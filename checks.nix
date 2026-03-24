# kix checks — schema validation and cross-resource integrity checks.
#
# Imported by flake.nix as:
#   kixChecks = import ./checks.nix { inherit pkgs lib; };
#
# Design principles:
#   - Every failure names the specific resource(s) involved.
#   - External references (cluster-provided roles, system pods) are exempted
#     via clear, documented allowlists — not naming-convention heuristics.
#   - No dead code, no double-negatives, no silent data loss.

{ pkgs, lib }:

rec {

  # Offline K8s JSON schemas for kubeconform — the Nix sandbox has no
  # network access, so we can't let kubeconform download schemas at
  # build time. Sparse checkout to avoid fetching the entire (~2GB) repo.
  kubernetesSchemas = pkgs.fetchgit {
    url = "https://github.com/yannh/kubernetes-json-schema.git";
    rev = "5040e4b99f6b2b6fd3801c7798cce29a077acf56";
    sparseCheckout = [ "master-standalone-strict" ];
    hash = "sha256-izt9E+RqmGuxLLwggPsRjaSx/QXHz8ZlcluiyHawikw=";
  };

  # Validate a manifest directory against K8s API schemas.
  schemaCheck =
    name: drv:
    pkgs.runCommand "schema-${name}"
      {
        nativeBuildInputs = [ pkgs.kubeconform ];
      }
      ''
        echo "Validating ${name}..."
        kubeconform -strict -summary \
          -ignore-missing-schemas \
          -schema-location '${kubernetesSchemas}/master-standalone-strict/{{ .ResourceKind }}{{ .KindSuffix }}.json' \
          ${drv}/*.yaml
        touch $out
      '';

  # --- Cross-resource validation ---
  #
  # Pure eval-time Nix checks. No IFD, no runtime.
  #
  # Validates:
  #   1. ServiceAccount references from workloads
  #   2. RoleBinding/ClusterRoleBinding roleRef targets
  #   3. ConfigMap volume references
  #   4. Service selectors match workload pod template labels
  #   5. HPA scaleTargetRef points to existing workloads
  #   6. No duplicate (kind, namespace, name) tuples
  #   7. managed-by label present on all resources
  #   8. Deployment/StatefulSet selector ⊆ pod template labels
  #
  # Only validates INTERNAL references (resources created by kix).
  # External references are exempted via documented allowlists.

  validateManifestSet =
    clusterName: manifests:
    let
      resources = manifests;

      # --- Helpers ---

      # Resource identity: kind/namespace/name (unique within a cluster).
      resourceId =
        r:
        let
          ns = r.metadata.namespace or "cluster-scoped";
          name = r.metadata.name or "unnamed";
        in
        "${r.kind}/${ns}/${name}";

      # Index by (kind, namespace, name) for namespace-aware lookup.
      byId = builtins.foldl' (acc: r: acc // { "${resourceId r}" = r; }) { } resources;

      # Cluster-scoped resources (Namespace, ClusterRole, etc.) have no namespace.
      # Namespace-scoped lookups need the referring resource's namespace.
      hasResource =
        kind: ns: name:
        byId ? "${kind}/${ns}/${name}" || byId ? "${kind}/cluster-scoped/${name}";

      workloadKinds = [
        "Deployment"
        "StatefulSet"
        "DaemonSet"
        "Job"
        "CronJob"
      ];
      workloads = builtins.filter (r: builtins.elem r.kind workloadKinds) resources;

      getPodSpec =
        r:
        let
          template =
            if r.kind == "CronJob" then
              r.spec.jobTemplate.spec.template.spec or { }
            else
              r.spec.template.spec or { };
        in
        template;

      selectorMatchesLabels =
        selector: labels: builtins.all (k: (labels.${k} or null) == selector.${k}) (lib.attrNames selector);

      # --- Allowlists for external references ---

      # Roles provided by the cluster itself, not by kix.
      externalRoleRef =
        name:
        lib.hasPrefix "system:" name
        || lib.hasSuffix "-psp" name
        || builtins.elem name [
          "admin"
          "cluster-admin"
          "edit"
          "view"
        ];

      # Services targeting pods managed by operators (Prometheus, Alertmanager)
      # or Kubernetes system components. These pods don't appear in manifests.
      operatorManagedKinds = [
        "Prometheus"
        "Alertmanager"
      ];
      hasOperatorResource = kind: builtins.any (r: r.kind == kind) resources;

      systemComponentSelectors = [
        { "k8s-app" = "kube-dns"; }
        { "k8s-app" = "coredns"; }
        { "component" = "kube-controller-manager"; }
        { "component" = "kube-scheduler"; }
        { "component" = "kube-apiserver"; }
        { "k8s-app" = "kube-proxy"; }
        { "component" = "etcd"; }
      ];

      isExemptService =
        svc:
        let
          selector = svc.spec.selector or { };
        in
        # No selector — headless or external-name service.
        selector == { }
        # Targets a K8s system component (metrics scraping).
        || builtins.any (sc: selectorMatchesLabels sc selector) systemComponentSelectors
        # Targets pods created by an operator CRD at runtime.
        # Match: a CRD resource of the operator kind exists, and the Service
        # name starts with that resource's name (operator naming convention).
        || builtins.any (
          r: builtins.elem r.kind operatorManagedKinds && lib.hasPrefix r.metadata.name svc.metadata.name
        ) resources;

      # --- 1. ServiceAccount references ---

      saFailures = builtins.concatMap (
        w:
        let
          podSpec = getPodSpec w;
          saName = podSpec.serviceAccountName or null;
          ns = w.metadata.namespace or "cluster-scoped";
        in
        if saName == null || saName == "default" then
          [ ]
        else if hasResource "ServiceAccount" ns saName then
          [ ]
        else
          [ "${w.kind} ${ns}/${w.metadata.name} references ServiceAccount '${saName}' which does not exist" ]
      ) workloads;

      # --- 2. RoleBinding/ClusterRoleBinding roleRef ---

      roleRefFailures =
        builtins.concatMap
          (
            binding:
            let
              ref = binding.roleRef or { };
              refKind = ref.kind or "";
              refName = ref.name or "";
              ns = binding.metadata.namespace or "cluster-scoped";
            in
            if hasResource refKind ns refName || externalRoleRef refName then
              [ ]
            else
              [
                "${binding.kind} ${ns}/${binding.metadata.name} references ${refKind} '${refName}' which does not exist"
              ]
          )
          (
            builtins.filter (
              r:
              builtins.elem r.kind [
                "RoleBinding"
                "ClusterRoleBinding"
              ]
            ) resources
          );

      # --- 3. ConfigMap volume references ---
      # Secrets are intentionally not checked — they are commonly managed
      # externally (Infisical, sealed-secrets, manual creation).

      volumeRefFailures = builtins.concatMap (
        w:
        let
          podSpec = getPodSpec w;
          volumes =
            let
              v = podSpec.volumes or [ ];
            in
            if v == null then [ ] else v;
          ns = w.metadata.namespace or "cluster-scoped";
        in
        builtins.concatMap (
          vol:
          let
            cmName = vol.configMap.name or null;
          in
          if cmName != null && !(hasResource "ConfigMap" ns cmName) then
            [
              "${w.kind} ${ns}/${w.metadata.name} mounts ConfigMap '${cmName}' which does not exist"
            ]
          else
            [ ]
        ) volumes
      ) workloads;

      # --- 4. Service selector -> workload label matching ---

      serviceFailures = builtins.concatMap (
        svc:
        if isExemptService svc then
          [ ]
        else
          let
            selector = svc.spec.selector or { };
            ns = svc.metadata.namespace or "cluster-scoped";
            matchesAny = builtins.any (
              w:
              let
                templateLabels = w.spec.template.metadata.labels or { };
              in
              selectorMatchesLabels selector templateLabels
            ) workloads;
          in
          if matchesAny then
            [ ]
          else
            [
              "Service ${ns}/${svc.metadata.name} selector ${builtins.toJSON selector} matches no workload pod template"
            ]
      ) (builtins.filter (r: r.kind == "Service") resources);

      # --- 5. HPA scaleTargetRef ---

      hpaFailures = builtins.concatMap (
        hpa:
        let
          ref = hpa.spec.scaleTargetRef or { };
          refKind = ref.kind or "";
          refName = ref.name or "";
          ns = hpa.metadata.namespace or "cluster-scoped";
        in
        if hasResource refKind ns refName then
          [ ]
        else
          [
            "HorizontalPodAutoscaler ${ns}/${hpa.metadata.name} targets ${refKind} '${refName}' which does not exist"
          ]
      ) (builtins.filter (r: r.kind == "HorizontalPodAutoscaler") resources);

      # --- 6. StatefulSet serviceName → headless Service validation ---
      # spec.serviceName must match a headless Service (clusterIP: None) in the
      # same namespace. A mismatch silently breaks per-pod DNS identity.
      serviceNameFailures =
        let
          headlessServiceNames = builtins.listToAttrs (
            builtins.concatMap (r:
              if r.kind == "Service" && (r.spec.clusterIP or "") == "None" then
                [{ name = "${r.metadata.namespace or "cluster-scoped"}/${r.metadata.name}"; value = true; }]
              else []
            ) resources
          );
        in
        builtins.concatMap (sts:
          let
            svcName = sts.spec.serviceName or null;
            ns = sts.metadata.namespace or "cluster-scoped";
          in
          if svcName == null || headlessServiceNames ? "${ns}/${svcName}" then []
          else [ "StatefulSet ${ns}/${sts.metadata.name} serviceName '${svcName}' does not match any headless Service (clusterIP: None) in the same namespace" ]
        ) (builtins.filter (r: r.kind == "StatefulSet") resources);

      # --- 7. No duplicate (kind, namespace, name) tuples ---

      resourceIds = map resourceId resources;
      uniqueIds = lib.unique resourceIds;
      duplicateFailures =
        if builtins.length resourceIds == builtins.length uniqueIds then
          [ ]
        else
          let
            counts = builtins.foldl' (acc: id: acc // { ${id} = (acc.${id} or 0) + 1; }) { } resourceIds;
            dups = lib.filterAttrs (_: c: c > 1) counts;
          in
          map (id: "Duplicate resource: ${id}") (lib.attrNames dups);

      # --- 7. managed-by label ---

      managedByFailures = builtins.concatMap (
        r:
        if (r.metadata.labels."app.kubernetes.io/managed-by" or "") == "kix" then
          [ ]
        else
          [ "${r.kind} ${resourceId r} is missing app.kubernetes.io/managed-by=kix label" ]
      ) resources;

      # --- 8. Selector consistency ---
      # A workload's spec.selector.matchLabels must be a subset of its
      # pod template labels, otherwise the workload will never match its pods.

      selectorConsistencyFailures =
        builtins.concatMap
          (
            w:
            let
              selectorLabels = w.spec.selector.matchLabels or { };
              templateLabels = w.spec.template.metadata.labels or { };
              ns = w.metadata.namespace or "cluster-scoped";
            in
            if selectorLabels == { } then
              [ ]
            else if selectorMatchesLabels selectorLabels templateLabels then
              [ ]
            else
              [
                "${w.kind} ${ns}/${w.metadata.name} selector ${builtins.toJSON selectorLabels} is not a subset of pod template labels ${builtins.toJSON templateLabels}"
              ]
          )
          (
            builtins.filter (
              r:
              builtins.elem r.kind [
                "Deployment"
                "StatefulSet"
                "DaemonSet"
              ]
            ) resources
          );

      # --- Collect all failures ---

      allFailures =
        saFailures
        ++ roleRefFailures
        ++ volumeRefFailures
        ++ serviceFailures
        ++ hpaFailures
        ++ serviceNameFailures
        ++ duplicateFailures
        ++ managedByFailures
        ++ selectorConsistencyFailures;
    in
    if allFailures == [ ] then
      true
    else
      throw "validateManifestSet(${clusterName}):\n${
        lib.concatMapStringsSep "\n" (f: "  - ${f}") allFailures
      }";

}
