# 2026-11-17 · `cli/kix-cli/src/commands/images.rs` · The image examples name a cert-manager tag that goes stale.

The doc comment in `images.rs:14` and `cli/kix-cli/schema/list-images.schema.json:7` give `quay.io/jetstack/cert-manager-controller:v1.21.2` as an example. Every bump of cert-manager leaves them naming an old tag, and `check-bump` lists them for review. Use a placeholder tag, or a package that does not move often.
