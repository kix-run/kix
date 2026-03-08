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

          # --- Package derivations ---
          # Defined here so both `packages` and `checks` can reference them.

          # Per-chart parity test fixtures
          corednsPkg = mkChartManifests ./pkgs/coredns {
            services.coredns.enable = true;
          };

          valkeyPkg = mkChartManifests ./pkgs/valkey {
            services.valkey.enable = true;
          };

          valkeySentinelPkg = mkChartManifests ./pkgs/valkey {
            services.valkey = {
              enable = true;
              sentinel.enabled = true;
            };
          };

          valkeyFullPkg = mkChartManifests ./pkgs/valkey {
            services.valkey = {
              enable = true;
              sentinel.enabled = true;
              metrics.enabled = true;
              metrics.serviceMonitor.enabled = true;
              networkPolicy.enabled = true;
              pdb.enabled = true;
            };
          };

          # Multi-chart cluster evaluation
          exampleEval = mkCluster {
            chartModules = [
              ./pkgs/coredns
              ./pkgs/valkey
            ];
            config = import ./clusters/example.nix;
          };

          clusterExamplePkg = mkManifests exampleEval;

        in
        {
          legacyPackages = {
            inherit mkCluster mkManifests mkChartManifests kixlib;
          };

          # Per-chart build targets for parity testing, plus cluster definitions.
          # `nix build .#<name>` builds any of these.
          packages = {
            coredns = corednsPkg;
            valkey = valkeyPkg;
            valkey-sentinel = valkeySentinelPkg;
            valkey-full = valkeyFullPkg;
            cluster-example = clusterExamplePkg;
          };

          checks = let
            reg = exampleEval.config.registry;
            mon = exampleEval.config.monitoring;
            manifests = exampleEval.config.manifests;

            # Helper: validate a manifest directory against K8s API schemas.
            # Skips CRDs (ServiceMonitor) since kubeconform doesn't have
            # Prometheus Operator schemas built-in.
            schemaCheck = name: drv: pkgs.runCommand "schema-${name}" {
              nativeBuildInputs = [ pkgs.kubeconform ];
            } ''
              echo "Validating ${name}..."
              kubeconform -strict -summary -skip ServiceMonitor ${drv}/*.json
              touch $out
            '';
          in {
            # --- Structural checks for multi-chart composition ---
            # Eval-time assertions validate that intent merging works across
            # charts. If any assertion fails, Nix aborts before the runCommand
            # executes, with a clear error message.
            cluster-example = let
              # Registry: both charts populated with non-empty hosts
              assertRegistry =
                assert reg.coredns.endpoints.dns-udp.host != "";
                assert reg.coredns.endpoints.dns-tcp.host != "";
                assert reg.coredns.endpoints.dns-udp.port == 53;
                assert reg.valkey.endpoints.primary.host != "";
                assert reg.valkey.endpoints.primary.port == 6379;
                assert reg.valkey.endpoints.sentinel.host != "";
                assert reg.valkey.endpoints.sentinel.port == 26379;
                assert reg.valkey.endpoints.metrics.host != "";
                assert reg.valkey.endpoints.metrics.port == 9121;
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

              # Monitoring: cross-cutting module created the ServiceMonitor,
              # per-chart one was suppressed.
              assertMonitoring =
                assert mon.targets.valkey.serviceName == "valkey-metrics";
                assert mon.targets.valkey.portName == "http-metrics";
                assert manifests ? "monitoring-valkey-servicemonitor";
                assert !(manifests ? "valkey-servicemonitor");
                true;

            in assert assertRegistry; assert assertOwnership; assert assertMonitoring;
            pkgs.runCommand "check-cluster-example" {} ''
              echo "Registry: coredns dns-udp=${reg.coredns.endpoints.dns-udp.host}:${toString reg.coredns.endpoints.dns-udp.port}"
              echo "Registry: valkey primary=${reg.valkey.endpoints.primary.host}:${toString reg.valkey.endpoints.primary.port}"
              echo "Registry: valkey sentinel=${reg.valkey.endpoints.sentinel.host}:${toString reg.valkey.endpoints.sentinel.port}"
              echo "Registry: valkey metrics=${reg.valkey.endpoints.metrics.host}:${toString reg.valkey.endpoints.metrics.port}"
              echo "Monitoring: valkey target=${mon.targets.valkey.serviceName}:${mon.targets.valkey.portName}"
              echo "All structural assertions passed."
              touch $out
            '';

            # --- Schema validation ---
            # Validates manifests against K8s API schemas using kubeconform.
            # Catches invalid apiVersions, missing required fields, wrong types.
            schema-cluster-example = schemaCheck "cluster-example" clusterExamplePkg;
            schema-coredns = schemaCheck "coredns" corednsPkg;
            schema-valkey = schemaCheck "valkey" valkeyPkg;
            schema-valkey-sentinel = schemaCheck "valkey-sentinel" valkeySentinelPkg;
            schema-valkey-full = schemaCheck "valkey-full" valkeyFullPkg;
          };
        };
    };
}
