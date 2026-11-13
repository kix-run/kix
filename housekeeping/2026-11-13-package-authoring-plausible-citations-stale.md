# 2026-11-13 · `.claude/skills/package-authoring/SKILL.md` · The pattern table cites plausible lines that no longer hold the code it names.

The row "A step after the migrations on one replica of a dependency" points at `plausible:517-560, 604-605`. Lines 604-605 of `kix/packages/experimental/plausible/default.nix` are a `deepSeq` of checks, and the `checksum/replicate` annotation the row means is at lines 632-633. An author who follows the citation reads the wrong code.
