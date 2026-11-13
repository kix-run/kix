# 2026-11-13 · `cli/kix-cli/src/cli_surface.rs` · The CLI surface snapshot leaves out the environment variables Kix reads.

Removing `KIX_OUTPUT` changed no line of `cli/kix-cli/tests/snapshots/cli_surface.snap`, so the change-kind check could not see it, and only the hand-written record caught the break. The snapshot also lists every `-o` format a command parses, not the flags a format needs, so a change to those conditions in `FORMATS` (`cli/kix-cli/src/dispatch.rs`) passes unseen too. Both are part of what a script depends on.
