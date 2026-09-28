# 2026-09-27 · `cli/kix-cli/src/cli.rs` · Every subcommand's `--help` lists all global flags, including ones it ignores.

`kix completions --help` offers `-o`, `--context`, `--flake` and `--no-cache`; `kix export --help` offers `-o`; `kix drift --help` offers `--flake`. None of them has any effect there, and nothing warns. The reference pages under `docs/src/content/docs/reference/cli/` have to say so page by page.
