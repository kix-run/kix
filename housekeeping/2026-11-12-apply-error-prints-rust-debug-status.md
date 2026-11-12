# 2026-11-12 · `cli/kix/src/cluster/apply/ssa.rs` · A failed apply ends its message with the API error's Rust debug form.

After a clear explanation, the line goes on with `Status { status: Some(Failure), code: 409, ... metadata: Some(ListMeta { continue_: None, ... }) ... }`. That is about 600 characters, and none of it adds to the sentence before it.
