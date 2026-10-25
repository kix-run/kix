# 2026-10-09 · `scripts/vendor_crds/test_vendor_crds.py` · Ruff rejects four list comprehensions in this test with E741, so the dev shell's treefmt step fails on every start.

Each `nix develop` runs `devenv:treefmt:run`, and its `ruff-check` reports
`E741 Ambiguous variable name: l` at lines 217, 219, 223 and 225, then ends
`Found 4 errors.` and marks the task failed. The shell still opens, so the
failure scrolls past in every hook run and hides any new lint error behind it.
