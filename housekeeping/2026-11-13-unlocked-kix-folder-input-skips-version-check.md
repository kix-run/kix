# 2026-11-13 · `cli/kix-core/src/flake_lock.rs` · A `kix` input moved by hand from a tag to a folder is not caught before Nix runs.

With `kix.url = "git+file:///some/dirty/checkout"` in flake.nix and flake.lock still pinning `v0.10.0-rc.3`, Kix reads the lock, treats the project as a 0.10.0-rc.3 release, and runs `kix check`. `nix flake lock` refuses to write the lock ("has an unlocked input"). The moved-tag check compares only tags, so a url without a tag is not compared with the lock.
