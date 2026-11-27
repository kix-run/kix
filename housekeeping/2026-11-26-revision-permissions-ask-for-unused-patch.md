# 2026-11-26 · `cli/kix/src/cluster/own_crds/mod.rs` · The CRD refusal still asks for `patch` on `packageinstancerevisions`, which Kix never sends.

`OwnCrd::verbs` for the revisions names `get`, `list`, `create`, `patch`, and `delete`, and `patch` on their status. `Revisions` only creates, gets, lists, deletes, and patches `status`, and the `RevisionError::Api` message in `revision/store.rs` already leaves out `patch` on the main resource. The `[K9557]` text for a CRD Kix cannot install therefore asks for one verb more than the revision error and the docs do.
