# The Kix repository flake: the Kix CLI, its runtime, the library checks,
# and every cluster under clusters/.
#
# The smoke test is homelab-kind:
#   nix run .#kix -- check homelab-kind

{
  description = "Kix, the Kubernetes compiler: its CLI, library, packages, and clusters";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    # The Nix release the Kix runtime ships (cli/runtime/runtime.nix). It
    # keeps its own nixpkgs, whose builds of it Hydra caches, including the
    # static Linux build.
    nix-runtime.url = "github:NixOS/nix/2.35.4";
  };

  outputs =
    inputs:
    let
      mkFlake = import ./kix/lib/mkFlake.nix;
      lib = inputs.nixpkgs.lib;

      clusterOutputs = mkFlake {
        inherit inputs;
        # A finding from an error-severity scorecard rule fails the build in
        # this repository. Every cluster otherwise runs the shipped default
        # rule set.
        clusterModules = [ { scorecard.maxSeverity = "error"; } ];

        # Every cluster the repository builds, keyed by the name commands
        # take: `kix build <key>`, `kix check <key>`, `kix deploy <key>`.
        # The key is also the cluster's name unless the definition passes
        # `name` to `buildCluster`. clusters/README.md says what each group
        # is for.
        clusters = {
          # Examples: start with example-hello.
          example-hello = ./clusters/example-hello.nix;
          example = ./clusters/example.nix;
          example-import = ./clusters/example-import.nix;
          example-multi-env-dev = ./clusters/example-multi-env/dev.nix;
          example-multi-env-prod = ./clusters/example-multi-env/prod.nix;

          # The smoke test: the full homelab service set on kind, and the same
          # cluster moved to Gateway API for scripts/kix-rollback-check.sh.
          homelab-kind = ./clusters/homelab/cluster-kind.nix;
          homelab-kind-gateway-migrate = ./clusters/homelab/cluster-kind-gateway-migrate.nix;

          # Library features: dependency resolution, composition, pins, bundles.
          minimal = ./clusters/test-minimal.nix;
          full = ./clusters/test-full.nix;
          helm = ./clusters/test-helm.nix;
          auto = ./clusters/test-auto.nix;
          auto2 = ./clusters/test-auto2.nix;
          fragments = ./clusters/test-fragments.nix;
          multi-env = ./clusters/test-multi-env.nix;
          pins = ./clusters/test-pins.nix;
          secrets = ./clusters/test-secrets.nix;
          bundle-alias = ./clusters/test-bundle-alias.nix;
          consumers-platform = ./clusters/test-consumers/platform.nix;
          consumers-acme = ./clusters/test-consumers/acme.nix;
          doc-how-tos = ./clusters/test-doc-how-tos.nix;
          spread = ./clusters/test-spread.nix;
          rke2-cilium = ./clusters/test-rke2-cilium.nix;

          # The CLI's kind integration tests deploy kind, then kind-v2 or kind-port
          # over it. All three share the cluster name "kind".
          kind = ./clusters/test-kind.nix;
          kind-v2 = ./clusters/test-kind-v2.nix;
          kind-port = ./clusters/test-kind-port.nix;
          kind-probe = ./clusters/test-kind-probe.nix;

          # Swap fixtures: two builds of one cluster that move a consumer from one
          # provider package to another. Each pair shares a cluster name.
          clickhouse-swap-bare = ./clusters/test-clickhouse-swap/bare.nix;
          clickhouse-swap-replicated = ./clusters/test-clickhouse-swap/replicated.nix;
          postgres-swap-stackgres = ./clusters/test-postgres-swap/stackgres.nix;
          postgres-swap-cnpg = ./clusters/test-postgres-swap/cnpg.nix;
          gateway-swap-envoy = ./clusters/test-gateway-swap/envoy.nix;
          gateway-swap-traefik = ./clusters/test-gateway-swap/traefik.nix;

          # One package, or a small group, each on kind unless its file says
          # otherwise.
          immich = ./clusters/test-immich.nix;
          n8n = ./clusters/test-n8n.nix;
          clickhouse = ./clusters/test-clickhouse.nix;
          clickhouse-operator = ./clusters/test-clickhouse-operator.nix;
          cnpg = ./clusters/test-cnpg.nix;
          rabbitmq = ./clusters/test-rabbitmq.nix;
          harbor = ./clusters/test-harbor.nix;
          operators = ./clusters/test-operators.nix;
          sealed-jobs = ./clusters/test-sealed-jobs.nix;
          ingress-netpol = ./clusters/test-ingress-netpol.nix;
          external-dns = ./clusters/test-external-dns.nix;
          external-dns-tryout = ./clusters/test-external-dns-tryout.nix;
          external-secrets = ./clusters/test-external-secrets.nix;
          openbao = ./clusters/test-openbao.nix;
          velero = ./clusters/test-velero.nix;
          reloader = ./clusters/test-reloader/kind.nix;
          tailscale = ./clusters/test-tailscale/cluster.nix;
          mayastor = ./clusters/test-mayastor.nix;
          virtualization = ./clusters/test-virtualization.nix;
          metabase = ./clusters/test-metabase.nix;
          plausible = ./clusters/test-plausible.nix;
          plausible-replicated = ./clusters/test-plausible-replicated.nix;
          metrics-server = ./clusters/test-metrics-server.nix;
          spegel = ./clusters/test-spegel.nix;
          volsync = ./clusters/test-volsync.nix;
          keycloak = ./clusters/test-keycloak.nix;
          keycloak-oidc = ./clusters/test-keycloak-oidc.nix;
          otel-collector = ./clusters/test-otel-collector.nix;
          falco = ./clusters/test-falco.nix;
          traefik = ./clusters/test-traefik.nix;
          envoy-gateway = ./clusters/test-envoy-gateway.nix;
          tempo = ./clusters/test-tempo.nix;
          tempo-generator = ./clusters/test-tempo-generator.nix;
          monitoring-native = ./clusters/test-monitoring-native.nix;
          monitoring-loki = ./clusters/test-monitoring-loki.nix;
          monitoring-netpol = ./clusters/test-monitoring-netpol.nix;
          victoria-metrics = ./clusters/test-victoria-metrics.nix;
          victoria-metrics-crd-ref = ./clusters/test-victoria-metrics-crd-ref.nix;
        };

        # region:pinFile
        # A cluster function that takes a `pins` argument gets this file
        # already loaded, so no cluster definition names the path.
        pins = ./clusters/pins.json;
        # endregion:pinFile
      };

      # Kix CLI package (built with crane)
      mkKixPackage = (import ./cli/flake-integration.nix).mkKixPackage;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      cliPackages = lib.genAttrs systems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          hasRuntime = builtins.elem system runtimeSystems;
          runtime = import ./cli/runtime/in-store.nix {
            inherit pkgs;
            nixRelease = inputs.nix-runtime;
          };
        in
        {
          # Kix with its runtime in libexec/kix, where it looks first.
          kix = mkKixPackage {
            inherit pkgs;
            lib = pkgs.lib;
            crane = inputs.crane;
            runtime = if hasRuntime then runtime else null;
          };
        }
        // lib.optionalAttrs hasRuntime {
          # The programs a Kix release ships beside the binary
          # (cli/runtime/default.nix).
          kix-runtime-spec = import ./cli/runtime {
            inherit pkgs;
            nixRelease = inputs.nix-runtime;
          };
          # The same programs, run from /nix/store.
          kix-runtime = runtime;
        }
      );
      runtimeSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Run the kix/lib evaluation test matrix (kix/lib/tests) as a flake check
      # so `nix flake check` covers it. Forcing `ok` evaluates every case; a
      # failure throws with the failing names.
      libTests = lib.genAttrs systems (system: {
        kix-lib-tests =
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
            result = (import ./kix/lib/tests { inherit lib; }).result;
          in
          assert result.ok;
          pkgs.runCommand "kix-lib-tests" { } ''
            echo "${toString (builtins.length result.passed)} kix/lib tests passed."
            touch $out
          '';
      });
      # Evaluate every directory under kix/packages/stable/ in a synthetic cluster of
      # its own (kix/package-eval.nix), once at availability "none" and once at
      # "zone", so a package that no cluster names still runs through the
      # validators and the scorecard.
      packageEval = lib.genAttrs systems (system: {
        every-package-evaluates =
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
            result = import ./kix/package-eval.nix {
              inherit lib;
              kix = import ./kix/lib { inherit pkgs lib; };
            };
          in
          pkgs.runCommand "every-package-evaluates" { } ''
            echo "${
              toString (builtins.length result.names / builtins.length result.levels)
            } kix packages evaluated at availability ${lib.concatStringsSep " and " result.levels}."
            echo "Skipped: ${
              if result.skip == { } then "none" else lib.concatStringsSep ", " (builtins.attrNames result.skip)
            }"
            echo "Known failures: ${
              lib.concatStringsSep ", " (
                lib.mapAttrsToList (
                  name: failures: "${name} (${lib.concatMapStringsSep ", " (f: f.rule) failures})"
                ) result.knownFailures
              )
            }"
            touch $out
          '';
      });

      # Provide a shell that can build and test the CLI.
      #
      # The crane package (`packages.kix`) sets `doCheck = false` because
      # the integration tests need a writable Nix store for the eval cache
      # and the build sandbox has none. `nix flake check` cannot run them,
      # so CI runs them from this shell without requiring devenv.
      devShells = lib.genAttrs systems (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.rustc
              pkgs.clippy
              pkgs.rustfmt
              pkgs.lefthook
              pkgs.pkg-config
              pkgs.openssl
            ]
            ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.dbus ];

            # Kix runs its programs only from a Kix runtime, never from PATH.
            # This one ships the programs a release ships, so `cargo test`
            # and a `kix` built with cargo run the versions the library
            # names.
            KIX_RUNTIME_DIR = cliPackages.${system}.kix-runtime or "";

            # Keyed on the checkout path and kept OUT of the checkout, for
            # the reason devenv.nix spells out at length: a `path:` flakeref
            # copies a directory into the store with no filtering at all, so
            # an in-tree target dir is copied verbatim on every change. Same
            # scheme as devenv's, so the two share a directory rather than
            # building two cold copies of the same tree.
            shellHook = ''
              export CARGO_TARGET_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/kix-cargo-target/$(basename "$PWD")-$(printf %s "$PWD" | sha256sum | cut -c1-12)"
              mkdir -p "$CARGO_TARGET_DIR"

              # The git hooks name lefthook by store path, which a
              # `nix store gc` can remove. Reinstalling points them at this
              # shell's lefthook.
              lefthook install >/dev/null 2>&1 || echo "lefthook install failed; git hooks may be stale" >&2
            '';
          };
        }
      );

      # Build one consumer once on the bare `clickhouse` package and once on
      # `clickhouse-cluster`. Everything rendered into the consumer's
      # namespace, plus the facade's bootstrap Job next to the server, must
      # match except for the ClickHouse hostname. The contract itself is
      # defined and checked at evaluation time in
      # kix/contracts/experimental/clickhouse.nix; this is the rendering regression
      # test. Kix's own dependency bookkeeping is stripped first because it
      # records upstream hashes that legitimately differ between providers.
      clickhouseSwap = lib.genAttrs systems (system: {
        clickhouse-swap =
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
            built = name: clusterOutputs.packages.${system}."cluster-clickhouse-swap-${name}";
          in
          pkgs.runCommand "clickhouse-swap" { } ''
            normalise() {
              mkdir -p "$2"
              for f in "$1"/app/*.yaml "$1"/db/*bootstrap*.yaml; do
                sed -E \
                  -e 's/(clickhouse-)?ch\.db\.svc\.cluster\.local/CLICKHOUSE_HOST/g' \
                  -e '/kix\.run\/(depends-on|identity-hash|closure-hash)/d' \
                  "$f" > "$2/$(basename "$f")"
              done
            }
            normalise ${built "bare"} bare
            normalise ${built "replicated"} replicated
            if ! diff -ru bare replicated; then
              echo "the consumer's manifests changed with the clickhouse implementation" >&2
              exit 1
            fi
            grep -rq CLICKHOUSE_HOST bare || { echo "no ClickHouse address reached the consumer" >&2; exit 1; }
            echo "$(ls bare | wc -l) consumer manifests identical across both implementations"
            touch $out
          '';
      });

      # Build one Metabase instance once on stackgres-database and once on
      # cnpg-database (clusters/test-postgres-swap). Metabase's manifests and
      # the facade's credentials Secret in the consumer's namespace must match
      # except for the PostgreSQL hostname. Stripped before comparison: Kix's
      # dependency bookkeeping (which names the upstream provider), the
      # `checksum/database` annotation (the identity hash of the credentials
      # Secret containing the hostname), and the facade's package-name label.
      postgresSwap = lib.genAttrs systems (system: {
        postgres-swap =
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
            built = name: clusterOutputs.packages.${system}."cluster-postgres-swap-${name}";
          in
          pkgs.runCommand "postgres-swap" { } ''
            # $3 is the provider's own host, so a wrong host from either
            # provider (CloudNativePG serves no Service named pg) differs.
            normalise() {
              mkdir -p "$2"
              for f in "$1"/app/metabase-*.yaml; do
                case "$(basename "$f")" in
                  metabase-db-packageinstance.yaml) continue ;;
                esac
                sed -E \
                  -e "s/$3/POSTGRES_HOST/g" \
                  -e '/kix\.run\/(depends-on|identity-hash|closure-hash)/d' \
                  -e 's/(checksum\/database:).*/\1 CREDENTIALS_HASH/' \
                  -e 's/(app\.kubernetes\.io\/name:) (stackgres|cnpg)-database/\1 DATABASE_PACKAGE/' \
                  "$f" > "$2/$(basename "$f")"
              done
            }
            normalise ${built "stackgres"} stackgres 'pg\.db\.svc\.cluster\.local'
            normalise ${built "cnpg"} cnpg 'pg-rw\.db\.svc\.cluster\.local'
            if ! diff -ru stackgres cnpg; then
              echo "the consumer's manifests changed with the PostgreSQL provider" >&2
              exit 1
            fi
            grep -rq POSTGRES_HOST stackgres || { echo "no PostgreSQL address reached the consumer" >&2; exit 1; }
            echo "$(ls stackgres | wc -l) consumer manifests identical across both providers"
            touch $out
          '';
      });

      # Build one File Browser instance once behind envoy-gateway and once
      # behind traefik (clusters/test-gateway-swap). Its manifests must match
      # except for the HTTPRoute's parentRef, which names each implementation's
      # Gateway (envoy-system/envoy, traefik-system/traefik), and Kix's
      # dependency bookkeeping. Network policy is off in both builds because
      # the rule that admits each implementation's proxies to the backend
      # names that implementation's pod labels.
      gatewaySwap = lib.genAttrs systems (system: {
        gateway-swap =
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
            built = name: clusterOutputs.packages.${system}."cluster-gateway-swap-${name}";
          in
          pkgs.runCommand "gateway-swap" { } ''
            # $3 and $4 are the Gateway's name and namespace in the parentRef.
            normalise() {
              mkdir -p "$2"
              for f in "$1"/files/*.yaml; do
                sed -E \
                  -e "/parentRefs:/,/namespace:/{s/name: $3\$/name: GATEWAY_NAME/;s/namespace: $4\$/namespace: GATEWAY_NAMESPACE/}" \
                  -e '/kix\.run\/(depends-on|identity-hash|closure-hash)/d' \
                  "$f" > "$2/$(basename "$f")"
              done
            }
            normalise ${built "envoy"} envoy envoy envoy-system
            normalise ${built "traefik"} traefik traefik traefik-system
            if ! diff -ru envoy traefik; then
              echo "the consumer's manifests changed with the gateway implementation" >&2
              exit 1
            fi
            grep -rq GATEWAY_NAMESPACE envoy || { echo "no parentRef reached the consumer" >&2; exit 1; }
            echo "$(ls envoy | wc -l) consumer manifests identical across both implementations"
            touch $out
          '';
      });
    in
    clusterOutputs
    // {
      inherit devShells;

      # Merge the Kix CLI into per-system packages alongside cluster outputs.
      packages = lib.mapAttrs (
        system: clusterPkgs: clusterPkgs // (cliPackages.${system} or { })
      ) clusterOutputs.packages;

      checks = lib.mapAttrs (
        system: clusterChecks:
        clusterChecks
        // (libTests.${system} or { })
        // (clickhouseSwap.${system} or { })
        // (postgresSwap.${system} or { })
        // (gatewaySwap.${system} or { })
        // (packageEval.${system} or { })
      ) clusterOutputs.checks;

      # Preserve the forPkgs API for external consumers. It supports only the
      # default kix builder, because it does not read kix.toml or publish the
      # outputs the kix program reads. A project that wires its own flake
      # outputs should merge mkFlake's outputs instead, and take the library
      # from `legacyPackages.<system>.kixLib`.
      #
      # `self` is the consumer's flake. Without it, Kix cannot tell a pin
      # file in that flake from one in another input, so image sources name
      # no pin file and Kix Enterprise opens no update pull requests.
      lib.forPkgs =
        {
          pkgs,
          lib,
          self ? null,
        }:
        let
          kix = import ./kix/lib { inherit pkgs lib self; };
          packages = import ./kix/packages { inherit lib; };
        in
        {
          inherit kix packages;
          inherit (kix) mkManifests;
        };

      # Wrap cluster definitions into a complete per-system flake output for
      # external consumers:
      #
      #   outputs = inputs: inputs.kix.lib.mkFlake {
      #     inherit inputs;
      #     clusters.my-cluster = ./cluster.nix;
      #   };
      lib.mkFlake = mkFlake;
    };
}
