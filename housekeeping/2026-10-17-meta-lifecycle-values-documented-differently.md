# 2026-10-17 · `docs-legacy/HANDBOOK.md` · The allowed `meta.lifecycle` values differ between documents.

`HANDBOOK.md:267` lists four values, including `durable` and `ephemeral`. `.claude/skills/kix-migration/SKILL.md:711` lists two, `stateless` and `stateful`. Neither says what the code accepts; check `kix/lib/core/activation.nix` before choosing which document is right.
