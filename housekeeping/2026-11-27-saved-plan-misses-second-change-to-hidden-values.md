# 2026-11-27 · `cli/kix/src/plan/saved.rs` · `kix deploy --plan` cannot see a second change to a reverted Secret value, or to a value over 16 KiB that keeps its length.

`compare` checks each reverted drift field's managers and live value against the saved plan, but `DriftChange.live` holds the value as the plan shows it (`plan/redact.rs`, `shown_value`): a fixed marker for a Secret, and `"(N bytes, not shown)"` for a value over 16 KiB. Both plans then hold the same text, so a change between `kix plan --out` and `kix deploy --plan` passes. Fields the build spells differently from the server (a port without `protocol`, a Secret's `stringData`) have no per-field entry at all. From the fresh plan to the write the forced apply still checks the real values, so the gap is the window between saving the plan and deploying it.

Decision required from Adam, about what a plan file may hold:
- (a) Store a digest of the unredacted value and compare digests. A bare digest of a short Secret can be guessed, so it needs a salt stored in the file, which only slows guessing. Suitable for non-Secret values over the limit.
- (b) For a Secret, compare the time of the other manager's `managedFields` entry. A proxy, since that time moves on any write by that manager.
- (c) Keep the gap and document it (the docs now state it).
