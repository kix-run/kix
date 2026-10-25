# 2026-10-17 · `flake.nix`, `clusters/flake.nix` · Test clusters are registered in two flakes, and nothing says which belong in the root one.

`clusters/flake.nix` lists every test cluster; root `flake.nix:28-61` lists a subset (openbao, falco, metrics-server, otel-collector, the swap fixtures). An author adding a package cannot tell whether to register in both. Decision required from the maintainers: the rule for the root list.
