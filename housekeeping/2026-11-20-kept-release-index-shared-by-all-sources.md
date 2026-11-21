# 2026-11-20 · `cli/kix/src/release/trust.rs` · Kix keeps one newest index for every release source, so a mirror a day behind kix.run is refused as if it hid a release.

`<data dir>/release-index.json` holds the newest index from any source. A machine that has read kix.run and then sets `KIX_RELEASE_SOURCE` to a mirror that syncs daily gets "Someone may be serving an old index to hide a release" until the mirror catches up. Keying the kept file by source would let a mirror lag without a refusal, at the cost of letting a stale mirror hide a withdrawal from machines that also use kix.run.
