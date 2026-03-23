{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

let
  # Nix C libraries for FFI bindings (nix-bindings-rust)
  nixLibs = [
    pkgs.nix.libs.nix-expr-c
    pkgs.nix.libs.nix-store-c
    pkgs.nix.libs.nix-util-c
    pkgs.nix.libs.nix-flake-c
    pkgs.nix.libs.nix-fetchers-c
    pkgs.nix.libs.nix-main-c
  ];
in
{
  packages = [
    inputs.claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default
    pkgs.graphviz
    pkgs.lefthook
    pkgs.pkg-config
  ]
  ++ nixLibs;

  # Bindgen needs libclang to generate FFI bindings
  env.LIBCLANG_PATH = lib.makeLibraryPath [ pkgs.llvmPackages.clang-unwrapped ];
  env.BINDGEN_EXTRA_CLANG_ARGS = "-x c++ -std=c++2a";

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

  # Documentation: build and serve mkdocs-material site.
  scripts.docs-serve.exec = ''
    uv run --group docs mkdocs serve "$@"
  '';
  scripts.docs-build.exec = ''
    uv run --group docs mkdocs build "$@"
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

  # Install lefthook git hooks on shell entry
  enterShell = ''
    lefthook install 2>/dev/null || true
  '';

  # kix CLI
  scripts.kix.exec = ''
    cargo run --quiet --manifest-path "$DEVENV_ROOT/cli/Cargo.toml" -- "$@"
  '';
}
