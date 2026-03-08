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
# Only mkManifest serializes to a Nix store derivation.
#
# Each module writes its resources to config.manifests.<name>, where each
# entry is one resource (not one-per-module). This makes verification and
# inspection straightforward — each JSON file is one Kubernetes resource.
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
          # in config.manifests. This is what verify-parity.sh compares against.
          mkManifests =
            evaluation:
            pkgs.runCommand "k8s-manifests" { } ''
              mkdir -p $out
              ${lib.concatStringsSep "\n" (
                lib.mapAttrsToList (
                  name: path: "cp ${path} $out/${name}.json"
                ) evaluation.config.manifests
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
              ${drv}/*.json
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
            nativeBuildInputs = [ pkgs.jq pkgs.diffutils ];
          } ''
            fail=0
            # Check each built manifest matches its golden file
            for f in ${drv}/*.json; do
              base=$(basename "$f")
              golden="${./tests}/${name}/golden/$base"
              if [ ! -f "$golden" ]; then
                echo "FAIL: $base is new (no golden file)"
                fail=1
                continue
              fi
              jq -S '.' "$f" > /tmp/actual.json
              if ! diff -u "$golden" /tmp/actual.json; then
                echo "FAIL: $base differs from golden"
                fail=1
              fi
            done
            # Check for removed resources (golden file with no matching output)
            for f in ${./tests}/${name}/golden/*.json; do
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
            mon = exampleEval.config.monitoring;
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

              # Monitoring: cross-cutting module created ServiceMonitors,
              # per-chart ones were suppressed.
              assertMonitoring =
                assert mon.targets.valkey.serviceName == "valkey-metrics";
                assert mon.targets.valkey.portName == "http-metrics";
                assert manifests ? "monitoring-valkey-servicemonitor";
                assert !(manifests ? "valkey-servicemonitor");
                assert mon.targets.coredns.serviceName == "coredns-metrics";
                assert mon.targets.coredns.portName == "metrics";
                assert manifests ? "monitoring-coredns-servicemonitor";
                assert !(manifests ? "coredns-servicemonitor");
                # Metrics Service should still exist (ServiceMonitor targets it)
                assert manifests ? "coredns-service-metrics";
                # cert-manager monitoring targets
                assert mon.targets.cert-manager.serviceName == "cert-manager";
                assert mon.targets.cert-manager-webhook.serviceName == "cert-manager-webhook";
                assert mon.targets.cert-manager-cainjector.serviceName == "cert-manager-cainjector";
                assert manifests ? "monitoring-cert-manager-servicemonitor";
                assert manifests ? "monitoring-cert-manager-webhook-servicemonitor";
                assert manifests ? "monitoring-cert-manager-cainjector-servicemonitor";
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
              echo "Monitoring: valkey target=${mon.targets.valkey.serviceName}:${mon.targets.valkey.portName}"
              echo "Monitoring: cert-manager target=${mon.targets.cert-manager.serviceName}"
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
              fmon = fullEval.config.monitoring;
              fman = fullEval.config.manifests;
            in
              # All 3 charts in registry
              assert freg ? coredns;
              assert freg ? valkey;
              assert freg ? cert-manager;
              # Monitoring targets exist for all monitored services
              assert fmon.targets ? coredns;
              assert fmon.targets ? valkey;
              assert fmon.targets ? cert-manager;
              assert fmon.targets ? cert-manager-webhook;
              # HPA resources created for both coredns and valkey
              assert fman ? "coredns-hpa";
              assert fman ? "valkey-hpa";
              # PDB for both coredns and valkey
              assert fman ? "coredns-poddisruptionbudget";
              assert fman ? "valkey-pdb";
              # ServiceAccount created (coredns has it enabled)
              assert fman ? "coredns-serviceaccount";
              # All charts produce ServiceMonitors via monitoring module
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
              # No HPA, PDB, ServiceMonitor
              assert !(mman ? "coredns-hpa");
              assert !(mman ? "coredns-pdb");
              assert !(lib.any (n: lib.hasInfix "servicemonitor" n) manifestNames);
              # No monitoring targets (prometheus.monitor.enabled = false by default)
              assert minimalEval.config.monitoring.targets == {};
              pkgs.runCommand "check-cluster-minimal" {} ''
                echo "Minimal cluster: all negative assertions passed."
                touch $out
              '';

            # --- Behavioral invariant: all resources have managed-by label ---
            invariant-managed-by = let
              allManifests = exampleEval.config.manifests;
            in pkgs.runCommand "invariant-managed-by" {
              nativeBuildInputs = [ pkgs.jq ];
            } ''
              fail=0
              for f in ${clusterExamplePkg}/*.json; do
                managed=$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // empty' "$f")
                if [ "$managed" != "kix" ]; then
                  echo "FAIL: $(basename "$f") missing app.kubernetes.io/managed-by=kix (got: '$managed')"
                  fail=1
                fi
              done
              [ "$fail" -eq 0 ] || exit 1
              echo "All resources have managed-by=kix label."
              touch $out
            '';
          };
        };
    };
}
