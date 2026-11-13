# 2026-11-13 · `kix/lib/eval/cluster.nix` · The build index has a `warnings` entry only when there are warnings.

Lines 895-899 add `warnings` only for a non-empty list, so the CLI (`cli/kix-core/src/eval/cli_backend.rs:100`, `build_files.rs:113`) has to handle a missing entry and an empty one. The comment there compares with the index before the change. Always write the entry, and delete the comment.
