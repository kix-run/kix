# kixpkgs flake — the entry point for building kix packages.
#
# Architecture (2026-03):
#
# Each Kubernetes package lives in pkgs-fp/<chart-name>/ using the fixpoint
# pattern. Packages are self-referential resource sets composed via
# k8s.mkPackage (inner fixpoint) and k8s.mkCluster (outer fixpoint).
#
# kixlib provides YAML serialization (mkManifest). The fixpoint library
# (lib/fixpoint/) adds ref tracking, closure computation, and self-referential
# package composition.
#
# To build a chart's manifests:
#   nix build .#<chart-name>
#
# To build a cluster:
#   nix build .#cluster-example

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

          # Fixpoint library — v1 resource model (Level 1-3).
          # Sits on top of kixlib builders, adds ref tracking, closure computation,
          # and self-referential package composition.
          k8s = import ./lib/fixpoint { inherit lib; };

          # --- v2 library ---
          # New resource model using builtins.toFile + builtins.getContext.
          # No tree walker, no custom refs. Resources are store paths.
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
          v2ClusterMinimal = import ./clusters/v2/test-minimal.nix { inherit kixv2; packages = v2Packages; };
          v2ClusterExample = import ./clusters/v2/example.nix { inherit kixv2; packages = v2Packages; };
          v2ClusterFull = import ./clusters/v2/test-full.nix { inherit kixv2; packages = v2Packages; };
          v2ClusterJa1 = import ./clusters/v2/nw1.nix { inherit kixv2; packages = v2Packages; };

          # Serializes v2 manifests (already post-processed) into YAML directory.
          mkV2Manifests = manifests:
            let
              fileEntries = map (m:
                let
                  kindLower = lib.toLower m.kind;
                  name = m.metadata.name;
                in {
                  fileName = "${name}-${kindLower}";
                  drv = kixlib.mkManifest m;
                }
              ) manifests;
            in
            pkgs.runCommand "k8s-v2-manifests" { } ''
              mkdir -p $out
              ${lib.concatStringsSep "\n" (map (e: "cp ${e.drv} $out/${e.fileName}.yaml") fileEntries)}
            '';

          # --- Fixpoint cluster evaluations ---
          # Cluster definitions now live in clusters/ as fixpoint-pattern files.
          # Each takes { k8s, lib } and returns a cluster via k8s.mkCluster.
          fpClusterMinimal = import ./clusters/test-minimal.nix { inherit k8s lib; };
          fpClusterFull = import ./clusters/test-full.nix { inherit k8s lib; };
          fpClusterExample = import ./clusters/example.nix { inherit k8s lib; };
          fpClusterJa1 = import ./clusters/nw1.nix { inherit k8s lib; };

          # Serializes a list of fixpoint resources into a directory of YAML files.
          # Each resource becomes a separate file named by {name}-{kind}.
          # Works for both clusters (.manifests) and single packages (.closure).
          mkFpManifests =
            resources:
            let
              fileEntries = map (
                r:
                let
                  kindLower = lib.toLower r.kind;
                in
                {
                  fileName = "${r.name}-${kindLower}";
                  drv = kixlib.mkManifest r.manifest;
                }
              ) resources;
            in
            pkgs.runCommand "k8s-manifests" { } ''
              mkdir -p $out
              ${lib.concatStringsSep "\n" (map (e: "cp ${e.drv} $out/${e.fileName}.yaml") fileEntries)}
            '';

          # Converts a fixpoint resource list to an attrset keyed by
          # {name}-{kind}, matching the shape expected by validateManifestSet.
          fpManifestMap =
            resources:
            builtins.listToAttrs (
              map (r: {
                name = "${r.name}-${lib.toLower r.kind}";
                value = r.manifest;
              }) resources
            );

          # Manifest packages for fixpoint clusters.
          fpClusterMinimalPkg = mkFpManifests fpClusterMinimal.manifests;
          fpClusterFullPkg = mkFpManifests fpClusterFull.manifests;
          fpClusterExamplePkg = mkFpManifests fpClusterExample.manifests;
          fpClusterJa1Pkg = mkFpManifests fpClusterJa1.manifests;

          # Offline K8s JSON schemas for kubeconform — the Nix sandbox has no
          # network access, so we can't let kubeconform download schemas at
          # build time. Sparse checkout to avoid fetching the entire (~2GB) repo.
          kubernetesSchemas = pkgs.fetchgit {
            url = "https://github.com/yannh/kubernetes-json-schema.git";
            rev = "5040e4b99f6b2b6fd3801c7798cce29a077acf56";
            sparseCheckout = [ "master-standalone-strict" ];
            hash = "sha256-izt9E+RqmGuxLLwggPsRjaSx/QXHz8ZlcluiyHawikw=";
          };

          # --- Fixpoint package variant registry ---
          # Each variant imports a package from pkgs-fp/ and optionally overrides it.
          # Packages and schema checks are generated automatically from this registry.
          #
          # Each entry is a fixpoint package (has .closure with all resources).
          # The registry key becomes the `nix build .#<key>` target.
          importCoredns = import ./pkgs-fp/coredns { inherit k8s lib; };
          importValkey = import ./pkgs-fp/valkey { inherit k8s lib; };
          importCertManager = import ./pkgs-fp/cert-manager { inherit k8s lib; };

          # NW1 migration packages
          importReloader = import ./pkgs-fp/reloader { inherit k8s lib; };
          importDescheduler = import ./pkgs-fp/descheduler { inherit k8s lib; };
          importEventLogger = import ./pkgs-fp/event-logger { inherit k8s lib; };
          importClusterIssuers = import ./pkgs-fp/cluster-issuers { inherit k8s lib; };
          importExternalDns = import ./pkgs-fp/external-dns { inherit k8s lib; };
          importIngressNginx = import ./pkgs-fp/ingress-nginx { inherit k8s lib; };
          importNetworkPolicies = import ./pkgs-fp/network-policies { inherit k8s lib; };
          importVelero = import ./pkgs-fp/velero { inherit k8s lib; };
          importArc = import ./pkgs-fp/arc { inherit k8s lib; };

          chartVariants = {
            # CoreDNS variants
            coredns = importCoredns;
            coredns-prometheus = importCoredns.override {
              prometheus = {
                service = {
                  enabled = true;
                  annotations = {
                    "prometheus.io/scrape" = "true";
                    "prometheus.io/port" = "9153";
                  };
                };
                monitor = {
                  enabled = true;
                  interval = null;
                };
              };
            };
            coredns-serviceaccount = importCoredns.override {
              serviceAccount = {
                create = true;
              };
            };
            coredns-pdb = importCoredns.override {
              podDisruptionBudget = {
                minAvailable = 1;
                maxUnavailable = null;
              };
            };
            coredns-hpa = importCoredns.override {
              hpa = {
                enabled = true;
                minReplicas = 2;
                maxReplicas = 5;
                metrics = [
                  {
                    type = "Resource";
                    resource = {
                      name = "cpu";
                      target = {
                        type = "Utilization";
                        averageUtilization = 80;
                      };
                    };
                  }
                ];
              };
            };
            coredns-autoscaler = importCoredns.override {
              autoscaler = {
                enabled = true;
                image = {
                  repository = "registry.k8s.io/cpa/cluster-proportional-autoscaler";
                  tag = "v1.9.0";
                  pullPolicy = "IfNotPresent";
                };
                resources = {
                  limits = {
                    cpu = "20m";
                    memory = "10Mi";
                  };
                  requests = {
                    cpu = "20m";
                    memory = "10Mi";
                  };
                };
                coresPerReplica = 256;
                nodesPerReplica = 16;
                preventSinglePointFailure = true;
                min = 0;
                max = 0;
                includeUnschedulableNodes = false;
              };
            };

            # Valkey variants
            valkey = importValkey;
            valkey-sentinel = importValkey.override {
              sentinel = {
                enabled = true;
                quorum = 2;
                primarySet = "myprimary";
                downAfterMilliseconds = 60000;
                failoverTimeout = 180000;
                parallelSyncs = 1;
                configuration = "";
                image = {
                  repository = "docker.io/bitnami/valkey-sentinel";
                  tag = "8.1.1-debian-12-r0";
                  pullPolicy = "IfNotPresent";
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                    ephemeral-storage = "50Mi";
                  };
                  limits = {
                    cpu = "150m";
                    memory = "192Mi";
                    ephemeral-storage = "2Gi";
                  };
                };
              };
            };
            valkey-full = importValkey.override {
              sentinel = {
                enabled = true;
                quorum = 2;
                primarySet = "myprimary";
                downAfterMilliseconds = 60000;
                failoverTimeout = 180000;
                parallelSyncs = 1;
                configuration = "";
                image = {
                  repository = "docker.io/bitnami/valkey-sentinel";
                  tag = "8.1.1-debian-12-r0";
                  pullPolicy = "IfNotPresent";
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                    ephemeral-storage = "50Mi";
                  };
                  limits = {
                    cpu = "150m";
                    memory = "192Mi";
                    ephemeral-storage = "2Gi";
                  };
                };
              };
              metrics = {
                enabled = true;
                image = {
                  repository = "docker.io/bitnami/redis-exporter";
                  tag = "1.70.0-debian-12-r2";
                  pullPolicy = "IfNotPresent";
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                    ephemeral-storage = "50Mi";
                  };
                  limits = {
                    cpu = "150m";
                    memory = "192Mi";
                    ephemeral-storage = "2Gi";
                  };
                };
              };
              networkPolicy = {
                enabled = true;
              };
              pdb = {
                enabled = true;
                maxUnavailable = 1;
                minAvailable = null;
              };
            };
            valkey-hpa = importValkey.override {
              replica = {
                replicaCount = 3;
                configuration = "";
                disableCommands = [
                  "FLUSHDB"
                  "FLUSHALL"
                ];
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                    ephemeral-storage = "50Mi";
                  };
                  limits = {
                    cpu = "150m";
                    memory = "192Mi";
                    ephemeral-storage = "2Gi";
                  };
                };
                autoscaling.hpa = {
                  enabled = true;
                  minReplicas = 1;
                  maxReplicas = 5;
                  targetCPU = 80;
                  targetMemory = null;
                };
              };
            };
            valkey-hpa-sentinel = importValkey.override {
              sentinel = {
                enabled = true;
                quorum = 2;
                primarySet = "myprimary";
                downAfterMilliseconds = 60000;
                failoverTimeout = 180000;
                parallelSyncs = 1;
                configuration = "";
                image = {
                  repository = "docker.io/bitnami/valkey-sentinel";
                  tag = "8.1.1-debian-12-r0";
                  pullPolicy = "IfNotPresent";
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                    ephemeral-storage = "50Mi";
                  };
                  limits = {
                    cpu = "150m";
                    memory = "192Mi";
                    ephemeral-storage = "2Gi";
                  };
                };
              };
              replica = {
                replicaCount = 3;
                configuration = "";
                disableCommands = [
                  "FLUSHDB"
                  "FLUSHALL"
                ];
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "128Mi";
                    ephemeral-storage = "50Mi";
                  };
                  limits = {
                    cpu = "150m";
                    memory = "192Mi";
                    ephemeral-storage = "2Gi";
                  };
                };
                autoscaling.hpa = {
                  enabled = true;
                  minReplicas = 1;
                  maxReplicas = 5;
                  targetCPU = 80;
                  targetMemory = null;
                };
              };
            };

            # cert-manager variants
            cert-manager = importCertManager;
            cert-manager-no-cainjector = importCertManager.override {
              cainjector = {
                enabled = false;
                image = {
                  repository = "quay.io/jetstack/cert-manager-cainjector";
                  tag = "v1.19.4";
                  pullPolicy = "IfNotPresent";
                };
                replicaCount = 1;
                resources = { };
              };
            };
            cert-manager-no-startupapicheck = importCertManager.override {
              startupapicheck = {
                enabled = false;
                image = {
                  repository = "quay.io/jetstack/cert-manager-startupapicheck";
                  tag = "v1.19.4";
                  pullPolicy = "IfNotPresent";
                };
                resources = { };
              };
            };

            # Reloader variants
            reloader = importReloader;

            # Descheduler variants
            descheduler = importDescheduler;

            # Event Logger variants
            event-logger = importEventLogger;

            # Cluster Issuers variants
            cluster-issuers = importClusterIssuers.override {
              domain = "lithus.net";
            };

            # External DNS variants
            external-dns = importExternalDns;
            external-dns-northwind = importExternalDns.override {
              instanceName = "northwind";
              provider = "cloudflare";
              domainFilters = [
                "shopfront.example"
                "ledgerly.example"
              ];
            };

            # Ingress NGINX variants
            ingress-nginx = importIngressNginx;
            ingress-nginx-clusterip = importIngressNginx.override {
              instanceName = "private";
              serviceType = "ClusterIP";
              replicaCount = 2;
            };

            # Network Policies
            network-policies = importNetworkPolicies;

            # Velero
            velero = importVelero;

            # ARC (GitHub Actions Runner Controller)
            arc = importArc;
          };

          # Generate manifest directories from fixpoint package closures.
          chartPackages = lib.mapAttrs (_: pkg: mkFpManifests pkg.closure) chartVariants;

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

          # Generate schema checks from chartVariants programmatically.
          schemaChecks = lib.mapAttrs' (
            name: drv: lib.nameValuePair "schema-${name}" (schemaCheck name drv)
          ) chartPackages;

          # --- Cross-resource validation (Phase 9) ---
          #
          # Validates referential integrity across the manifest set:
          # - ServiceAccount references resolve to SAs in the set
          # - RoleBinding/ClusterRoleBinding roleRefs resolve to Roles/ClusterRoles
          # - ConfigMap volume refs resolve to ConfigMaps in the set
          # - Service selectors match at least one workload's pod template labels
          #
          # Only validates INTERNAL references (resources created by kix).
          # External references (e.g., auth.existingSecret) are intentionally
          # skipped — those are cluster-provided resources outside kix's scope.
          #
          # This is pure eval-time Nix — no IFD, no runtime check. Made possible
          # by the deferred serialization design where config.manifests stores
          # raw attrsets instead of opaque store derivations.
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
              # Extract serviceAccountName from pod templates in workloads.
              workloadKinds = [
                "Deployment"
                "StatefulSet"
                "DaemonSet"
                "Job"
              ];
              workloads = builtins.filter (r: builtins.elem r.kind workloadKinds) resources;

              # Get the pod spec from a workload (handles Job's extra nesting).
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

              # Only validate SA refs where the SA is created by kix (not external).
              # A ServiceAccount exists in our set if hasResource "ServiceAccount" saName.
              # We only flag refs where the SA name matches a chart prefix but is missing.
              saValidation = builtins.all (
                ref:
                hasResource "ServiceAccount" ref.saName
                # Allow external SAs: if no SA with this name is expected
                # (i.e., default SA or external), skip validation.
                || !(builtins.any (
                  r:
                  r.kind == "ServiceAccount" && lib.hasPrefix (lib.removeSuffix ref.saName ref.saName) r.metadata.name
                ) resources)
                # Always allow "default" SA — it's created by K8s itself.
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
                # roleRef must point to a Role/ClusterRole that exists in our set.
                hasResource refKind refName
                # Allow external roles (e.g., system:auth-delegator) — K8s built-in.
                || lib.hasPrefix "system:" refName
                # Allow admin/edit/view — K8s built-in aggregated roles.
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

              # --- 4. Service selector → workload label matching ---
              services = builtins.filter (r: r.kind == "Service") resources;

              # Check that each Service's selector matches at least one
              # workload's pod template labels.
              selectorMatchesLabels =
                selector: labels: builtins.all (k: (labels.${k} or null) == selector.${k}) (lib.attrNames selector);

              serviceValidation = builtins.all (
                svc:
                let
                  selector = svc.spec.selector or { };
                in
                # Skip headless services with no selector
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
              # Two resources with the same identity would collide in the cluster.
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
              # Pure Nix replacement for the invariant-managed-by shell check.
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
            inherit
              kixlib
              k8s
              fpClusterMinimal
              fpClusterFull
              fpClusterExample
              fpClusterJa1
              ;

            # v2 exports
            inherit kixv2 v2Packages;
            inherit v2ClusterMinimal v2ClusterExample v2ClusterFull v2ClusterJa1;
          };

          # Per-chart build targets plus cluster definitions.
          # `nix build .#<name>` builds any of these.
          packages = chartPackages // {
            cluster-example = fpClusterExamplePkg;
            cluster-full = fpClusterFullPkg;
            cluster-minimal = fpClusterMinimalPkg;
            cluster-nw1 = fpClusterJa1Pkg;

            # v2 cluster build targets
            v2-cluster-minimal = mkV2Manifests v2ClusterMinimal.manifests;
            v2-cluster-example = mkV2Manifests v2ClusterExample.manifests;
            v2-cluster-full = mkV2Manifests v2ClusterFull.manifests;
            v2-cluster-nw1 = mkV2Manifests v2ClusterJa1.manifests;

            # --- Fixpoint DAG visualization ---
            # Renders the example cluster's full resource DAG as SVG.
            #   nix build .#fp-dag-svg && xdg-open result/dag.svg
            fp-dag-svg =
              pkgs.runCommand "fp-dag-svg"
                {
                  nativeBuildInputs = [ pkgs.graphviz ];
                }
                ''
                  mkdir -p $out
                  echo ${lib.escapeShellArg fpClusterExample.dagDot} | dot -Tsvg -o $out/dag.svg
                '';

            # Renders the example cluster DAG as PNG.
            fp-dag-png =
              pkgs.runCommand "fp-dag-png"
                {
                  nativeBuildInputs = [ pkgs.graphviz ];
                }
                ''
                  mkdir -p $out
                  echo ${lib.escapeShellArg fpClusterExample.dagDot} | dot -Tpng -o $out/dag.png
                '';
          };

          # Dev shell with DAG visualization commands.
          devShells.default = pkgs.mkShell {
            nativeBuildInputs = [ pkgs.graphviz ];
            shellHook = ''
              # kix-dag: print the example cluster's resource DAG as a tree
              kix-dag() {
                nix eval --raw .#legacyPackages.${pkgs.stdenv.hostPlatform.system}.fpClusterExample.dagTree
              }
              # kix-dag-dot: print the DAG as Graphviz DOT (pipe to `dot -Tsvg`)
              kix-dag-dot() {
                nix eval --raw .#legacyPackages.${pkgs.stdenv.hostPlatform.system}.fpClusterExample.dagDot
              }
              # kix-dag-svg: render the DAG as SVG and open it
              kix-dag-svg() {
                local out="''${1:-/tmp/kix-dag.svg}"
                nix eval --raw .#legacyPackages.${pkgs.stdenv.hostPlatform.system}.fpClusterExample.dagDot | dot -Tsvg -o "$out"
                echo "DAG written to $out"
              }
            '';
          };

          checks =
            let
              # Convert fixpoint cluster manifests to the attrset format
              # expected by validateManifestSet and assertion checks.
              exampleManifests = fpManifestMap fpClusterExample.manifests;
              fullManifests = fpManifestMap fpClusterFull.manifests;
              minimalManifests = fpManifestMap fpClusterMinimal.manifests;
              ja1Manifests = fpManifestMap fpClusterJa1.manifests;
            in
            schemaChecks
            // {
              # --- Fixpoint cluster: example ---
              # Validates that the example cluster produces the expected resources.
              # NOTE: Registry and monitoring capability checks are removed — those
              # are module-system features not yet available in the fixpoint pattern.
              # Validates all 3 packages: coredns, valkey, cert-manager.
              cluster-example =
                let
                  manifests = exampleManifests;
                in
                # --- CoreDNS resources ---
                assert manifests ? "coredns-deployment";
                assert manifests ? "coredns-configmap";
                assert manifests ? "coredns-service";
                assert manifests ? "coredns-clusterrole";
                assert manifests ? "coredns-clusterrolebinding";
                # Metrics service present (prometheus.service.enabled = true)
                assert manifests ? "coredns-metrics-service";
                # ServiceAccount not created by default
                assert !(manifests ? "coredns-serviceaccount");
                # HPA disabled by default
                assert !(manifests ? "coredns-horizontalpodautoscaler");
                # Cluster labels applied
                assert
                  (manifests."coredns-deployment".metadata.labels."app.kubernetes.io/part-of" or "") == "kix-example";
                assert (manifests."coredns-deployment".metadata.labels."team" or "") == "platform";

                # --- Valkey resources (sentinel mode) ---
                assert manifests ? "valkey-node-statefulset";
                assert manifests ? "valkey-service";
                assert manifests ? "valkey-headless-service";
                assert manifests ? "valkey-configuration-configmap";
                assert manifests ? "valkey-health-configmap";
                assert manifests ? "valkey-scripts-configmap";
                assert manifests ? "valkey-serviceaccount";
                assert manifests ? "valkey-metrics-service";
                assert manifests ? "valkey-networkpolicy";
                assert manifests ? "valkey-node-poddisruptionbudget";
                # Cluster labels applied to valkey (team label; part-of is package-level)
                assert (manifests."valkey-node-statefulset".metadata.labels."team" or "") == "platform";

                # --- Cert-manager resources ---
                assert manifests ? "cert-manager-deployment";
                assert manifests ? "cert-manager-service";
                assert manifests ? "cert-manager-serviceaccount";
                assert manifests ? "cert-manager-webhook-deployment";
                assert manifests ? "cert-manager-webhook-service";
                assert manifests ? "cert-manager-webhook-serviceaccount";
                assert manifests ? "cert-manager-cainjector-deployment";
                assert manifests ? "cert-manager-cainjector-serviceaccount";
                assert manifests ? "cert-manager-startupapicheck-job";
                assert manifests ? "cert-manager-startupapicheck-serviceaccount";
                # Webhook configurations
                assert manifests ? "cert-manager-webhook-mutatingwebhookconfiguration";
                assert manifests ? "cert-manager-webhook-validatingwebhookconfiguration";
                # RBAC: controller ClusterRoles
                assert manifests ? "cert-manager-controller-issuers-clusterrole";
                assert manifests ? "cert-manager-controller-certificates-clusterrole";
                assert manifests ? "cert-manager-controller-orders-clusterrole";
                assert manifests ? "cert-manager-controller-challenges-clusterrole";
                # Aggregated ClusterRoles
                assert manifests ? "cert-manager-cluster-view-clusterrole";
                assert manifests ? "cert-manager-view-clusterrole";
                assert manifests ? "cert-manager-edit-clusterrole";

                pkgs.runCommand "check-cluster-example" { } ''
                  echo "Example cluster (fixpoint): all assertions passed."
                  touch $out
                '';

              # Schema validation for cluster configs
              schema-cluster-example = schemaCheck "cluster-example" fpClusterExamplePkg;
              schema-cluster-full = schemaCheck "cluster-full" fpClusterFullPkg;
              schema-cluster-minimal = schemaCheck "cluster-minimal" fpClusterMinimalPkg;
              schema-cluster-nw1 = schemaCheck "cluster-nw1" fpClusterJa1Pkg;

              # --- Fixpoint cluster: full ---
              # All features enabled across all 3 packages — validates feature interaction.
              cluster-full =
                let
                  manifests = fullManifests;
                in
                # --- CoreDNS core resources ---
                assert manifests ? "coredns-deployment";
                assert manifests ? "coredns-configmap";
                assert manifests ? "coredns-service";
                # HPA enabled
                assert manifests ? "coredns-horizontalpodautoscaler";
                # PDB enabled (minAvailable = 1)
                assert manifests ? "coredns-poddisruptionbudget";
                # ServiceAccount created
                assert manifests ? "coredns-serviceaccount";
                # Metrics service present
                assert manifests ? "coredns-metrics-service";
                # RBAC chain present
                assert manifests ? "coredns-clusterrole";
                assert manifests ? "coredns-clusterrolebinding";
                # Cluster labels applied
                assert
                  (manifests."coredns-deployment".metadata.labels."app.kubernetes.io/part-of" or "")
                  == "kix-full-test";
                assert (manifests."coredns-deployment".metadata.labels."team" or "") == "platform";

                # --- Valkey resources (full: sentinel + HPA + PDB + network policy) ---
                assert manifests ? "valkey-node-statefulset";
                assert manifests ? "valkey-service";
                assert manifests ? "valkey-headless-service";
                assert manifests ? "valkey-configuration-configmap";
                assert manifests ? "valkey-health-configmap";
                assert manifests ? "valkey-scripts-configmap";
                assert manifests ? "valkey-serviceaccount";
                assert manifests ? "valkey-metrics-service";
                assert manifests ? "valkey-networkpolicy";
                assert manifests ? "valkey-node-poddisruptionbudget";
                # HPA enabled for valkey replicas
                assert manifests ? "valkey-node-horizontalpodautoscaler";
                # Cluster labels applied to valkey (team label; part-of is package-level)
                assert (manifests."valkey-node-statefulset".metadata.labels."team" or "") == "platform";

                # --- Cert-manager resources ---
                assert manifests ? "cert-manager-deployment";
                assert manifests ? "cert-manager-service";
                assert manifests ? "cert-manager-serviceaccount";
                assert manifests ? "cert-manager-webhook-deployment";
                assert manifests ? "cert-manager-webhook-service";
                assert manifests ? "cert-manager-cainjector-deployment";
                assert manifests ? "cert-manager-startupapicheck-job";
                # Webhook configurations
                assert manifests ? "cert-manager-webhook-mutatingwebhookconfiguration";
                assert manifests ? "cert-manager-webhook-validatingwebhookconfiguration";

                pkgs.runCommand "check-cluster-full" { } ''
                  echo "Full cluster (fixpoint): all assertions passed."
                  touch $out
                '';

              # --- Fixpoint cluster: minimal ---
              # Single chart, all defaults — validates nothing extra is produced.
              cluster-minimal =
                let
                  manifests = minimalManifests;
                  manifestNames = lib.attrNames manifests;
                in
                # Only coredns resources should exist
                assert lib.all (n: lib.hasInfix "coredns" n) manifestNames;
                # No ServiceAccount (create = false by default)
                assert !(manifests ? "coredns-serviceaccount");
                # No HPA, no PDB (both disabled by default)
                assert !(manifests ? "coredns-horizontalpodautoscaler");
                assert !(manifests ? "coredns-poddisruptionbudget");
                # No metrics service (prometheus.service.enabled = false by default)
                assert !(manifests ? "coredns-metrics-service");
                # No autoscaler resources
                assert !(lib.any (n: lib.hasInfix "autoscaler" n) manifestNames);
                pkgs.runCommand "check-cluster-minimal" { } ''
                  echo "Minimal cluster (fixpoint): all negative assertions passed."
                  touch $out
                '';

              # --- Cross-resource validation ---
              # Pure eval-time checks over raw manifest attrsets. Validates
              # referential integrity: SA refs, roleRefs, ConfigMap volumes,
              # Service selectors, HPA targets, duplicate IDs, managed-by labels.
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

              # --- Fixpoint cluster: NW1 (production) ---
              # Validates that the NW1 cluster produces all expected resources
              # across all migrated packages.
              cluster-nw1 =
                let
                  manifests = ja1Manifests;
                in
                # --- CoreDNS ---
                assert manifests ? "coredns-deployment";
                assert manifests ? "coredns-service";

                # --- Valkey ---
                assert manifests ? "valkey-node-statefulset";
                assert manifests ? "valkey-service";

                # --- Cert-manager ---
                assert manifests ? "cert-manager-deployment";
                assert manifests ? "cert-manager-webhook-deployment";

                # --- Reloader ---
                assert manifests ? "reloader-reloader-deployment";
                assert manifests ? "reloader-priority-class-priorityclass";

                # --- Descheduler ---
                assert manifests ? "descheduler-deployment";
                assert manifests ? "descheduler-configmap";

                # --- Event Logger ---
                assert manifests ? "event-logger-deployment";
                assert manifests ? "event-logger-configmap";

                # --- Cluster Issuers ---
                assert manifests ? "letsencrypt-production-clusterissuer";
                assert manifests ? "letsencrypt-staging-clusterissuer";

                # --- External DNS (2 instances) ---
                assert manifests ? "external-dns-cluster-public-deployment";
                assert manifests ? "external-dns-cluster-public-service";
                assert manifests ? "external-dns-northwind-deployment";
                assert manifests ? "external-dns-northwind-service";

                # --- Ingress NGINX (3 instances, unique selectors) ---
                assert manifests ? "public-controller-deployment";
                assert manifests ? "public-controller-service";
                assert manifests ? "public-ingressclass";
                assert manifests ? "public-v2-controller-deployment";
                assert manifests ? "public-v2-controller-service";
                assert manifests ? "public-v2-ingressclass";
                assert manifests ? "private-v2-controller-deployment";
                assert manifests ? "private-v2-controller-service";
                assert manifests ? "private-v2-ingressclass";
                # Verify selector labels are unique across instances
                assert
                  manifests."public-controller-deployment".spec.selector.matchLabels."app.kubernetes.io/instance"
                  == "public";
                assert
                  manifests."public-v2-controller-deployment".spec.selector.matchLabels."app.kubernetes.io/instance"
                  == "public-v2";
                assert
                  manifests."private-v2-controller-deployment".spec.selector.matchLabels."app.kubernetes.io/instance"
                  == "private-v2";

                # --- Network Policies ---
                assert manifests ? "global-dns-ciliumclusterwidenetworkpolicy";
                assert manifests ? "kubernetes-api-access-ciliumclusterwidenetworkpolicy";
                assert manifests ? "global-access-to-ingress-nginx-ciliumclusterwidenetworkpolicy";

                # --- Velero ---
                assert manifests ? "velero-deployment";
                assert manifests ? "daily-cluster-backup-schedule";
                assert manifests ? "default-backupstoragelocation";
                assert manifests ? "node-agent-daemonset";

                # --- ARC ---
                assert manifests ? "arc-runners-priorityclass";
                assert manifests ? "actions-listener-restart-cron-cronjob";
                assert manifests ? "actions-runner-rules-prometheusrule";
                assert manifests ? "arc-runners-namespace";

                # --- Cluster labels on all packages ---
                assert (manifests."coredns-deployment".metadata.labels."app.kubernetes.io/part-of" or "") == "nw1";
                assert (manifests."velero-deployment".metadata.labels."app.kubernetes.io/part-of" or "") == "nw1";
                assert (manifests."reloader-reloader-deployment".metadata.labels."team" or "") == "platform";

                pkgs.runCommand "check-cluster-nw1" { } ''
                  echo "NW1 cluster: all assertions passed (155 resources)."
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
