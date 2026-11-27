# 2026-11-26 · `cli/kix/src/cluster/revision/store.rs` · Kix asks for `patch` on `packageinstancerevisions`, which it never sends.

`RevisionError::Api` and `OwnCrd::verbs` in `cluster/own_crds/mod.rs` name `get`, `list`, `create`, `patch`, and `delete` on the revisions, and `patch` on their status. `Revisions` only creates, gets, lists, deletes, and patches `status`. The docs and the change record follow the messages, so an account gets one verb more than it needs.
