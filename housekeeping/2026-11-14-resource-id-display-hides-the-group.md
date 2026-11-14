# 2026-11-14 · `cli/kix-core/src/manifest/types.rs` · A `ResourceId` prints without its API group, so two objects can print alike.

`Display` and `display_id` give `Kind/name@namespace`. Two objects that differ only in their group, such as a `batch` Job and a `batch.volcano.sh` Job of one name, print the same in plan output, deploy progress, and errors. The plan file's `shown` map and `new_manifest` are also keyed by that string. `qualified_kind` gives `Job.batch` but only the saved-plan comparison uses it.
Because of this, the planner refuses a build that moves an object to another group under the same kind, namespace, and name (`PlanError::SharedNames`), and the user must deploy the move in two steps.
