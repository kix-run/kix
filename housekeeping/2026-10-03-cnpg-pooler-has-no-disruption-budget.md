# 2026-10-03 · `kix/packages/cnpg-pooler` · Pooler pods get no PodDisruptionBudget, so a node drain can stop every PgBouncer pod at once.

The CloudNativePG operator creates none for a Pooler, and Kix derives budgets only for workloads it renders. At availability `pod` and up the package runs two pods and spreads them, but a drain of both nodes in turn can still leave no pod ready. A budget over `cnpg.io/poolerName` would need a way to declare one for operator-created pods.
