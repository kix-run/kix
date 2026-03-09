# kixpkgs flake — the entry point for building kix modules.
#
# Architecture (2026-03):
#
# Each Helm chart migration lives in pkgs/<chart-name>/ as a Nix module.
# Modules are evaluated using lib.evalModules (the NixOS module system),
# which gives us typed options, submodules, and cross-module references.
#
# kixlib is passed to every module via specialArgs. It provides resource
# builders (mkDeployment, mkService, etc.) that produce plain attrsets.
#
# Each module writes its resources to config.manifests.<name> as raw attrsets
# (with kind, apiVersion, metadata, etc.). Serialization to JSON store
# derivations is deferred to mkManifests — the output boundary. This keeps
# structured data available throughout the module system for cross-resource
# validation, behavioral invariants, and any module that needs to inspect
# other charts' resources.
#
# To build a chart's manifests:
#   nix build .#<chart-name>
#
# To evaluate without building (useful for debugging):
#   nix eval .#legacyPackages.<system>.mkCluster { ... }

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

          # Offline K8s JSON schemas for kubeconform — the Nix sandbox has no
          # network access, so we can't let kubeconform download schemas at
          # build time. Sparse checkout to avoid fetching the entire (~2GB) repo.
          kubernetesSchemas = pkgs.fetchgit {
            url = "https://github.com/yannh/kubernetes-json-schema.git";
            rev = "5040e4b99f6b2b6fd3801c7798cce29a077acf56";
            sparseCheckout = [ "master-standalone-strict" ];
            hash = "sha256-izt9E+RqmGuxLLwggPsRjaSx/QXHz8ZlcluiyHawikw=";
          };

          # Evaluate modules with a given config.
          #
          # `chartModules` — list of chart module paths to include
          #   (e.g., [ ./pkgs/coredns ])
          # `config` — the user's config module that sets options
          #   (e.g., { services.coredns.enable = true; replicas = 3; })
          #
          # The base ./modules provides the `manifests` option that all chart
          # modules write into. Each chart module adds its own options under
          # services.<name> and its resources under config.manifests.
          mkCluster =
            { chartModules ? [ ], config ? { } }:
            lib.evalModules {
              modules = [
                ./modules
              ] ++ chartModules ++ [
                config
              ];
              specialArgs = {
                inherit pkgs lib kixlib;
              };
            };

          # Collect all manifests from an evaluation into a directory.
          # Each manifest becomes a separate .json file, named by its key
          # in config.manifests.
          #
          # SERIALIZATION BOUNDARY: config.manifests stores raw attrsets
          # (with kind, apiVersion, metadata, etc.). This function is the
          # sole point where attrsets become JSON store derivations. This
          # keeps structured data available throughout the module system for
          # cross-resource validation and behavioral invariants.
          mkManifests =
            evaluation:
            let
              serialized = lib.mapAttrs (name: resource:
                kixlib.mkManifest resource
              ) evaluation.config.manifests;
            in
            pkgs.runCommand "k8s-manifests" { } ''
              mkdir -p $out
              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (
                  name: path: "cp ${path} $out/${name}.yaml"
                ) serialized
              )}
            '';

          # Convenience: evaluate a single chart with a config and build manifests.
          # This is what the flake packages use:
          #   packages.coredns = mkChartManifests ./pkgs/coredns {
          #     services.coredns.enable = true;
          #   };
          mkChartManifests =
            chartPath: config:
            mkManifests (mkCluster {
              chartModules = [ chartPath ];
              config = config;
            });

          # --- Programmatic chart variant registry ---
          # Instead of 16 manual `<name>Pkg = mkChartManifests ./pkgs/<chart> { ... }`
          # definitions, all single-chart variants are declared in one data structure.
          # Adding a new variant is a single line — the packages and schema checks
          # are generated automatically below.
          chartVariants = {
            # CoreDNS variants
            coredns = { chart = ./pkgs/coredns; config.services.coredns.enable = true; };
            coredns-prometheus = { chart = ./pkgs/coredns; config.services.coredns = {
              enable = true;
              prometheus.service.enabled = true;
              prometheus.monitor.enabled = true;
            }; };
            coredns-serviceaccount = { chart = ./pkgs/coredns; config.services.coredns = {
              enable = true;
              serviceAccount.create = true;
            }; };
            coredns-pdb = { chart = ./pkgs/coredns; config.services.coredns = {
              enable = true;
              podDisruptionBudget.minAvailable = 1;
            }; };
            coredns-hpa = { chart = ./pkgs/coredns; config.services.coredns = {
              enable = true;
              hpa = {
                enabled = true;
                minReplicas = 2;
                maxReplicas = 5;
                metrics = [{
                  type = "Resource";
                  resource = {
                    name = "cpu";
                    target = {
                      type = "Utilization";
                      averageUtilization = 80;
                    };
                  };
                }];
              };
            }; };
            coredns-autoscaler = { chart = ./pkgs/coredns; config.services.coredns = {
              enable = true;
              autoscaler.enabled = true;
            }; };

            # Valkey variants
            valkey = { chart = ./pkgs/valkey; config.services.valkey.enable = true; };
            valkey-sentinel = { chart = ./pkgs/valkey; config.services.valkey = {
              enable = true;
              sentinel.enabled = true;
            }; };
            valkey-full = { chart = ./pkgs/valkey; config.services.valkey = {
              enable = true;
              sentinel.enabled = true;
              metrics.enabled = true;
              metrics.serviceMonitor.enabled = true;
              networkPolicy.enabled = true;
              pdb.enabled = true;
            }; };
            valkey-podmonitor = { chart = ./pkgs/valkey; config.services.valkey = {
              enable = true;
              sentinel.enabled = true;
              metrics.enabled = true;
              metrics.serviceMonitor.enabled = true;
              metrics.podMonitor.enabled = true;
              networkPolicy.enabled = true;
            }; };
            valkey-prometheusrule = { chart = ./pkgs/valkey; config.services.valkey = {
              enable = true;
              sentinel.enabled = true;
              metrics.enabled = true;
              metrics.serviceMonitor.enabled = true;
              metrics.prometheusRule = {
                enabled = true;
                rules = [{
                  alert = "ValkeyDown";
                  expr = "valkey_up == 0";
                  "for" = "5m";
                  labels.severity = "critical";
                }];
              };
              networkPolicy.enabled = true;
            }; };
            valkey-hpa = { chart = ./pkgs/valkey; config.services.valkey = {
              enable = true;
              replica.autoscaling.hpa = {
                enabled = true;
                minReplicas = 1;
                maxReplicas = 5;
                targetCPU = 80;
              };
            }; };
            valkey-hpa-sentinel = { chart = ./pkgs/valkey; config.services.valkey = {
              enable = true;
              sentinel.enabled = true;
              replica.autoscaling.hpa = {
                enabled = true;
                minReplicas = 1;
                maxReplicas = 5;
                targetCPU = 80;
              };
            }; };

            # cert-manager variants
            cert-manager = { chart = ./pkgs/cert-manager; config.services.cert-manager.enable = true; };
            cert-manager-no-cainjector = { chart = ./pkgs/cert-manager; config.services.cert-manager = {
              enable = true;
              cainjector.enabled = false;
            }; };
            cert-manager-no-startupapicheck = { chart = ./pkgs/cert-manager; config.services.cert-manager = {
              enable = true;
              startupapicheck.enabled = false;
            }; };
          };

          # Generate package derivations from chartVariants.
          chartPackages = lib.mapAttrs (_: v:
            mkChartManifests v.chart v.config
          ) chartVariants;

          # Multi-chart cluster evaluation — kept separate because it uses
          # multiple chart modules and has its own assertion-based check.
          exampleEval = mkCluster {
            chartModules = [
              ./pkgs/coredns
              ./pkgs/valkey
              ./pkgs/cert-manager
            ];
            config = import ./clusters/example.nix;
          };

          clusterExamplePkg = mkManifests exampleEval;

          # --- Additional test clusters ---
          # Full cluster: all features enabled
          fullEval = mkCluster {
            chartModules = [ ./pkgs/coredns ./pkgs/valkey ./pkgs/cert-manager ];
            config = import ./clusters/test-full.nix;
          };
          clusterFullPkg = mkManifests fullEval;

          # Minimal cluster: single chart, all defaults
          minimalEval = mkCluster {
            chartModules = [ ./pkgs/coredns ];
            config = import ./clusters/test-minimal.nix;
          };
          clusterMinimalPkg = mkManifests minimalEval;

          # Helper: validate a manifest directory against K8s API schemas.
          # Skips Prometheus Operator CRDs since kubeconform doesn't have
          # their schemas built-in.
          schemaCheck = name: drv: pkgs.runCommand "schema-${name}" {
            nativeBuildInputs = [ pkgs.kubeconform ];
          } ''
            echo "Validating ${name}..."
            kubeconform -strict -summary \
              -ignore-missing-schemas \
              -schema-location '${kubernetesSchemas}/master-standalone-strict/{{ .ResourceKind }}{{ .KindSuffix }}.json' \
              ${drv}/*.yaml
            touch $out
          '';

          # Generate schema checks from chartVariants programmatically.
          schemaChecks = lib.mapAttrs' (name: drv:
            lib.nameValuePair "schema-${name}" (schemaCheck name drv)
          ) chartPackages;

          # Golden-file snapshot tests — compares built manifests against
          # checked-in golden files. Run `./scripts/update-golden.sh` to
          # regenerate after intentional changes.
          goldenCheck = name: drv: pkgs.runCommand "golden-${name}" {
            nativeBuildInputs = [ pkgs.diffutils ];
          } ''
            fail=0
            # Check each built manifest matches its golden file
            for f in ${drv}/*.yaml; do
              base=$(basename "$f")
              golden="${./tests}/${name}/golden/$base"
              if [ ! -f "$golden" ]; then
                echo "FAIL: $base is new (no golden file)"
                fail=1
                continue
              fi
              if ! diff -u "$golden" "$f"; then
                echo "FAIL: $base differs from golden"
                fail=1
              fi
            done
            # Check for removed resources (golden file with no matching output)
            for f in ${./tests}/${name}/golden/*.yaml; do
              base=$(basename "$f")
              if [ ! -f "${drv}/$base" ]; then
                echo "FAIL: $base removed (golden file exists but no output)"
                fail=1
              fi
            done
            [ "$fail" -eq 0 ] || exit 1
            touch $out
          '';

          # Generate golden checks for all variants that have golden dirs.
          goldenChecks = lib.mapAttrs' (name: drv:
            lib.nameValuePair "golden-${name}" (goldenCheck name drv)
          ) (lib.filterAttrs (name: _:
            builtins.pathExists (./tests + "/${name}/golden")
          ) (chartPackages // { cluster-example = clusterExamplePkg; }));

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
          validateManifestSet = clusterName: manifests:
            let
              resources = lib.attrValues manifests;

              # Index resources by (kind, name) for lookup.
              byKindName = builtins.foldl' (acc: r:
                let
                  name = r.metadata.name or "";
                  kind = r.kind;
                in acc // { "${kind}:${name}" = r; }
              ) {} resources;

              hasResource = kind: name: byKindName ? "${kind}:${name}";

              # --- 1. ServiceAccount references ---
              # Extract serviceAccountName from pod templates in workloads.
              workloadKinds = [ "Deployment" "StatefulSet" "DaemonSet" "Job" ];
              workloads = builtins.filter (r: builtins.elem r.kind workloadKinds) resources;

              # Get the pod spec from a workload (handles Job's extra nesting).
              getPodSpec = r:
                if r.kind == "Job"
                then r.spec.template.spec or {}
                else r.spec.template.spec or {};

              saRefs = builtins.concatMap (r:
                let
                  podSpec = getPodSpec r;
                  saName = podSpec.serviceAccountName or null;
                in
                if saName != null
                then [{ workload = r.metadata.name; inherit saName; kind = r.kind; }]
                else []
              ) workloads;

              # Only validate SA refs where the SA is created by kix (not external).
              # A ServiceAccount exists in our set if hasResource "ServiceAccount" saName.
              # We only flag refs where the SA name matches a chart prefix but is missing.
              saValidation = builtins.all (ref:
                hasResource "ServiceAccount" ref.saName
                # Allow external SAs: if no SA with this name is expected
                # (i.e., default SA or external), skip validation.
                || !(builtins.any (r:
                  r.kind == "ServiceAccount" && lib.hasPrefix (lib.removeSuffix ref.saName ref.saName) r.metadata.name
                ) resources)
                # Always allow "default" SA — it's created by K8s itself.
                || ref.saName == "default"
              ) saRefs;

              # --- 2. RoleBinding/ClusterRoleBinding roleRef validation ---
              bindingKinds = [ "RoleBinding" "ClusterRoleBinding" ];
              bindings = builtins.filter (r: builtins.elem r.kind bindingKinds) resources;

              roleRefValidation = builtins.all (binding:
                let
                  ref = binding.roleRef or {};
                  refKind = ref.kind or "";
                  refName = ref.name or "";
                in
                # roleRef must point to a Role/ClusterRole that exists in our set.
                hasResource refKind refName
                # Allow external roles (e.g., system:auth-delegator) — K8s built-in.
                || lib.hasPrefix "system:" refName
                # Allow admin/edit/view — K8s built-in aggregated roles.
                || builtins.elem refName [ "admin" "edit" "view" ]
              ) bindings;

              # --- 3. ConfigMap volume references ---
              configMapVolRefs = builtins.concatMap (r:
                let
                  podSpec = getPodSpec r;
                  volumes = podSpec.volumes or [];
                in
                builtins.concatMap (vol:
                  let cmName = vol.configMap.name or null;
                  in if cmName != null
                     then [{ workload = r.metadata.name; inherit cmName; }]
                     else []
                ) volumes
              ) workloads;

              configMapValidation = builtins.all (ref:
                hasResource "ConfigMap" ref.cmName
              ) configMapVolRefs;

              # --- 4. Service selector → workload label matching ---
              services = builtins.filter (r: r.kind == "Service") resources;

              # Check that each Service's selector matches at least one
              # workload's pod template labels.
              selectorMatchesLabels = selector: labels:
                builtins.all (k:
                  (labels.${k} or null) == selector.${k}
                ) (lib.attrNames selector);

              serviceValidation = builtins.all (svc:
                let
                  selector = svc.spec.selector or {};
                in
                # Skip headless services with no selector
                selector == {}
                || builtins.any (w:
                  let
                    templateLabels = w.spec.template.metadata.labels or {};
                  in selectorMatchesLabels selector templateLabels
                ) workloads
              ) services;

              # --- 5. HPA scaleTargetRef validation ---
              hpas = builtins.filter (r: r.kind == "HorizontalPodAutoscaler") resources;

              hpaValidation = builtins.all (hpa:
                let ref = hpa.spec.scaleTargetRef or {};
                in hasResource (ref.kind or "") (ref.name or "")
              ) hpas;

              # --- 6. No duplicate (kind, namespace, name) tuples ---
              # Two resources with the same identity would collide in the cluster.
              resourceIds = map (r:
                let
                  ns = r.metadata.namespace or null;
                  nsStr = if ns == null then "cluster-scoped" else ns;
                  name = r.metadata.name or "unnamed";
                in "${r.kind}/${nsStr}/${name}"
              ) resources;
              uniqueIds = lib.unique resourceIds;
              noDuplicateIds = builtins.length resourceIds == builtins.length uniqueIds;

              # --- 7. managed-by label on all resources ---
              # Pure Nix replacement for the invariant-managed-by shell check.
              managedByValidation = builtins.all (r:
                (r.metadata.labels."app.kubernetes.io/managed-by" or "") == "kix"
              ) resources;

              # --- Collect failures for clear error messages ---
              failures =
                (lib.optional (!saValidation)
                  "ServiceAccount reference validation failed")
                ++ (lib.optional (!roleRefValidation)
                  "RoleBinding roleRef validation failed — a binding references a Role/ClusterRole not in the manifest set")
                ++ (lib.optional (!configMapValidation)
                  "ConfigMap volume reference validation failed — a workload references a ConfigMap not in the manifest set")
                ++ (lib.optional (!serviceValidation)
                  "Service selector validation failed — a Service's selector doesn't match any workload's pod template labels")
                ++ (lib.optional (!hpaValidation)
                  "HPA scaleTargetRef validation failed — an HPA targets a workload not in the manifest set")
                ++ (lib.optional (!noDuplicateIds)
                  "Duplicate resource identity (kind/namespace/name) detected")
                ++ (lib.optional (!managedByValidation)
                  "managed-by label validation failed — a resource is missing app.kubernetes.io/managed-by=kix");
            in
            if failures == []
            then true
            else throw "validateManifestSet(${clusterName}): ${lib.concatStringsSep "; " failures}";

        in
        {
          legacyPackages = {
            inherit mkCluster mkManifests mkChartManifests kixlib;
          };

          # Per-chart build targets for parity testing, plus cluster definitions.
          # `nix build .#<name>` builds any of these.
          packages = chartPackages // {
            cluster-example = clusterExamplePkg;
            cluster-full = clusterFullPkg;
            cluster-minimal = clusterMinimalPkg;
          };

          checks = let
            reg = exampleEval.config.registry;
            caps = exampleEval.config.capabilities.monitoring;
            manifests = exampleEval.config.manifests;
          in schemaChecks // goldenChecks // {
            # --- Structural checks for multi-chart composition ---
            # Eval-time assertions validate that intent merging works across
            # charts. If any assertion fails, Nix aborts before the runCommand
            # executes, with a clear error message.
            cluster-example = let
              # Registry: all charts populated with non-empty hosts and correct values
              assertRegistry =
                assert reg.coredns.endpoints.dns-udp.host != "";
                assert reg.coredns.endpoints.dns-tcp.host != "";
                assert reg.coredns.endpoints.dns-udp.port == 53;
                assert reg.coredns.endpoints.dns-udp.protocol == "dns-udp";
                assert reg.valkey.endpoints.primary.host != "";
                assert reg.valkey.endpoints.primary.port == 6379;
                assert reg.valkey.endpoints.primary.protocol == "redis";
                assert reg.valkey.endpoints.sentinel.host != "";
                assert reg.valkey.endpoints.sentinel.port == 26379;
                assert reg.valkey.endpoints.metrics.host != "";
                assert reg.valkey.endpoints.metrics.port == 9121;
                assert reg.cert-manager.endpoints.webhook.port == 443;
                assert reg.cert-manager.endpoints.webhook.protocol == "https";
                assert reg.cert-manager.endpoints.metrics.port == 9402;
                true;

              # Registry ownership: each registry key must match a chart that
              # actually produced manifests with that prefix. Catches copy-paste
              # errors where a chart accidentally writes to another chart's
              # registry entry (e.g., valkey writing to registry.coredns).
              registryKeys = lib.attrNames reg;
              assertOwnership = lib.all (key:
                lib.any (mName: lib.hasPrefix "${key}-" mName || mName == key)
                  (lib.attrNames manifests)
              ) registryKeys;

              # V4 Capabilities: implementation module created ServiceMonitors,
              # per-chart ones were suppressed. Verify capability inputs and outputs.
              assertMonitoring =
                # Capability inputs populated correctly
                assert caps.valkey.serviceName == "valkey-metrics";
                assert caps.valkey.portName == "http-metrics";
                assert caps.coredns.serviceName == "coredns-metrics";
                assert caps.coredns.portName == "metrics";
                assert caps.cert-manager.serviceName == "cert-manager";
                assert caps.cert-manager-webhook.serviceName == "cert-manager-webhook";
                assert caps.cert-manager-cainjector.serviceName == "cert-manager-cainjector";
                # ServiceMonitors created by implementation module
                assert manifests ? "monitoring-valkey-servicemonitor";
                assert manifests ? "monitoring-coredns-servicemonitor";
                assert manifests ? "monitoring-cert-manager-servicemonitor";
                assert manifests ? "monitoring-cert-manager-webhook-servicemonitor";
                assert manifests ? "monitoring-cert-manager-cainjector-servicemonitor";
                # Per-chart ServiceMonitors suppressed
                assert !(manifests ? "valkey-servicemonitor");
                assert !(manifests ? "coredns-servicemonitor");
                # Metrics Service should still exist (ServiceMonitor targets it)
                assert manifests ? "coredns-service-metrics";
                # V4 writeback: output labels populated by implementation module
                assert caps.coredns.output.labels ? "kix.monitoring/scrape";
                assert caps.valkey.output.labels ? "kix.monitoring/scrape";
                assert caps.cert-manager.output.labels ? "kix.monitoring/scrape";
                true;

              # Negative assertions: disabled features must not produce resources
              assertNegative =
                # CoreDNS serviceAccount.create is false by default
                assert !(manifests ? "coredns-serviceaccount");
                # CoreDNS HPA is disabled by default
                assert !(manifests ? "coredns-hpa");
                true;

            in assert assertRegistry; assert assertOwnership; assert assertMonitoring; assert assertNegative;
            pkgs.runCommand "check-cluster-example" {} ''
              echo "Registry: coredns dns-udp=${reg.coredns.endpoints.dns-udp.host}:${toString reg.coredns.endpoints.dns-udp.port}"
              echo "Registry: valkey primary=${reg.valkey.endpoints.primary.host}:${toString reg.valkey.endpoints.primary.port}"
              echo "Registry: valkey sentinel=${reg.valkey.endpoints.sentinel.host}:${toString reg.valkey.endpoints.sentinel.port}"
              echo "Registry: valkey metrics=${reg.valkey.endpoints.metrics.host}:${toString reg.valkey.endpoints.metrics.port}"
              echo "Registry: cert-manager webhook=${reg.cert-manager.endpoints.webhook.host}:${toString reg.cert-manager.endpoints.webhook.port}"
              echo "Registry: cert-manager metrics=${reg.cert-manager.endpoints.metrics.host}:${toString reg.cert-manager.endpoints.metrics.port}"
              echo "Monitoring: valkey capability=${caps.valkey.serviceName}:${caps.valkey.portName}"
              echo "Monitoring: cert-manager capability=${caps.cert-manager.serviceName}"
              echo "All structural assertions passed."
              touch $out
            '';

            # Schema validation for cluster configs (not in chartVariants)
            schema-cluster-example = schemaCheck "cluster-example" clusterExamplePkg;
            schema-cluster-full = schemaCheck "cluster-full" clusterFullPkg;
            schema-cluster-minimal = schemaCheck "cluster-minimal" clusterMinimalPkg;

            # --- Composition test: full cluster ---
            # All features enabled — validates feature interaction.
            cluster-full = let
              freg = fullEval.config.registry;
              fullCaps = fullEval.config.capabilities.monitoring;
              fman = fullEval.config.manifests;
            in
              # All 3 charts in registry
              assert freg ? coredns;
              assert freg ? valkey;
              assert freg ? cert-manager;
              # Capability targets exist for all monitored services
              assert fullCaps ? coredns;
              assert fullCaps ? valkey;
              assert fullCaps ? cert-manager;
              assert fullCaps ? cert-manager-webhook;
              # HPA resources created for both coredns and valkey
              assert fman ? "coredns-hpa";
              assert fman ? "valkey-hpa";
              # PodDisruptionBudget for both coredns and valkey
              assert fman ? "coredns-poddisruptionbudget";
              assert fman ? "valkey-pdb";
              # ServiceAccount created (coredns has it enabled)
              assert fman ? "coredns-serviceaccount";
              # All charts produce ServiceMonitors via implementation module
              assert fman ? "monitoring-coredns-servicemonitor";
              assert fman ? "monitoring-valkey-servicemonitor";
              assert fman ? "monitoring-cert-manager-servicemonitor";
              pkgs.runCommand "check-cluster-full" {} ''
                echo "Full cluster composition: all assertions passed."
                touch $out
              '';

            # --- Composition test: minimal cluster ---
            # Single chart, all defaults — validates nothing extra is produced.
            cluster-minimal = let
              mman = minimalEval.config.manifests;
              manifestNames = lib.attrNames mman;
            in
              # Only coredns resources should exist
              assert lib.all (n: lib.hasPrefix "coredns" n) manifestNames;
              # No ServiceAccount (create = false by default)
              assert !(mman ? "coredns-serviceaccount");
              # No HPA, PodDisruptionBudget, ServiceMonitor
              assert !(mman ? "coredns-hpa");
              assert !(mman ? "coredns-pdb");
              assert !(lib.any (n: lib.hasInfix "servicemonitor" n) manifestNames);
              # No monitoring capabilities (prometheus.monitor.enabled = false by default)
              assert minimalEval.config.capabilities.monitoring == {};
              pkgs.runCommand "check-cluster-minimal" {} ''
                echo "Minimal cluster: all negative assertions passed."
                touch $out
              '';

            # --- Cross-resource validation ---
            # Pure eval-time checks over raw manifest attrsets. Validates
            # referential integrity: SA refs, roleRefs, ConfigMap volumes,
            # Service selectors, HPA targets, duplicate IDs, managed-by labels.
            validate-cluster-example =
              assert validateManifestSet "cluster-example" manifests;
              pkgs.runCommand "validate-cluster-example" {} ''
                echo "Cross-resource validation passed for cluster-example."
                touch $out
              '';

            validate-cluster-full =
              assert validateManifestSet "cluster-full" fullEval.config.manifests;
              pkgs.runCommand "validate-cluster-full" {} ''
                echo "Cross-resource validation passed for cluster-full."
                touch $out
              '';

            validate-cluster-minimal =
              assert validateManifestSet "cluster-minimal" minimalEval.config.manifests;
              pkgs.runCommand "validate-cluster-minimal" {} ''
                echo "Cross-resource validation passed for cluster-minimal."
                touch $out
              '';
          };
        };
    };
}
