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
  ns,
  self,
  config,
}:

let
  cleanupFinalizer = "actions.github.com/cleanup-protection";
  versionKey = "app.kubernetes.io/version";

  githubConfigUrl = import ./github-config-url.nix;

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
rec {
  # The first constraint the arguments of mkAutoscalingRunnerSet break, as a
  # message without the instance prefix, or null.
  refusal =
    {
      namespace,
      name,
      spec,
    }:
    let
      templateSpec = (spec.template or { }).spec or { };
      containers = templateSpec.containers or [ ];
      url = spec.githubConfigUrl or null;
      runners = n: if builtins.isInt (spec.${n} or null) then spec.${n} else null;
      nameLength = builtins.stringLength name;
    in
    if templateSpec ? serviceAccountName then
      "spec.template.spec.serviceAccountName is set. The runner pods use the ServiceAccount ${name}-runner, which this builder creates; bind a Role to it for API access instead."
    else if nameLength > 45 then
      "the name has ${toString nameLength} characters. The controller names the listener <name>-<hash of up to 8 characters>-listener, which must fit in 63 characters, so the name may have at most 45; choose a shorter name."
    else if !(builtins.isString url) then
      "spec.githubConfigUrl is missing or not a string. Set it to the organization, repository, or enterprise URL."
    else if githubConfigUrl.problem url != null then
      "spec.githubConfigUrl ${githubConfigUrl.problem url}"
    else if !(builtins.isString (spec.githubConfigSecret or null)) then
      "spec.githubConfigSecret is missing or not a string. Pass the out.name of a Secret in ${namespace}."
    else if
      runners "minRunners" != null && runners "maxRunners" != null && spec.minRunners > spec.maxRunners
    then
      "spec.minRunners (${toString spec.minRunners}) is greater than spec.maxRunners (${toString spec.maxRunners}). Lower minRunners or raise maxRunners."
    else if !(builtins.any (c: (c.name or null) == "runner") containers) then
      "spec.template.spec.containers has no container named runner. The controller runs the job in the container with that name; add it."
    else
      null;

  mkAutoscalingRunnerSet =
    consumerScope:
    { name, spec }:
    let
      namespace = consumerScope.namespaceName;
      problem = refusal { inherit namespace name spec; };

      objectLabels.${versionKey} = builtins.unsafeDiscardStringContext config.image.tag;

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
        annotations = {
          "actions.github.com/cleanup-manager-role-binding" = managerRoleBinding.out.name;
          "actions.github.com/cleanup-manager-role-name" = managerRole.out.name;
          "actions.github.com/cleanup-no-permission-service-account-name" = runnerServiceAccount.out.name;
        };
        requires = [ self.deployment ];
        spec = lib.recursiveUpdate spec {
          githubConfigUrl = githubConfigUrl.trimTrailingSlashes spec.githubConfigUrl;
          template.spec.serviceAccountName = runnerServiceAccount.out.name;
        };
      };
    in
    if problem != null then
      consumerScope.fail {
        package = "arc";
        message = "AutoscalingRunnerSet ${namespace}/${name}: ${problem}";
      }
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
