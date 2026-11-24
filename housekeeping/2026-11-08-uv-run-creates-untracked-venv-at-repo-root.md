# 2026-11-08 · `scripts/vendor-crds.py` · `uv run scripts/vendor-crds.py` creates a `.venv` at the repo root, and `.gitignore` does not cover it.

The crd-vendoring skill runs the script with `uv run`. Outside devenv, that leaves an untracked `.venv/` directory in the checkout. A `path:` flakeref would copy it into the Nix store.
