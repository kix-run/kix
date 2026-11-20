# 2026-11-08 · `devenv shell` · Entering the shell runs the formatters with `--fix` and rewrites tracked files.

`devenv shell -- <command>` ran `ruff-check --fix` and the Nix formatter over the tree. It rewrapped lines in `cli/fuzz/seed.py`, `scripts/vendor_crds/__init__.py`, `scripts/vendor-clickhouse-crd-schemas.py`, and `kix/packages/grafana/default.nix`, and the ruff step failed on E741 in `scripts/vendor_crds/test_vendor_crds.py`. Running one command such as `kubectl` in the shell should not modify the working tree.
