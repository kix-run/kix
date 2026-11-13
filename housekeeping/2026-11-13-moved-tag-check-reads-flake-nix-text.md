# 2026-11-13 · `cli/kix-core/src/pin_library.rs` · Kix decides whether the `kix` input's tag moved by scanning the text of flake.nix.

`literals` (line 420), `repo_url_of` (362), and `declared_tag` (442) pick out string literals that look like the library's url and read a tag from them. `flake_lock::project_kix` (`flake_lock.rs:158`) runs this on every command, and `reset_moved_tag` (462) rewrites flake.nix from what the scan found. Any flake.nix the scan misreads gives a wrong answer, and two entries already record such cases: [library-url-match-ignores-fetcher-type](2026-11-13-library-url-match-ignores-fetcher-type.md) and [unlocked-kix-folder-input-skips-version-check](2026-11-13-unlocked-kix-folder-input-skips-version-check.md).

Decision required from Adam: how Kix learns the declared input.
- (a) Recommended. Ask Nix with `read_locks` (`nix flake metadata --no-write-lock-file`, line 141) where a moved tag matters: `kix upgrade` and the check before evaluation. This costs one Nix call.
- (b) Keep the text scan only for choosing the Kix version to run (`select`), and use (a) everywhere else.
- (c) Keep the scan and accept that each new flake.nix shape can bring a new bug.
