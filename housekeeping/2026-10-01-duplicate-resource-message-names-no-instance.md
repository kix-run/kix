# 2026-10-01 · `kix/lib/eval/validate.nix` · Rule 7's duplicate-resource message names no instance.

Rule 7 (`validate.nix:429-441`) reports `Duplicate resource:
<kind>/<namespace or cluster-scoped>/<name>` and not the instances that built
the two objects. Two same-named instances of a cluster-scoped package in
different namespaces fail this way: `instances.a.high` and `instances.b.high`
of `priority-class` give `Duplicate resource: PriorityClass/cluster-scoped/high`,
and the user has to search the cluster file for the name.
