# 2026-11-13 · `cli/kix-cli/src/plan/render.rs` · The "not checked" lines put a plural count before a singular verb.

`kix deploy` prints `? 2 calls an admission webhook whose Service is missing or not ready, and this deploy writes that Service:`. It should read "2 call" or name the objects first. Other `UncheckedReason` lines may share the pattern.
