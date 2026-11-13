# Kix documentation site: Astro Starlight, built as a Nix derivation.
#
# Build:  nix build ./docs#site        (as the latest release, at /docs)
#         nix build ./docs#site-main   (as main, at /docs/main)
# Dev:    nix run  ./docs#dev
#
# This is a true sibling subflake; the top-level kixpkgs flake does NOT
# depend on it.
#
# Requires `nix-command` and `flakes` to be enabled in the host's Nix
# config (standard on nix-darwin / NixOS / most setups). `pipe-operators`
# is requested via `nixConfig` below; accept the prompt or set
# `accept-flake-config = true` in your nix.conf.

{
  description = "Kix documentation site (Astro Starlight)";

  nixConfig = {
    extra-experimental-features = [ "pipe-operators" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # kixpkgs keeps its own nixpkgs. The `kix` package carries a runtime
    # built from it, and kix refuses a runtime whose programs differ from the
    # versions compiled into it (cli/kix-core/runtime/programs.json).
    kixpkgs.url = "path:..";
    # Fetched via the GitHub fetcher. Both kixpkgs (above) and
    # kix-examples are currently private; any consumer must supply
    # `access-tokens = github.com=…` to Nix. See the project README
    # for setup.
    kix-examples.url = "github:kix-run/kix-examples";
    # kix-examples declares its own `kix` input, and this flake uses only its
    # source tree (snippet regions, and the workspace the captures runner
    # rewrites to a store path). Following ours keeps that second copy out
    # of the lock. It is not just waste: when the lock resolves it to a
    # `git+https://` ref, fetching it needs git credentials rather than the
    # `access-tokens` the `github:` fetcher uses, which no CI runner has.
    kix-examples.inputs.kix.follows = "kixpkgs";
  };

  outputs =
    {
      nixpkgs,
      kixpkgs,
      kix-examples,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      # The Kix version the docs describe: the workspace version of the
      # revision they are built from.
      kixVersion = (builtins.fromTOML (builtins.readFile ../cli/Cargo.toml)).workspace.package.version;
    in
    {
      packages = forAllSystems (pkgs: rec {
        # Snippet extraction: read named `# region:NAME` blocks out of
        # source `.nix` files and emit Markdown files with fenced code
        # blocks. Consumed by `site` below (copied into the Starlight
        # content tree under an underscore prefix so Starlight treats
        # the directory as non-routable).
        snippets =
          let
            snippetLib = import ./nix/snippets.nix {
              inherit pkgs;
              lib = pkgs.lib;
            };
            exampleSnippets = snippetLib.mkSnippetsFromTree {
              root = "${kix-examples}";
              sourceUrlBase = "https://github.com/kix-run/kix-examples/blob/${kix-examples.rev or "main"}";
            };
            repositorySnippets = snippetLib.mkSnippetsFromTree {
              root = "${kixpkgs}";
              sourceUrlBase = "https://github.com/kix-run/kix/blob/${kixpkgs.rev or "main"}";
            };
          in
          # Auto-discovery: every `.nix` file under kix-examples or kixpkgs
          # with at least one `# region:NAME` marker is picked up
          # automatically. To add a snippet, add the marker. No registration
          # step.
          #
          # `sourceUrlBase` powers the "View source" link in the
          # `<Snippet>` component. kix-examples links are pinned to the commit
          # currently locked in `flake.lock`. The local kixpkgs path input has
          # no revision, so its links use main.
          pkgs.runCommand "kix-doc-snippets-combined" { } ''
            mkdir -p $out
            cp -r ${exampleSnippets}/. $out/
            chmod -R u+w $out
            cp -r ${repositorySnippets}/. $out/
            chmod -R u+w $out
            ${pkgs.jq}/bin/jq -s \
              '{ sources: (.[0].sources + .[1].sources) }' \
              ${exampleSnippets}/manifest.json \
              ${repositorySnippets}/manifest.json \
              > $out/manifest.json
          '';

        # Auto-generated per-package option reference (Markdown), produced
        # via `nixosOptionsDoc` against each package's `options` attrset.
        # Three packages for now; future passes will scale to all 61.
        reference =
          let
            ref = import ./nix/reference.nix {
              inherit pkgs;
              inherit (pkgs) lib;
            };
          in
          ref.mkAllReferences {
            packages = [
              {
                path = ../kix/packages/stable/echo-server;
                name = "echo-server";
              }
              {
                path = ../kix/packages/experimental/cert-manager;
                name = "cert-manager";
              }
              {
                path = ../kix/packages/experimental/cilium;
                name = "cilium";
              }
            ];
          };

        # The docs as one Kix version's build. CI builds them once per
        # version, each at its own git revision, and serves each under its
        # own path (.github/workflows/pages.yml):
        #
        # - `site`: the latest release, at /docs.
        # - `site-main`: the main branch, at /docs/main.
        # - `site-archived`: an older minor release, at
        #   /docs/v<major>.<minor>.
        #
        # src/lib/docs-version.ts reads the channel and version, and
        # astro.config.mjs reads the base path.
        site = pkgs.buildNpmPackage {
          pname = "kix-docs";
          version = kixVersion;

          env = {
            KIX_DOCS_CHANNEL = "release";
            KIX_DOCS_BASE = "/docs";
            KIX_DOCS_VERSION = kixVersion;
          };

          src = ./.;

          # To regenerate after dep changes: set to lib.fakeHash, rebuild,
          # paste the "got: sha256-…" hash from the error.
          npmDepsHash = "sha256-Dyp2eMT8QVHnb2asLVq9sJgH9xSdu7dGNjHnFmg4HYQ=";

          # Astro/Starlight have no install scripts we care about; keep
          # the build hermetic.
          npmFlags = [ "--ignore-scripts" ];

          # Drop generated content into the source tree before `npm run build`:
          # - Snippets land under `src/snippets/` (OUTSIDE the Starlight
          #   content collection so they're not parsed as MDX). Pages
          #   reach them with Vite `?raw` imports.
          # - Per-package reference Markdown lands under
          #   `src/content/docs/reference/package-catalog/`, overwriting
          #   any placeholder pages Phase 2A wrote for these names.
          #   Generated content wins.
          # `--no-preserve=mode` + chmod so the copies are writable:
          # files from the Nix store arrive read-only.
          #
          # Captures sidecars (src/command-output/) are NOT copied here:
          # both offline and live captures are committed to git, with
          # CI running `regen-captures-offline -- --check` to gate
          # stale sidecars. Live captures are regenerated by
          # `nix run ./docs#regen-captures -- --apply` against a kind
          # cluster; offline captures by `regen-captures-offline`.
          preBuild = ''
            npm run check:how-to-coverage
            mkdir -p src/snippets
            cp -r --no-preserve=mode ${snippets}/. src/snippets/
            chmod -R u+w src/snippets
            mkdir -p src/content/docs/reference/package-catalog
            cp -r --no-preserve=mode ${reference}/. src/content/docs/reference/package-catalog/
            chmod -R u+w src/content/docs/reference/package-catalog
            npm run check:local-imports
            KIX_REPO_ROOT=${kixpkgs} npm run check:doc-refs
          '';

          # `npm run build` writes the static site to ./dist.
          installPhase = ''
            runHook preInstall
            mkdir -p $out
            cp -r dist/* $out/
            runHook postInstall
          '';

          meta = {
            description = "Kix documentation site (Astro Starlight)";
            platforms = pkgs.lib.platforms.unix;
          };
        };

        site-main = site.overrideAttrs (old: {
          env = old.env // {
            KIX_DOCS_CHANNEL = "main";
            KIX_DOCS_BASE = "/docs/main";
          };
        });
        site-archived = site.overrideAttrs (old: {
          env = old.env // {
            KIX_DOCS_CHANNEL = "archived";
            KIX_DOCS_BASE = "/docs/v${pkgs.lib.versions.majorMinor kixVersion}";
          };
        });

        default = site;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nodejs_22
            pkgs.prefetch-npm-deps
          ];
        };
      });

      # `nix run ./docs#dev`: one-shot dev workflow:
      #   1. Build the snippets + reference Nix derivations.
      #   2. Sync their outputs into the writable source tree.
      #   3. `npm install` if node_modules is missing.
      #   4. Start the Astro dev server with HMR.
      #
      # Run from the kixpkgs repo root. The script expects cwd to contain
      # the `docs/` directory.
      apps = forAllSystems (pkgs: {
        # Live driver for the captures pipeline. Spins up a dedicated kind
        # cluster, runs every manifest group's live steps against it
        # (sharing the cluster across groups so deploys accumulate), and
        # diffs the captured sidecars against the checked-in tree before
        # optionally writing them. See `nix/captures.nix` for the
        # manifest and `nix/captures-live.nix` for the trust boundary
        # and flag plumbing.
        #
        # Run: `nix run ./docs#regen-captures` (or `-- --apply` / `--check`).
        regen-captures =
          (import ./nix/captures-live.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            kix = kixpkgs.packages.${pkgs.system}.kix;
            kixExamples = kix-examples;
            kixpkgsSrc = kixpkgs;
          }).app;

        # Offline captures regen. Same shape as regen-captures, but
        # without a kind cluster: invokes `kix` against the workspace
        # directly. See `nix/captures-offline.nix` for the trust
        # boundary and `nix/captures.nix` for the manifest.
        regen-captures-offline =
          (import ./nix/captures-offline.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            kix = kixpkgs.packages.${pkgs.system}.kix;
            kixExamples = kix-examples;
            kixpkgsSrc = kixpkgs;
          }).app;

        dev = {
          type = "app";
          program = toString (
            pkgs.writeShellScript "kix-docs-dev" ''
              set -euo pipefail

              if [ ! -f docs/package.json ]; then
                echo "error: run \`nix run ./docs#dev\` from the kixpkgs repo root" >&2
                echo "       (cwd must contain a docs/ directory)" >&2
                exit 1
              fi

              export PATH=${
                pkgs.lib.makeBinPath [
                  pkgs.nodejs_22
                  pkgs.nix
                  pkgs.coreutils
                ]
              }:$PATH

              echo "→ building snippets pipeline"
              snip=$(nix build ./docs#snippets --no-link --print-out-paths)

              echo "→ building reference pipeline"
              ref=$(nix build ./docs#reference --no-link --print-out-paths)

              # Captures sidecars live in git (docs/src/command-output/);
              # to refresh them run \`nix run ./docs#regen-captures-offline\`
              # (offline) or \`nix run ./docs#regen-captures\` (live).
              echo "→ syncing generated content into docs/src"
              mkdir -p docs/src/snippets docs/src/content/docs/reference/package-catalog
              cp -r --no-preserve=mode "$snip"/. docs/src/snippets/
              cp -r --no-preserve=mode "$ref"/. docs/src/content/docs/reference/package-catalog/
              chmod -R u+w docs/src/snippets docs/src/content/docs/reference/package-catalog

              cd docs

              npm run check:local-imports
              npm run check:doc-refs

              if [ ! -d node_modules ]; then
                echo "→ installing npm dependencies (first run)"
                npm install
              fi

              echo "→ starting Astro dev server"
              exec npm run dev
            ''
          );
        };
      });
    };
}
