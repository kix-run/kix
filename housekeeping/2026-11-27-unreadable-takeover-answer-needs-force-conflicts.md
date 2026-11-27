# 2026-11-27 · `cli/kix/src/cluster/apply/ssa.rs` · For some objects Kix can never read what a forced apply would take, and only `--force-conflicts` takes the drift back.

`taken_in` returns `Takes::Unknown` and the plan keeps no answer when a field in the server's conflict answer does not resolve on the object (`value_at`). This happens every time, not by chance, when the other manager's entry was recorded under another API version whose paths differ, when the other manager owns a field the object no longer holds, and when the kind is served by an aggregated API server that refuses dry runs. Each deploy then shows a conflict. The way out is `--force-conflicts`, which forces every object in the deploy, or `ownership.cede`. The deploy docs now say this.

Options: (1) leave it documented. (2) On `Unknown`, read the object again at the other manager's API version and resolve the path there; this costs one more GET per such object and an API version in `TakenField`.
