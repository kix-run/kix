# Built-in scorecard rules for secret sources, container security contexts,
# host access, cluster-wide RBAC, image references, and network policies.

{ lib }:

let
  kixKeys = (import ../core/annotations.nix).keys;

  inherit (import ../core/util.nix { inherit lib; }) listOr attrsOr;
  inherit (import ../core/pod-spec.nix { inherit lib; }) podSpecOf;
  workloadKinds = import ../core/workload-kinds.nix { inherit lib; };

  getPodSpec = podSpecOf;

  getContainers =
    resource:
    let
      podSpec = getPodSpec resource;
    in
    # Helm charts can render `initContainers: null`, and scorecard rules inspect
    # manifests before null fields are stripped.
    listOr (podSpec.containers or [ ]) ++ listOr (podSpec.initContainers or [ ]);

  # Return the effective `securityContext` field for a container, falling back
  # to the pod-level `securityContext`.
  effectiveSecurity =
    resource: container: field:
    let
      podLevel = (getPodSpec resource).securityContext or { };
      containerLevel = container.securityContext or { };
    in
    if containerLevel ? ${field} then
      containerLevel.${field}
    else if podLevel ? ${field} then
      podLevel.${field}
    else
      null;

  # Treat runAsNonRoot=true or a resolved nonzero runAsUser as non-root.
  runsAsNonRoot =
    resource: container:
    let
      flag = effectiveSecurity resource container "runAsNonRoot";
      uid = effectiveSecurity resource container "runAsUser";
    in
    (flag == true) || (flag == null && uid != null && uid != 0);

  # Return true when the package declares `grant` in `meta.unsafe`.
  holdsGrant = meta: grant: builtins.elem grant (meta.unsafe or [ ]);

  isWorkload = resource: builtins.elem (resource.kind or "") workloadKinds.builtKinds;

  # Return true when `resource` is an import marker produced by `scope.mkSecretRef`.
  isSecretRefMarker =
    resource:
    (resource.kind or "") == "PackageInstance"
    && resource.metadata.annotations.${kixKeys.mode} or null == "import"
    && resource.metadata.annotations.${kixKeys.importKind} or null == "Secret";

  # Return `{ <key> = <source>; }` for each key in a Secret. Keys present in
  # `data` or `stringData` are always treated as `inline` (or `plain` when
  # stamped as non-credential) so a forged `kix.run/secret-sources` annotation
  # on a raw Secret cannot disguise inline values.
  secretKeySources =
    resource:
    let
      annotations = resource.metadata.annotations or { };
      stamp = annotations.${kixKeys.secretSources} or "";
      classification = annotations.${kixKeys.classification} or null;
      fromStamp = builtins.listToAttrs (
        map (
          pair:
          let
            parts = lib.splitString "=" pair;
          in
          {
            name = builtins.head parts;
            value = builtins.elemAt parts 1;
          }
        ) (builtins.filter (pair: pair != "") (lib.splitString "," stamp))
      );
      dataKeys = builtins.attrNames (
        attrsOr (resource.data or null) // attrsOr (resource.stringData or null)
      );
      fromData = lib.genAttrs dataKeys (
        k: if fromStamp.${k} or null == "plain" then "plain" else "inline"
      );
      sources = lib.filterAttrs (k: _: !(builtins.elem k dataKeys)) fromStamp // fromData;
    in
    lib.mapAttrs (
      _: source:
      if source == "inline" && classification == "configuration" then "configuration" else source
    ) sources;

  describeSource = {
    inline = "written into the build (inline)";
    sops = "decrypted from a SOPS file at deploy (sops)";
    controller = "filled by a controller after Kix creates the Secret (controller)";
    configuration = "configuration the package rendered, classified as holding no credential (configuration)";
    external = "created outside Kix (external)";
  };
