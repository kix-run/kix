# 2026-09-27 · `kix/lib/eval/auto.nix` · When two available packages claim the same alias, auto-instantiation silently takes the one whose name sorts first.

`availableByKey` builds its map with `builtins.listToAttrs`, which keeps
the first entry for a duplicate key. With `availablePackages = packages`,
both kube-prometheus-stack and prometheus-operator claim `prometheus` and
`prometheusOperator`, so an alertmanager with no explicit operator gets
the Helm stack, which has no `out.mkAlertmanager`, and fails with
"attribute 'mkAlertmanager' missing". Nothing warns about the collision.
`kix/package-eval.nix` removes kube-prometheus-stack from its
`availablePackages` to avoid it.
