# kixpkgs flake — the entry point for building kix packages.
#
# Architecture (2026-03):
#
# Each Kubernetes package lives in packages/<chart-name>/ as a plain Nix
# function. The v2 resource model (lib/v2/) uses builtins.toFile for
# content-addressed resources, with dependency tracking via Nix store path
# context. lib/fixpoint/ provides the core resource primitives (mkResource,
# closure computation, registry).
#
# To build a cluster's manifests:
#   nix build .#cluster-example
#
# To build all clusters:
#   nix build .#cluster-nw1

{
  description = "kixpkgs - Kubernetes packages built with Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem =
        { pkgs, ... }:
        let
          lib = pkgs.lib;

          kixlib = import ./lib { inherit pkgs lib; };

          # v2 library — resource model using builtins.toFile + builtins.getContext.
          # Resources are store paths. No tree walker, no custom refs.
          kixv2 = import ./lib/v2 { inherit lib; };

          # v2 package registry
          v2Packages = {
            coredns = import ./packages/coredns;
            reloader = import ./packages/reloader;
            descheduler = import ./packages/descheduler;
            event-logger = import ./packages/event-logger;
            cluster-issuers = import ./packages/cluster-issuers;
            external-dns = import ./packages/external-dns;
            ingress-nginx = import ./packages/ingress-nginx;
            network-policies = import ./packages/network-policies;
            velero = import ./packages/velero;
            arc = import ./packages/arc;
            valkey = import ./packages/valkey;
            cert-manager = import ./packages/cert-manager;
          };

          # v2 cluster evaluations
          v2ClusterMinimal = import ./clusters/test-minimal.nix {
            inherit kixv2;
            packages = v2Packages;
          };
          v2ClusterExample = import ./clusters/example.nix {
            inherit kixv2;
            packages = v2Packages;
          };
          v2ClusterFull = import ./clusters/test-full.nix {
            inherit kixv2;
            packages = v2Packages;
          };
          v2ClusterJa1 = import ./clusters/nw1.nix {
            inherit kixv2;
            packages = v2Packages;
          };

          # Serializes v2 manifests (already post-processed) into YAML directory.
          mkV2Manifests =
            manifests:
            let
              fileEntries = map (
                m:
                let
                  kindLower = lib.toLower m.kind;
                  name = m.metadata.name;
                in
                {
                  fileName = "${name}-${kindLower}";
                  drv = kixlib.mkManifest m;
                }
              ) manifests;
            in
            pkgs.runCommand "k8s-v2-manifests" { } ''
              mkdir -p $out
              ${lib.concatStringsSep "\n" (map (e: "cp ${e.drv} $out/${e.fileName}.yaml") fileEntries)}
            '';

          # Offline K8s JSON schemas for kubeconform — the Nix sandbox has no
          # network access, so we can't let kubeconform download schemas at
          # build time. Sparse checkout to avoid fetching the entire (~2GB) repo.
          kubernetesSchemas = pkgs.fetchgit {
            url = "https://github.com/yannh/kubernetes-json-schema.git";
            rev = "5040e4b99f6b2b6fd3801c7798cce29a077acf56";
            sparseCheckout = [ "master-standalone-strict" ];
            hash = "sha256-izt9E+RqmGuxLLwggPsRjaSx/QXHz8ZlcluiyHawikw=";
          };

          # Helper: validate a manifest directory against K8s API schemas.
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

          # Convert v2 manifest list to an attrset keyed by {name}-{kind},
          # matching the shape expected by validateManifestSet.
          v2ManifestMap =
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
                || builtins.elem refName [
                  "admin"
                  "edit"
                  "view"
                ]
              ) bindings;

              # --- 3. ConfigMap volume references ---
              configMapVolRefs = builtins.concatMap (
                r:
                let
                  podSpec = getPodSpec r;
                  volumes = podSpec.volumes or [ ];
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

              serviceValidation = builtins.all (
                svc:
                let
                  selector = svc.spec.selector or { };
                in
                selector == { }
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

        in
        {
          legacyPackages = {
            inherit kixlib kixv2 v2Packages;
            inherit
              v2ClusterMinimal
              v2ClusterExample
              v2ClusterFull
              v2ClusterJa1
              ;
          };

          # Cluster manifest build targets.
          # `nix build .#<name>` builds any of these.
          packages = {
            cluster-minimal = mkV2Manifests v2ClusterMinimal.manifests;
            cluster-example = mkV2Manifests v2ClusterExample.manifests;
            cluster-full = mkV2Manifests v2ClusterFull.manifests;
            cluster-nw1 = mkV2Manifests v2ClusterJa1.manifests;
          };

          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [ pkgs.graphviz ];
          };

          checks =
            let
              exampleManifests = v2ManifestMap v2ClusterExample.manifests;
              fullManifests = v2ManifestMap v2ClusterFull.manifests;
              minimalManifests = v2ManifestMap v2ClusterMinimal.manifests;
              ja1Manifests = v2ManifestMap v2ClusterJa1.manifests;
            in
            {
              # --- Schema validation ---
              schema-cluster-example = schemaCheck "cluster-example" (mkV2Manifests v2ClusterExample.manifests);
              schema-cluster-full = schemaCheck "cluster-full" (mkV2Manifests v2ClusterFull.manifests);
              schema-cluster-minimal = schemaCheck "cluster-minimal" (mkV2Manifests v2ClusterMinimal.manifests);
              schema-cluster-nw1 = schemaCheck "cluster-nw1" (mkV2Manifests v2ClusterJa1.manifests);

              # --- Cross-resource validation ---
              validate-cluster-example =
                assert validateManifestSet "cluster-example" exampleManifests;
                pkgs.runCommand "validate-cluster-example" { } ''
                  echo "Cross-resource validation passed for cluster-example."
                  touch $out
                '';

              validate-cluster-full =
                assert validateManifestSet "cluster-full" fullManifests;
                pkgs.runCommand "validate-cluster-full" { } ''
                  echo "Cross-resource validation passed for cluster-full."
                  touch $out
                '';

              validate-cluster-minimal =
                assert validateManifestSet "cluster-minimal" minimalManifests;
                pkgs.runCommand "validate-cluster-minimal" { } ''
                  echo "Cross-resource validation passed for cluster-minimal."
                  touch $out
                '';

              validate-cluster-nw1 =
                assert validateManifestSet "cluster-nw1" ja1Manifests;
                pkgs.runCommand "validate-cluster-nw1" { } ''
                  echo "Cross-resource validation passed for cluster-nw1."
                  touch $out
                '';
            };
        };
    };
}
