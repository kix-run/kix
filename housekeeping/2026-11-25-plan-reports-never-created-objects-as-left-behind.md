# 2026-11-25 · `cli/kix/src/cluster/apply/mod.rs` · A plan reports objects a stopped deploy never created as "left the build, still on the cluster".

`fold_failed_closures` adds every object of a failed record's build that the new build lacks as an orphan. It does not check that the stopped deploy created the object. The plan and the deploy then print `left the build, still on the cluster` for an object that does not exist, and finalize writes the build to `status.orphansKeptFrom`.

Seen on kind: a deploy stopped before it created `ConfigMap/fresh-cfg`, and the next deploy of the old build listed it as left behind. `kubectl get` returned NotFound. A deploy with `--only` makes this common, because most of its build is not applied.
