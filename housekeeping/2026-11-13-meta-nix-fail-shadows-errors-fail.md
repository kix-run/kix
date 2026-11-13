# 2026-11-13 · `kix/lib/meta.nix` · A local function named `fail` builds an assertion record next to calls to `errors.fail`, which throws.

`fail` (line 10) returns an assertion record, while `errors.fail` (101, 141) throws an error. A reader can confuse the two. Rename the local one to `failedAssertion`.
