# 2026-11-08 · `CLAUDE.md` · CLAUDE.md tells agents to update `docs-legacy/` files that no longer exist.

The "user-facing reference docs" paragraph names `docs-legacy/BEST-PRACTICES.md`, `docs-legacy/HANDBOOK.md`, and `docs-legacy/FEATURE-CATALOG.md`, but `2d00c042` consolidated them into the Starlight docs under `docs/`. An agent following the rule looks for the files, finds nothing, and either skips the docs step or wastes time searching.
