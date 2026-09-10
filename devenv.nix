{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

let
  # Nix C libraries for FFI bindings (nix-bindings-rust).
  # These come from nixpkgs' own `pkgs.nix.libs.*` — no cachix fork or
  # separate nix flake input needed. The .dev outputs provide pkg-config
  # .pc files and C headers that the nix-bindings-*-sys crates find via
  # pkg-config at build time. Adding them to `packages` makes them
  # available in PKG_CONFIG_PATH automatically.
  nixLibs = [
    pkgs.nix.libs.nix-expr-c
    pkgs.nix.libs.nix-store-c
    pkgs.nix.libs.nix-util-c
    pkgs.nix.libs.nix-flake-c
    pkgs.nix.libs.nix-fetchers-c
    pkgs.nix.libs.nix-main-c
  ];

  # A stable, readable name for this checkout: the directory name plus a
  # short digest of its absolute path, so two worktrees of kixpkgs never
  # collide and neither name is a mystery when you look in ~/.cache.
  targetDirKey =
    "${builtins.baseNameOf config.devenv.root}-"
    + builtins.substring 0 12 (builtins.hashString "sha256" config.devenv.root);
in
{
  packages = [
    inputs.claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default
    pkgs.graphviz
    pkgs.lefthook
    pkgs.pkg-config
    pkgs.nixfmt-rfc-style
    pkgs.ruff
    pkgs.kind
    pkgs.kubectl
    pkgs.cilium-cli
    pkgs.vhs
    pkgs.tmux
    pkgs.viddy
    pkgs.k9s
    pkgs.jq
    pkgs.sops
    pkgs.age
    pkgs.nodejs_22
  ]
  ++ nixLibs
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.wf-recorder
  ];

  # devenv's rustc and a host rustup toolchain are rarely the same version.
  # Cargo fingerprints include the compiler version, so if both write to
  # cli/target/ each one invalidates the other's cache and every build from
  # either side starts from scratch. The shared target dir is precisely what
  # keeps it cold. A separate dir costs disk once and lets both stay warm,
  # and (unlike pinning the two toolchains to match) does not silently
  # re-break the next time either side moves.
  #
  # It lives under the user's cache dir rather than in the checkout, because
  # a `path:` flakeref copies a directory into the Nix store with NO
  # filtering. .gitignore is not consulted, so an in-repo target dir is
  # copied verbatim, and a fresh copy is made every time any byte of the
  # tree changes. On 9 Sep 2026 that left two `-source` paths of 47.7 GB and
  # 48.4 GB in the store, against a 40 MB git-filtered tree of the same
  # commit, and filled a 1.9 TB disk overnight. Nothing in the Nix output
  # names the cause. `.claude/hooks/nix_store_guard.py` refuses the command
  # that would do it; keeping the artifacts out of the tree is the other
  # half, and the half that also protects `nix build` from a stale checkout.
  #
  # The path is keyed on this checkout so that worktrees do not share one
  # flat `debug/deps` directory, which is its own slow-build problem
  # (rust-lang/cargo#16665, see .claude/hooks/cargo_target_guard.py).
  #
  # Set in enterShell rather than `env` so that `$XDG_CACHE_HOME` and `$HOME`
  # are expanded by the shell: devenv evaluates hermetically by default, so
  # Nix cannot read them at eval time.

  # Bindgen needs libclang to generate FFI bindings from the Nix C headers.
  # BINDGEN_EXTRA_CLANG_ARGS is required because the headers use C++20 features.
  env.LIBCLANG_PATH = lib.makeLibraryPath [ pkgs.llvmPackages.clang-unwrapped ];
  env.BINDGEN_EXTRA_CLANG_ARGS = builtins.concatStringsSep " " (
    [
      "-x"
      "c++"
      "-std=c++2a"
    ]
    ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
      "-isystem"
      "${pkgs.stdenv.cc.cc}/include/c++/${lib.getVersion pkgs.stdenv.cc.cc}"
      "-isystem"
      "${pkgs.stdenv.cc.cc}/include/c++/${lib.getVersion pkgs.stdenv.cc.cc}/x86_64-unknown-linux-gnu"
      "-isystem"
      "${pkgs.glibc.dev}/include"
    ]
  );

  # DAG visualization scripts for the fixpoint cluster.
  # These evaluate the fixpoint cluster's resource graph at eval time.
  scripts.kix-dag.exec = ''
    nix eval --raw ".#legacyPackages.$(nix eval --raw --impure --expr builtins.currentSystem).fpCluster.dagTree"
  '';
  scripts.kix-dag-dot.exec = ''
    nix eval --raw ".#legacyPackages.$(nix eval --raw --impure --expr builtins.currentSystem).fpCluster.dagDot"
  '';

  # Cluster diff tooling: dump live cluster and compare against kix output.
  scripts.kix-check.exec = ''
    cluster="''${1:?Usage: kix-check <cluster-name> [--context <ctx>]}"
    context="''${2:-}"
    echo "Building kix manifests for $cluster..."
    nix build ".#cluster-$cluster" --extra-experimental-features pipe-operators
    dump_dir="/tmp/kix-dump-$cluster"
    rm -rf "$dump_dir"
    ./scripts/kix-dump.py --match-kix ./result ''${context:+--context "$context"} "$dump_dir"
    ./scripts/kix-diff.py ./result "$dump_dir"
  '';

  # kind: create/delete local cluster and deploy kix manifests.
  scripts.kind-up.exec = ''
    name="''${1:-kix-test}"
    kind create cluster --name "$name" 2>&1
  '';
  scripts.kind-down.exec = ''
    name="''${1:-kix-test}"
    kind delete cluster --name "$name" 2>&1
  '';
  scripts.kind-deploy.exec = ''
    cluster="''${1:?Usage: kind-deploy <cluster-name> [--kind-name <name>]}"
    kind_name="''${2:-kix-test}"
    echo "Building kix manifests for $cluster..."
    nix build ".#cluster-$cluster" --extra-experimental-features pipe-operators
    echo "Applying manifests to kind cluster $kind_name..."
    # Apply CRDs first and wait for them to register
    for f in result/*-customresourcedefinition.yaml; do
      [ -e "$f" ] || continue
      echo "  apply $(basename "$f")"
      kubectl --context "kind-$kind_name" apply -f "$f"
    done
    kubectl --context "kind-$kind_name" wait --for=condition=Established crd --all --timeout=30s 2>/dev/null || true
    # Apply everything (CRDs are idempotent, CRs now work)
    kubectl --context "kind-$kind_name" apply -f result/
    echo "Done."
  '';

  scripts.kix-dag-svg.exec = ''
    cluster="''${1:?Usage: kix-dag-svg <cluster-name> <output-path.svg>}"
    out="''${2:?Usage: kix-dag-svg <cluster-name> <output-path.svg>}"
    nix build ".#cluster-$cluster" --extra-experimental-features pipe-operators
    nix-store --query --graph result | , dot -Tsvg -o "$out"
    echo "DAG written to $out"
  '';

  languages = {
    python = {
      enable = true;
      uv.enable = true;
      uv.sync.enable = true;
    };
    rust.enable = true;
  };

  treefmt = {
    enable = true;
    config.programs = {
      nixfmt.enable = true;
      rustfmt.enable = true;
      ruff-check.enable = true;
      ruff-format.enable = true;
    };
  };

  # Install lefthook git hooks on shell entry
  enterShell = ''
    export CARGO_TARGET_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/kix-cargo-target/${targetDirKey}"
    mkdir -p "$CARGO_TARGET_DIR"

    # lefthook install >/dev/null 2>&1 || true
  '';

  # kix CLI
  scripts.kix.exec = ''
    cargo run --manifest-path "$DEVENV_ROOT/cli/Cargo.toml" --bin kix -- "$@"
  '';

  # k9s with kix plugins: launches k9s with the kix plugin set loaded.
  # Copies the kix plugin file into the user's real k9s config dir, then
  # launches k9s. On exit the plugin file stays (it's harmless and useful).
  # Usage: kix-k9s [--context <ctx>] [k9s flags...]
  scripts.kix-k9s.exec = ''
    K9S_DIR="''${XDG_CONFIG_HOME:-$HOME/.config}/k9s"
    mkdir -p "$K9S_DIR/plugins"
    cp "$DEVENV_ROOT/tools/k9s-plugin/plugins.yaml" "$K9S_DIR/plugins/kix.yaml"
    echo "Installed kix plugins → $K9S_DIR/plugins/kix.yaml"
    k9s "$@"
  '';
}
