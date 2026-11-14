# 2026-11-14 · `cli/kix/src/plan/diff.rs` · `PackageChangeDiff::secrets` records which resources are core Secrets, which the id now says.

The plan keeps a separate set of the changed resources that are `v1` Secrets because `ResourceId` had no group. The id now carries the group, so the set repeats what `rid.group == "" && rid.kind == "Secret"` says, and the two can drift apart.
