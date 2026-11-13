# 2026-11-13 · `docs/src/command-output/` · The captured output of `kix history` and `kix gc` shows wording the CLI no longer prints.

`how-to/application-rollback/list.json` starts with "Rollback: deployment history for", which `kix history` dropped. The gc captures say "deployment record(s) kept", and gc's "Nothing to delete" line now says "objects still in use". The captures change only when they run again on kind, so the docs pages that import them show the old text until then.
