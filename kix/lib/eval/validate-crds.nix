# Validate custom resource kinds, versions, CRD dependency ordering, and
# `metadata.namespace` presence on namespaced kinds (checks 18 and 21).
{ lib }:

let
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;

  builtInNamespacedKinds = {
    "" = [
      "ConfigMap"
      "Endpoints"
      "Event"
      "LimitRange"
      "PersistentVolumeClaim"
      "Pod"
      "PodTemplate"
      "ReplicationController"
      "ResourceQuota"
      "Secret"
      "Service"
      "ServiceAccount"
    ];
    "apps" = [
      "ControllerRevision"
      "DaemonSet"
      "Deployment"
      "ReplicaSet"
      "StatefulSet"
    ];
    "autoscaling" = [ "HorizontalPodAutoscaler" ];
    "batch" = [
      "CronJob"
      "Job"
    ];
    "coordination.k8s.io" = [ "Lease" ];
    "discovery.k8s.io" = [ "EndpointSlice" ];
    "events.k8s.io" = [ "Event" ];
    "networking.k8s.io" = [
      "Ingress"
      "NetworkPolicy"
    ];
    "policy" = [ "PodDisruptionBudget" ];
    "rbac.authorization.k8s.io" = [
      "Role"
      "RoleBinding"
    ];
    "storage.k8s.io" = [ "CSIStorageCapacity" ];
  };

  builtInGroups = [
    ""
    "apps"
    "batch"
    "autoscaling"
    "policy"
    "networking.k8s.io"
    "rbac.authorization.k8s.io"
    "storage.k8s.io"
    "scheduling.k8s.io"
    "admissionregistration.k8s.io"
    "apiextensions.k8s.io"
    "apiregistration.k8s.io"
    "coordination.k8s.io"
    "discovery.k8s.io"
    "events.k8s.io"
    "node.k8s.io"
    "certificates.k8s.io"
    "flowcontrol.apiserver.k8s.io"
    "resource.k8s.io"
    "authentication.k8s.io"
    "authorization.k8s.io"
    "internal.apiserver.k8s.io"
    "storagemigration.k8s.io"
    kixAnnotations.group
  ];

  inherit (import ../core/util.nix { inherit lib; }) listOr splitList groupOf;

  versionOf =
    apiVersion:
    let
      parts = lib.splitString "/" apiVersion;
    in
    lib.last parts;

  describe =
    r:
    let
      ns = r.metadata.namespace or null;
      name = r.metadata.name or "unnamed";
    in
    if ns == null then "${r.kind} ${name}" else "${r.kind} ${ns}/${name}";

  instanceClause = owner: if owner == null then "" else " (instance ${owner})";
