# 2026-10-03 · `cli/kix-cli/src/commands/drift.rs` · The `/scale` drift message states as fact a cause it only infers, and the search behind it can run its full length for nothing.

`scale_line` says `spec.replicas` changed "through /scale", but `unrecorded_scale` only sees that no managedFields entry owns `spec.replicas` and that some replicas value reproduces the applied hash. For a Deployment whose build sets no replicas, no candidate can reproduce the hash, so `unrecorded_scale` hashes all 1025 values from 0 to `SCALE_SEARCH_LIMIT` before giving up.
