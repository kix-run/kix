# 2026-11-24 · `ROADMAP.md` · `ROADMAP.md` still documents the removed `kix export --for` flag.

`ROADMAP.md` describes `kix export --for exit` and `kix export --for audit`, which Kix does not accept. Running `kix export --for ...` fails with an argument error; the current flag for keeping Kix metadata is `--with-kix-metadata` (`cli/kix-cli/src/cli/build.rs`).