in
{
  checkCrds =
    {
      resources,
      entries,
      dependencyClosure,
    }:
    let
      crdDecls = builtins.concatMap (
        e:
        if e.r.kind == "CustomResourceDefinition" then
          [
            {
              group = e.r.spec.group or "";
              kind = e.r.spec.names.kind or "";
              served = map (v: v.name) (
                builtins.filter (v: v.served or true) (listOr (e.r.spec.versions or [ ]))
              );
              scope = e.r.spec.scope or "Namespaced";
              text = "CustomResourceDefinition ${e.r.metadata.name or "unnamed"}";
              inherit e;
            }
          ]
        else
          [ ]
      ) entries;

      crdRefDecls = builtins.concatMap (
        e:
        let
          anns = e.r.metadata.annotations or { };
          crdName = anns.${kixKeys.importName} or "";
          dot = lib.splitString "." crdName;
        in
        if e.r.kind == "PackageInstance" && anns ? ${kixKeys.crdKind} then
          [
            {
              group = builtins.concatStringsSep "." (builtins.tail dot);
              kind = anns.${kixKeys.crdKind};
              served = splitList anns.${kixKeys.crdServedVersions};
              scope = anns.${kixKeys.crdScope} or "Namespaced";
              text = "the CRD ref ${e.r.metadata.name} for ${crdName}";
              inherit e;
            }
          ]
        else
          [ ]
      ) entries;

      apiServiceDecls = builtins.concatMap (
        e:
        let
          anns = e.r.metadata.annotations or { };
          fromName =
            name:
            let
              parts = lib.splitString "." name;
            in
            {
              version = builtins.head parts;
              group = builtins.concatStringsSep "." (builtins.tail parts);
            };
          decl = gv: text: {
            inherit (gv) group;
            kind = null;
            served = [ gv.version ];
            scope = null;
            inherit text e;
          };
        in
        if e.r.kind == "APIService" then
          [
            (decl {
              group = e.r.spec.group or "";
              version = e.r.spec.version or "";
            } "APIService ${e.r.metadata.name or "unnamed"}")
          ]
        else if e.r.kind == "PackageInstance" && (anns.${kixKeys.importKind} or null) == "APIService" then
          [
            (decl (fromName
              anns.${kixKeys.importName}
            ) "the import of APIService ${anns.${kixKeys.importName}} (${e.r.metadata.name})")
          ]
        else
          [ ]
      ) entries;

      kindDecls = crdDecls ++ crdRefDecls ++ apiServiceDecls;

      # A namespaced resource without `metadata.namespace` is stored in the
      # default namespace by the API server while the CLI tracks it as
      # cluster-scoped, breaking diff and prune. Check built-in namespaced kinds
      # and custom kinds declared as `Namespaced` by a CRD or CRD ref marker in
      # the build.
      namespacedCustomKinds =
        builtins.listToAttrs (
          map
            (crd: {
              name = "${crd.spec.group}/${crd.spec.names.kind}";
              value = true;
            })
            (
              builtins.filter (
                r: r.kind == "CustomResourceDefinition" && (r.spec.scope or "") == "Namespaced"
              ) resources
            )
        )
        // builtins.listToAttrs (
          map (d: {
            name = "${d.group}/${d.kind}";
            value = true;
          }) (builtins.filter (d: d.scope == "Namespaced") crdRefDecls)
        );

      isNamespacedKind =
        r:
        let
          group = groupOf (r.apiVersion or "");
        in
        builtins.elem r.kind (builtInNamespacedKinds.${group} or [ ])
        || namespacedCustomKinds ? "${group}/${r.kind}";

      missingNamespaceFailures = map (
        r:
        "${r.kind} ${r.metadata.name or "unnamed"} (${r.apiVersion or ""}) is a namespaced kind but has no metadata.namespace. Create it with a namespaced scope (scope.mkResource) rather than scope.mkClusterResource, or set metadata.namespace"
      ) (builtins.filter (r: !(r.metadata ? namespace) && isNamespacedKind r) resources);

      # Every resource outside the built-in API groups must depend (via
      # `kix.run/depends-on`) on a CustomResourceDefinition, CRD ref marker, or
      # APIService that serves its group, kind, and version.
      customResourceFailures = builtins.concatMap (
        e:
        let
          r = e.r;
          apiVersion = r.apiVersion or "";
          group = groupOf apiVersion;
          version = versionOf apiVersion;
          matching = builtins.filter (d: d.group == group && (d.kind == null || d.kind == r.kind)) kindDecls;
          closure = dependencyClosure e;
          reachable = builtins.filter (d: d.e.hash != null && closure ? ${d.e.hash}) matching;
          provider = d: if d.e.owner == null then "" else " (instance ${d.e.owner})";
          chartSentence = "If a Helm chart renders it (a values toggle), turn the toggle off and build it with the owner's builder in a package of your own; a chart resource cannot take the dependency.";
        in
        if builtins.elem group builtInGroups then
          [ ]
        else if matching == [ ] then
          [
            "${describe r} (${apiVersion}${
              lib.optionalString (e.owner != null) ", instance ${e.owner}"
            }) has no CustomResourceDefinition in the cluster build, so the apiserver would reject it at apply. Take the package that installs the CRD as a dependency and build the resource with its builder (scope.mkCR dep.out.crds.<Kind>, or dep.out.mk<Kind> where it exists), vendor the CRD as JSON and build it with scope.mkCRD (scripts/vendor-crds.py fetches upstream CRDs), or declare a CRD installed outside Kix with scope.mkCRDRef { group = \"${group}\"; kind = \"${r.kind}\"; version = \"${version}\"; ... } and build with scope.mkCR. ${chartSentence}"
          ]
        else if reachable == [ ] then
          let
            own = builtins.filter (d: e.owner != null && d.e.owner == e.owner) matching;
            d = builtins.head matching;
          in
          if own != [ ] then
            [
              "${describe r}${instanceClause e.owner} does not depend on ${(builtins.head own).text}, which the same instance declares, so the deploy can apply it before the CRD is served. Build it with scope.mkCR from that declaration, or list the declaration in its requires."
            ]
          else
            [
              "${describe r}${instanceClause e.owner} does not depend on ${d.text}${provider d}, which declares its kind, so the deploy can apply it before the CRD is served. Take ${
                if d.e.owner == null then "that instance" else d.e.owner
              } as a dependency${
                lib.optionalString (e.owner != null) " of ${e.owner}"
              } and build the resource with its builder, which adds the dependency. ${chartSentence}"
            ]
        else if builtins.any (d: builtins.elem version d.served) reachable then
          [ ]
        else
          let
            d = builtins.head reachable;
          in
          [
            "${describe r} uses ${apiVersion}, but ${d.text}${provider d} serves ${builtins.concatStringsSep ", " d.served} for ${group}/${r.kind}. Use a served version, or correct the declaration."
          ]
      ) entries;
    in
    {
      inherit missingNamespaceFailures customResourceFailures;
    };
}
