# arc's `out.mkAutoscalingRunnerSet`: one AutoscalingRunnerSet and the three
# objects the controller expects beside it.
#
#   parts = arc.out.mkAutoscalingRunnerSet scope {
#     name = scope.instanceName;
#     spec = {
#       githubConfigUrl = "https://github.com/example-org";
#       githubConfigSecret = githubConfigSecret.out.name;
#       maxRunners = 4;
#       template.spec.containers = [ { name = "runner"; image = "..."; command = [ "/home/runner/run.sh" ]; } ];
#     };
#   };
#
# Returns, in the caller's namespace:
#   runnerServiceAccount  `<name>-runner`, which the runner pods use. It has
#                         no permissions; bind a Role to it for API access.
#   managerRole           `<name>-manager` (the chart's manager_role.yaml),
#                         which lets the controller create the runner pods,
#                         their Secrets, and the listener's RBAC here. It also
#                         reads ConfigMaps when the spec sets githubServerTLS.
#   managerRoleBinding    `<name>-manager`, binding it to the controller.
#   autoscalingRunnerSet  the runner set, with `spec.template.spec.
#                         serviceAccountName` set to the runner ServiceAccount
#                         and `githubConfigUrl` without trailing slashes.
#
# The runner set carries the version label the controller compares with its
# own (it deletes a runner set whose major.minor differs) and the
# `actions.github.com/cleanup-*` annotations naming the other three objects.
# Those three carry the `actions.github.com/cleanup-protection` finalizer,
# which the controller removes once it has deleted the runner set, and they
# require the controller Deployment, so a new arc release re-applies them
# after the new controller runs.
#
# Remove a runner set before its secret and before arc (see default.nix): the
# controller needs both to deregister the scale set from GitHub.
{
  lib,
  kix,
  who,
  ns,
  self,
  config,
}:

let
  cleanupFinalizer = "actions.github.com/cleanup-protection";
  versionKey = "app.kubernetes.io/version";

  # ParseGitHubConfigFromURL (github/actions/actions.go) accepts an
  # organization, a repository, or enterprises/<name> after the host. It
  # also accepts a URL without a scheme, which this check refuses.
  urlPattern = "https?://[^/]+/[^/]+(/[^/]+)?";
  trimTrailingSlashes =
    s:
    let
      m = builtins.match "(.*[^/])/*" s;
    in
    if m == null then s else builtins.head m;

  # Keys under actions.github.com/ are the controller's: it reads the
  # cleanup annotations and writes the rest.
  reservedKeys =
    attrs: builtins.filter (lib.hasPrefix "actions.github.com/") (builtins.attrNames attrs);

  managerRules =
    rbac: withTLS:
    let
      inherit (rbac) core allow grant;
      authz = rbac.group "rbac.authorization.k8s.io" [
        "rolebindings"
        "roles"
      ];
      createDelete = [
        "create"
        "delete"
        "get"
        "patch"
        "update"
      ];
    in
    grant (
      [
        (
          core.pods
          |> allow [
            "create"
            "delete"
            "get"
          ]
        )
        (core "pods/status" |> allow [ "get" ])
        (
          [
            core.secrets
            core.serviceaccounts
          ]
          |> allow (createDelete ++ [ "list" ])
        )
        (
          [
            authz.rolebindings
            authz.roles
          ]
          |> allow createDelete
        )
      ]
      ++ lib.optional withTLS (core.configmaps |> allow [ "get" ])
    );
in
{
  mkAutoscalingRunnerSet =
    consumerScope:
    {
      name,
      spec,
      labels ? { },
      annotations ? { },
    }:
    let
      where = "${who}: AutoscalingRunnerSet ${consumerScope.namespaceName}/${name}";
      templateSpec = (spec.template or { }).spec or { };
      containers = templateSpec.containers or [ ];
      rawUrl = spec.githubConfigUrl or null;
      url = if builtins.isString rawUrl then trimTrailingSlashes rawUrl else null;
      runners = n: if builtins.isInt (spec.${n} or null) then spec.${n} else null;

      refusal =
        if labels ? ${versionKey} then
          "labels sets ${versionKey}, which the package sets to the controller's image tag; the controller deletes a runner set whose label differs from its version. Remove it."
        else if reservedKeys labels != [ ] || reservedKeys annotations != [ ] then
          "labels or annotations set ${
            lib.concatStringsSep ", " (reservedKeys labels ++ reservedKeys annotations)
          }, which the controller owns. Remove them."
        else if templateSpec ? serviceAccountName then
          "spec.template.spec.serviceAccountName is set. The runner pods use the ServiceAccount ${name}-runner, which this builder creates; bind a Role to it for API access instead."
        else if builtins.stringLength name > 45 then
          "the name has ${toString (builtins.stringLength name)} characters. The controller allows 45, because the listener's name derives from it; choose a shorter instance name."
        else if url == null then
          "spec.githubConfigUrl is missing or not a string. Set it to the organization, repository, or enterprise URL."
        else if builtins.match urlPattern url == null then
          "spec.githubConfigUrl must be http(s)://<host>/ followed by <org>, <org>/<repo>, or enterprises/<name>; got \"${rawUrl}\"."
        else if !(builtins.isString (spec.githubConfigSecret or null)) then
          "spec.githubConfigSecret is missing or not a string. Pass the out.name of a Secret in ${consumerScope.namespaceName}."
        else if
          runners "minRunners" != null && runners "maxRunners" != null && spec.minRunners > spec.maxRunners
        then
          "spec.minRunners (${toString spec.minRunners}) is greater than spec.maxRunners (${toString spec.maxRunners}). Lower minRunners or raise maxRunners."
        else if !(builtins.any (c: (c.name or null) == "runner") containers) then
          "spec.template.spec.containers has no container named runner. The controller runs the job in the container with that name; add it."
        else
          null;

      objectLabels = labels // {
        ${versionKey} = config.image.tag;
      };

      supporting =
        args:
        consumerScope.mkResource (
          args
          // {
            labels = objectLabels;
            requires = [ self.deployment ];
            extra = lib.recursiveUpdate (args.extra or { }) { metadata.finalizers = [ cleanupFinalizer ]; };
          }
        );

      runnerServiceAccount = supporting {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-runner";
      };

      managerRole = supporting {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "Role";
        name = "${name}-manager";
        extra.rules = managerRules consumerScope.rbac (spec ? githubServerTLS);
      };

      managerRoleBinding = supporting {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "RoleBinding";
        name = "${name}-manager";
        extra = {
          roleRef = {
            apiGroup = "rbac.authorization.k8s.io";
            kind = "Role";
            name = managerRole.out.name;
          };
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = ns;
            }
          ];
        };
      };

      autoscalingRunnerSet = self.crds.autoscalingRunnerSets.out.mkCR consumerScope {
        inherit name;
        labels = objectLabels;
        annotations = annotations // {
          "actions.github.com/cleanup-manager-role-binding" = managerRoleBinding.out.name;
          "actions.github.com/cleanup-manager-role-name" = managerRole.out.name;
          "actions.github.com/cleanup-no-permission-service-account-name" = runnerServiceAccount.out.name;
        };
        requires = [ self.deployment ];
        spec = lib.recursiveUpdate spec {
          githubConfigUrl = url;
          template.spec.serviceAccountName = runnerServiceAccount.out.name;
        };
      };
    in
    if refusal != null then
      throw "${where}: ${refusal}"
    else
      {
        inherit
          runnerServiceAccount
          managerRole
          managerRoleBinding
          autoscalingRunnerSet
          ;
      };
}
