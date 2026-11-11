# 2026-11-11 · `cli/kix-core/src/project.rs` · Kix 0.9.1 and older refuse a `kix.toml` with an `[upgrade]` table, so the table breaks an upgrade that steps through them.

`ProjectConfig::parse` stops on any key it does not know. Once a project sets `[upgrade] min-age`, every older Kix that `kix upgrade` builds with on the way fails with "unknown setting `upgrade`", and so does a teammate on an older Kix. Selection still hands over because `kix_setting` ignores other keys. Each new `kix.toml` key repeats this problem.
