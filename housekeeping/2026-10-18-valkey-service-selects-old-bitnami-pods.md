# 2026-10-18 · `kix/packages/valkey` · The new valkey Service selector also matches pods of the old Bitnami valkey.

The selector is only `app.kubernetes.io/instance` and `app.kubernetes.io/name`, which the Bitnami `valkey-primary` pods carry too. Until the old StatefulSet is pruned, clients reach the old pod with the old password: immich crash-looped with WRONGPASS on ludo and the deploy halted. The default deploy keeps orphans, so this happens on every upgrade from the Bitnami package.
