# Kix documentation site — Astro Starlight, built as a Nix derivation.
#
# Build:  nix build ./docs#site
# Dev:    nix run  ./docs#dev
#
# This is a true sibling subflake — the top-level kixpkgs flake does NOT
# depend on it.
#
# Requires `nix-command` and `flakes` to be enabled in the host's Nix
# config (standard on nix-darwin / NixOS / most setups). `pipe-operators`
# is requested via `nixConfig` below — accept the prompt or set
# `accept-flake-config = true` in your nix.conf.

{
  description = "Kix documentation site (Astro Starlight)";

  nixConfig = {
    extra-experimental-features = [ "pipe-operators" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    kixpkgs = {
      url = "path:..";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Local sibling checkout for dev iteration. CI builds the docs site
    # by checking kix-examples out separately and passing
    # `--override-input kix-examples git+file://$PWD/...` to `nix build`.
    # See `.github/workflows/pages.yml`.
    kix-examples.url = "git+file:///Users/adam/ghq/github.com/adamcharnock/kix-examples";
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
          in
          # Auto-discovery: every `.nix` file under kix-examples
          # with at least one `# region:NAME` marker is picked up
          # automatically. To add a snippet: add the marker. No
          # registration step.
          #
          # `sourceUrlBase` powers the "View source" link in the
          # `<Snippet>` component. Pinned to the kix-examples commit
          # currently locked in `flake.lock`, so links never rot under
          # `main`. Falls back to `main` if the input has no rev (e.g.
          # dirty working tree without a commit).
          snippetLib.mkSnippetsFromTree {
            root = "${kix-examples}";
            sourceUrlBase = "https://github.com/kix-ops/kix-examples/blob/${kix-examples.rev or "main"}";
          };

        # Captured CLI output for docs examples. Only non-live commands belong
        # here: commands must not require a Kubernetes cluster, kubeconfig, or
        # network access beyond what Nix already needs to realise inputs.
        commandOutputs =
          let
            commandOutputLib = import ./nix/command-outputs.nix {
              inherit pkgs;
              inherit (pkgs) lib;
              kix = kixpkgs.packages.${pkgs.system}.kix;
              kixExamples = kix-examples;
            };
          in
          commandOutputLib;

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
                path = ../kix/packages/echo-server;
                name = "echo-server";
              }
              {
                path = ../kix/packages/cert-manager;
                name = "cert-manager";
              }
              {
                path = ../kix/packages/cilium;
                name = "cilium";
              }
            ];
          };

        site = pkgs.buildNpmPackage {
          pname = "kix-docs";
          version = "0.0.0";

          src = ./.;

          # To regenerate after dep changes: set to lib.fakeHash, rebuild,
          # paste the "got: sha256-…" hash from the error.
          npmDepsHash = "sha256-iZc+c56BhmITniDwKxrMW40KKagqHUf+RK/S8saNfMU=";

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
          # `--no-preserve=mode` + chmod so the copies are writable —
          # files from the Nix store arrive read-only.
          preBuild = ''
            mkdir -p src/snippets
            cp -r --no-preserve=mode ${snippets}/. src/snippets/
            chmod -R u+w src/snippets
            mkdir -p src/command-output
            cp -r --no-preserve=mode ${commandOutputs}/. src/command-output/
            chmod -R u+w src/command-output
            mkdir -p src/content/docs/reference/package-catalog
            cp -r --no-preserve=mode ${reference}/. src/content/docs/reference/package-catalog/
            chmod -R u+w src/content/docs/reference/package-catalog
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

      # `nix run ./docs#dev` — one-shot dev workflow:
      #   1. Build the snippets + reference Nix derivations.
      #   2. Sync their outputs into the writable source tree.
      #   3. `npm install` if node_modules is missing.
      #   4. Start the Astro dev server with HMR.
      #
      # Run from the kixpkgs repo root. The script expects cwd to contain
      # the `docs/` directory.
      apps = forAllSystems (pkgs: {
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

              echo "→ building command output pipeline"
              command_outputs=$(nix build ./docs#commandOutputs --no-link --print-out-paths)

              echo "→ building reference pipeline"
              ref=$(nix build ./docs#reference --no-link --print-out-paths)

              echo "→ syncing generated content into docs/src"
              mkdir -p docs/src/snippets docs/src/command-output docs/src/content/docs/reference/package-catalog
              cp -r --no-preserve=mode "$snip"/. docs/src/snippets/
              cp -r --no-preserve=mode "$command_outputs"/. docs/src/command-output/
              cp -r --no-preserve=mode "$ref"/. docs/src/content/docs/reference/package-catalog/
              chmod -R u+w docs/src/snippets docs/src/command-output docs/src/content/docs/reference/package-catalog

              cd docs

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