in
{
  # Check Secret value sources when `cluster.secrets.accept` is configured.
  # Keys marked `plain` are non-credential values and are always allowed.
  secretSource = {
    description = "Secret values come only from the sources the cluster accepts";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "secrets"
    ];
    appliesTo =
      {
        resource,
        acceptedSecretSources ? null,
        ...
      }:
      acceptedSecretSources != null && ((resource.kind or "") == "Secret" || isSecretRefMarker resource);
    check =
      {
        resource,
        acceptedSecretSources,
        ...
      }:
      let
        accepted = lib.concatStringsSep ", " acceptedSecretSources;
        fix = "Supply the value from a source this cluster accepts (a secret-ref dependency for a Secret something else creates, a SOPS source for a packages.secret instance), or add the source to cluster.secrets.accept.";
      in
      if isSecretRefMarker resource then
        lib.optional (!(builtins.elem "external" acceptedSecretSources)) {
          message = "Secret '${
            resource.metadata.annotations.${kixKeys.importName}
          }' is ${describeSource.external}, and this cluster accepts ${accepted}. ${fix}";
        }
      else
        let
          sources = secretKeySources resource;
          offending = lib.filterAttrs (
            _: source: source != "plain" && !(builtins.elem source acceptedSecretSources)
          ) sources;
          bySource = lib.groupBy (k: offending.${k}) (builtins.attrNames offending);
        in
        lib.mapAttrsToList (
          source: keys:
          let
            keyText = if keys == [ "*" ] then "every key" else "key(s) ${lib.concatStringsSep ", " keys}";
            verb = if builtins.length keys == 1 then "is" else "are";
          in
          {
            message = "Secret '${resource.metadata.name or "?"}': ${keyText} ${verb} ${
              describeSource.${source} or source
            }, and this cluster accepts ${accepted}. ${fix}";
          }
        ) bySource;
  };

  nonRoot = {
    description = "All containers must run as non-root";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "cis-benchmark"
    ];
    appliesTo =
      {
        resource,
        meta ? { },
        ...
      }:
      isWorkload resource && !(holdsGrant meta "run-as-root");
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: !(runsAsNonRoot resource c)) containers;
      in
      map (c: {
        message =
          "container '${c.name or "unnamed"}' may run as root: neither it nor the pod "
          + "sets securityContext.runAsNonRoot, and no non-zero runAsUser resolves for it";
      }) failing;
  };

  noPrivileged = {
    description = "No containers may run in privileged mode";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "cis-benchmark"
    ];
    appliesTo =
      {
        resource,
        meta ? { },
        ...
      }:
      isWorkload resource && !(holdsGrant meta "privileged");
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: c.securityContext.privileged or false) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' runs in privileged mode";
      }) failing;
  };

  readOnlyRootfs = {
    description = "Containers should use read-only root filesystem";
    level = "manifest";
    severity = "warning";
    tags = [ "security" ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        failing = builtins.filter (c: !(c.securityContext.readOnlyRootFilesystem or false)) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' does not set readOnlyRootFilesystem";
      }) failing;
  };

  noHostNetwork = {
    description = "Pods must not use host networking";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "cis-benchmark"
    ];
    appliesTo =
      {
        resource,
        meta ? { },
        ...
      }:
      isWorkload resource && !(holdsGrant meta "host-network");
    check =
      { resource, ... }:
      let
        podSpec = getPodSpec resource;
        violations = lib.concatLists [
          (lib.optional (podSpec.hostNetwork or false) { message = "pod uses hostNetwork"; })
          (lib.optional (podSpec.hostPID or false) { message = "pod uses hostPID"; })
          (lib.optional (podSpec.hostIPC or false) { message = "pod uses hostIPC"; })
        ];
      in
      violations;
  };

  # Reject ClusterRoleBindings to `cluster-admin` and ClusterRoles that grant
  # `*` on `apiGroups`, `resources`, and `verbs`. Namespaced RoleBindings and
  # wildcards scoped to specific API groups are allowed.
  noClusterAdmin = {
    description = "No ClusterRoleBinding may grant cluster-admin, and no ClusterRole may grant every verb on every resource";
    level = "manifest";
    severity = "error";
    tags = [
      "security"
      "rbac"
      "cis-benchmark"
    ];
    appliesTo =
      {
        resource,
        meta ? { },
        ...
      }:
      builtins.elem (resource.kind or "") [
        "ClusterRoleBinding"
        "ClusterRole"
      ]
      && !(holdsGrant meta "cluster-admin");
    check =
      { resource, ... }:
      let
        name = resource.metadata.name or "unnamed";
        fix =
          "Derive the rules the program needs with scope.rbac, or, when it must read and write "
          + "every kind (a cluster-wide backup tool), add \"cluster-admin\" to the package's meta.unsafe "
          + "with a comment that gives the reason.";
        describeSubject =
          s:
          if (s.kind or "") == "ServiceAccount" then
            "ServiceAccount ${s.namespace or "?"}/${s.name or "?"}"
          else
            "${s.kind or "subject"} ${s.name or "?"}";
        subjects = map describeSubject (listOr (resource.subjects or [ ]));
        subjectText = if subjects == [ ] then "no subjects" else lib.concatStringsSep ", " subjects;
        isAllWildcard =
          rule:
          builtins.all (field: builtins.elem "*" (listOr (rule.${field} or [ ]))) [
            "apiGroups"
            "resources"
            "verbs"
          ];
      in
      if resource.kind == "ClusterRoleBinding" then
        lib.optional
          ((resource.roleRef.kind or "") == "ClusterRole" && (resource.roleRef.name or "") == "cluster-admin")
          {
            message = "ClusterRoleBinding '${name}' grants cluster-admin to ${subjectText}. ${fix}";
          }
      else
        lib.optional (builtins.any isAllWildcard (listOr (resource.rules or [ ]))) {
          message = "ClusterRole '${name}' grants every verb on every resource in every API group, the reach of cluster-admin. ${fix}";
        };
  };

  noLatestTag = {
    description = "Image references should not use :latest or be untagged";
    level = "manifest";
    severity = "warning";
    tags = [
      "security"
      "operations"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        containers = getContainers resource;
        hasLatestOrNoTag =
          c:
          let
            image = c.image or "";
            # A colon after the last slash separates the tag from the repository.
            afterSlash = lib.last (lib.splitString "/" image);
            parts = lib.splitString ":" afterSlash;
          in
          (builtins.length parts == 1) || (lib.last parts == "latest");
        failing = builtins.filter hasLatestOrNoTag containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' uses image '${c.image or ""}' with :latest or no tag";
      }) failing;
  };

  # Detect known placeholder spellings and unexpanded variables in image
  # references. This cannot detect plausible but incorrect tags or digests;
  # `kix pin check` performs registry verification. The rule warns by default.
  noUnresolvedPlaceholder = {
    description = "Image references must not carry an unresolved placeholder";
    level = "manifest";
    severity = "warning";
    tags = [
      "security"
      "operations"
    ];
    appliesTo = { resource, ... }: isWorkload resource;
    check =
      { resource, ... }:
      let
        patterns = [
          {
            pattern = "REPLACE_ME";
            label = "the placeholder REPLACE_ME";
          }
          {
            pattern = "REPLACEME";
            label = "the placeholder REPLACEME";
          }
          {
            pattern = "CHANGE_ME";
            label = "the placeholder CHANGE_ME";
          }
          {
            pattern = "CHANGEME";
            label = "the placeholder CHANGEME";
          }
          {
            pattern = "PLACEHOLDER";
            label = "the placeholder PLACEHOLDER";
          }
          {
            pattern = "TODO";
            label = "the placeholder TODO";
          }
          {
            pattern = "FIXME";
            label = "the placeholder FIXME";
          }
          {
            pattern = "XXX";
            label = "the placeholder XXX";
          }
          {
            pattern = "[$][{]";
            label = "an unexpanded variable";
          }
        ];
        hit =
          image:
          let
            found = builtins.filter (p: builtins.match ".*${p.pattern}.*" image != null) patterns;
          in
          if found == [ ] then null else (builtins.head found).label;
        containers = getContainers resource;
        failing = builtins.filter (c: hit (c.image or "") != null) containers;
      in
      map (c: {
        message = "container '${c.name or "unnamed"}' uses image '${c.image or ""}', which still contains ${hit (c.image or "")}. Resolve it before deploying: keep the reference in a pin file (kix.pins) and set it with `kix pin set <key> --tag <tag>`.";
      }) failing;
  };

  hasNetworkPolicy = {
    description = "Namespaces with workloads must have at least one network policy";
    level = "namespace";
    severity = "warning";
    tags = [
      "security"
      "network"
    ];
    check =
      {
        resources,
        namespaceName,
        # Policy kinds accepted as namespace network policies, populated from
        # the cluster's `network-policy-enforcer` provider.
        networkPolicyKinds ? [ "NetworkPolicy" ],
        ...
      }:
      let
        hasWorkload = builtins.any (r: builtins.elem (r.kind or "") workloadKinds.servingKinds) resources;
        hasNetpol = builtins.any (r: builtins.elem (r.kind or "") networkPolicyKinds) resources;
      in
      if hasWorkload && !hasNetpol then
        [ { message = "namespace '${namespaceName}' has workloads but no network policy"; } ]
      else
        [ ];
  };
}
