# kix checks — schema validation and cross-resource integrity checks.
#
# Imported by flake.nix as:
#   kixChecks = import ./checks.nix { inherit pkgs lib; };

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
  # Skips Prometheus Operator CRDs since kubeconform doesn't have
  # their schemas built-in.
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

  # Convert manifest list to an attrset keyed by {name}-{kind},
  # matching the shape expected by validateManifestSet.
  manifestMap =
    manifests:
    builtins.listToAttrs (
      map (m: {
        name = "${m.metadata.name}-${lib.toLower m.kind}";
        value = m;
      }) manifests
    );

  # --- Cross-resource validation ---
  #
  # Validates referential integrity across the manifest set:
  # - ServiceAccount references resolve to SAs in the set
  # - RoleBinding/ClusterRoleBinding roleRefs resolve to Roles/ClusterRoles
  # - ConfigMap volume refs resolve to ConfigMaps in the set
  # - Service selectors match at least one workload's pod template labels
  # - HPA scaleTargetRef points to existing workloads
  # - No duplicate (kind, namespace, name) tuples
  # - managed-by label on all resources
  #
  # Only validates INTERNAL references (resources created by kix).
  # External references (e.g., auth.existingSecret) are intentionally
  # skipped — those are cluster-provided resources outside kix's scope.
  #
  # This is pure eval-time Nix — no IFD, no runtime check.
  validateManifestSet =
    clusterName: manifests:
    let
      resources = lib.attrValues manifests;

      # Index resources by (kind, name) for lookup.
      byKindName = builtins.foldl' (
        acc: r:
        let
          name = r.metadata.name or "";
          kind = r.kind;
        in
        acc // { "${kind}:${name}" = r; }
      ) { } resources;

      hasResource = kind: name: byKindName ? "${kind}:${name}";

      # --- 1. ServiceAccount references ---
      workloadKinds = [
        "Deployment"
        "StatefulSet"
        "DaemonSet"
        "Job"
      ];
      workloads = builtins.filter (r: builtins.elem r.kind workloadKinds) resources;

      getPodSpec =
        r: if r.kind == "Job" then r.spec.template.spec or { } else r.spec.template.spec or { };

      saRefs = builtins.concatMap (
        r:
        let
          podSpec = getPodSpec r;
          saName = podSpec.serviceAccountName or null;
        in
        if saName != null then
          [
            {
              workload = r.metadata.name;
              inherit saName;
              kind = r.kind;
            }
          ]
        else
          [ ]
      ) workloads;

      saValidation = builtins.all (
        ref:
        hasResource "ServiceAccount" ref.saName
        || !(builtins.any (
          r:
          r.kind == "ServiceAccount" && lib.hasPrefix (lib.removeSuffix ref.saName ref.saName) r.metadata.name
        ) resources)
        || ref.saName == "default"
      ) saRefs;

      # --- 2. RoleBinding/ClusterRoleBinding roleRef validation ---
      bindingKinds = [
        "RoleBinding"
        "ClusterRoleBinding"
      ];
      bindings = builtins.filter (r: builtins.elem r.kind bindingKinds) resources;

      roleRefValidation = builtins.all (
        binding:
        let
          ref = binding.roleRef or { };
          refKind = ref.kind or "";
          refName = ref.name or "";
        in
        hasResource refKind refName
        || lib.hasPrefix "system:" refName
        || lib.hasSuffix "-psp" refName
        || builtins.elem refName [
          "admin"
          "cluster-admin"
          "edit"
          "view"
        ]
      ) bindings;

      # --- 3. ConfigMap volume references ---
      configMapVolRefs = builtins.concatMap (
        r:
        let
          podSpec = getPodSpec r;
          volumes =
            let
              v = podSpec.volumes or [ ];
            in
            if v == null then [ ] else v;
        in
        builtins.concatMap (
          vol:
          let
            cmName = vol.configMap.name or null;
          in
          if cmName != null then
            [
              {
                workload = r.metadata.name;
                inherit cmName;
              }
            ]
          else
            [ ]
        ) volumes
      ) workloads;

      configMapValidation = builtins.all (ref: hasResource "ConfigMap" ref.cmName) configMapVolRefs;

      # --- 4. Service selector -> workload label matching ---
      services = builtins.filter (r: r.kind == "Service") resources;

      selectorMatchesLabels =
        selector: labels: builtins.all (k: (labels.${k} or null) == selector.${k}) (lib.attrNames selector);

      # Workaround: Prometheus Operator creates pods from Prometheus/Alertmanager
      # CRDs at runtime, injecting its own labels. Since those labels don't exist
      # at Nix evaluation time, we can't match Service selectors against them.
      # We exempt services whose name matches a CRD resource name instead.
      operatorWorkloadKinds = [
        "Prometheus"
        "Alertmanager"
      ];

      # Workaround: kube-prometheus-stack Helm chart creates headless Services
      # that target Kubernetes control-plane and system pods (coredns, scheduler,
      # etc.) for scraping metrics. These pods are managed by the cluster itself,
      # not by kix, so they will never appear in the manifest set.
      systemComponentSelectors = [
        { "k8s-app" = "kube-dns"; }
        { "component" = "kube-controller-manager"; }
        { "component" = "kube-scheduler"; }
        { "component" = "kube-apiserver"; }
        { "k8s-app" = "kube-proxy"; }
        { "component" = "etcd"; }
      ];

      serviceValidation = builtins.all (
        svc:
        let
          selector = svc.spec.selector or { };
          isSystemComponent = builtins.any (sc: selectorMatchesLabels sc selector) systemComponentSelectors;
          targetsOperatorWorkload =
            builtins.any (r: builtins.elem r.kind operatorWorkloadKinds) resources
            && builtins.any (
              r: builtins.elem r.kind operatorWorkloadKinds && lib.hasPrefix r.metadata.name svc.metadata.name
            ) resources;
        in
        selector == { }
        || isSystemComponent
        || targetsOperatorWorkload
        || builtins.any (
          w:
          let
            templateLabels = w.spec.template.metadata.labels or { };
          in
          selectorMatchesLabels selector templateLabels
        ) workloads
      ) services;

      # --- 5. HPA scaleTargetRef validation ---
      hpas = builtins.filter (r: r.kind == "HorizontalPodAutoscaler") resources;

      hpaValidation = builtins.all (
        hpa:
        let
          ref = hpa.spec.scaleTargetRef or { };
        in
        hasResource (ref.kind or "") (ref.name or "")
      ) hpas;

      # --- 6. No duplicate (kind, namespace, name) tuples ---
      resourceIds = map (
        r:
        let
          ns = r.metadata.namespace or null;
          nsStr = if ns == null then "cluster-scoped" else ns;
          name = r.metadata.name or "unnamed";
        in
        "${r.kind}/${nsStr}/${name}"
      ) resources;
      uniqueIds = lib.unique resourceIds;
      noDuplicateIds = builtins.length resourceIds == builtins.length uniqueIds;

      # --- 7. managed-by label on all resources ---
      managedByValidation = builtins.all (
        r: (r.metadata.labels."app.kubernetes.io/managed-by" or "") == "kix"
      ) resources;

      # --- Collect failures for clear error messages ---
      failures =
        (lib.optional (!saValidation) "ServiceAccount reference validation failed")
        ++ (lib.optional (!roleRefValidation)
          "RoleBinding roleRef validation failed — a binding references a Role/ClusterRole not in the manifest set"
        )
        ++ (lib.optional (!configMapValidation)
          "ConfigMap volume reference validation failed — a workload references a ConfigMap not in the manifest set"
        )
        ++ (lib.optional (!serviceValidation)
          "Service selector validation failed — a Service's selector doesn't match any workload's pod template labels"
        )
        ++ (lib.optional (
          !hpaValidation
        ) "HPA scaleTargetRef validation failed — an HPA targets a workload not in the manifest set")
        ++ (lib.optional (!noDuplicateIds) "Duplicate resource identity (kind/namespace/name) detected")
        ++ (lib.optional (
          !managedByValidation
        ) "managed-by label validation failed — a resource is missing app.kubernetes.io/managed-by=kix");
    in
    if failures == [ ] then
      true
    else
      throw "validateManifestSet(${clusterName}): ${lib.concatStringsSep "; " failures}";

}
