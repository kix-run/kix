# 2026-11-11 · `cli/kix/src/plan/baseline.rs` · A rollback whose current build is not on this machine writes every object again and leaves the current build's objects.

`Baseline::of_record` has nothing to compare with when the current deployment's
build is missing, so the rollback re-applies every object of the target and
deletes none of the objects only the current build has. `Baseline::of_cluster`
already rebuilds a baseline from live objects for `kix deploy`; `of_record`
does not. The warning has to explain this during an incident.
