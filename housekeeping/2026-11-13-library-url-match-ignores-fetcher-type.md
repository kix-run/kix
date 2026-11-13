# 2026-11-13 · `cli/kix-core/src/pin_library.rs` · A `git+` url counts as the library input when its path contains the GitHub owner and repository.

`repo_url_of` accepts a `git+` literal when it contains the lock's `owner/repo` as text, even when the lock's `original` is a `github` input. A local checkout such as `git+file:///home/me/github.com/kix-run/kix?ref=v0.10.0-rc.2` therefore counts as the `kix` input of a project locked to `github:kix-run/kix`. `declared_tag` then reports a moved tag, and `reset_moved_tag` rewrites the `git+file` url instead of leaving a change of repository to the check after evaluation. Requiring the literal's scheme to match the lock's `type` would close it, but it also changes which urls `kix upgrade` pins.

This is a symptom of [moved-tag-check-reads-flake-nix-text](2026-11-13-moved-tag-check-reads-flake-nix-text.md).
