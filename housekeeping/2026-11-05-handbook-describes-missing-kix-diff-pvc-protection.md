# 2026-11-05 · `docs-legacy/HANDBOOK.md` · The diff section says `kix-diff.py` warns on changed PVCs and that stateful packages enforce no deletion, but no such script or check exists.

The "PVC modification warnings" bullet in HANDBOOK §26 names `kix-diff.py`, which is not in `scripts/`, and FEATURE-CATALOG's `kix diff` entry says "Warns on PVC modifications". The only reader of `lifecycle = "stateful"` in the CLI is migration pair detection (`cli/kix/src/cluster/migrate.rs`). A reader who trusts the docs expects a deletion guard on claims that is not there.
