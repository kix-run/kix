# 2026-11-28 · `cli/kix-cli/src/commands/gc/plan.rs` · `kix gc --full-scan` names no package for garbage this Kix wrote.

`judge_hard` takes a garbage object's package from its live `kix.run/package` note unless the object is a package instance record. Kix no longer sends that note, so garbage written by this Kix shows no package, and only objects an older Kix wrote still show one.
