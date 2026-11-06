# Changelog

What changed in each Kix release. Kix uses semantic versioning and is still
below 1.0: a minor release (0.5 to 0.6) may break things, and a patch release
(0.5.0 to 0.5.1) does not. Each breaking entry says what to change when you
upgrade.

Every pull request that changes something a Kix user sees adds a line under
`## Unreleased`, in one of the sections Breaking, Added, Changed, or Fixed.
`CLAUDE.md` § Versioning and breaking changes says what counts as breaking.

## Unreleased

### Breaking

- Each deploy now writes its build's package index to the Activation record, under `status.packageIndex`. Nothing changes when you upgrade: older Kix ignores the field, and records written without it work as before.
- A package with `lifecycle = "stateful"` fails to build when it renders a custom resource whose kind does not declare `holdsData`. When you upgrade, add `holdsData = true` to the `scope.mkCRD`, `scope.mkCRDRef`, or `kix.mkImport` `crds` entry of each kind that keeps data deleting it loses (a database, a storage pool), and `holdsData = false` to the others (monitoring, certificates, policy). Build those custom resources with `scope.mkCR` so they carry the answer. The packages in this repository declare it already.
- Kix writes a `kix.run/holds-data` annotation (`"true"` or `"false"`) on custom resources whose kind declares `holdsData`, and `"true"` on PersistentVolumeClaims, PersistentVolumes, and StatefulSets with volume claim templates. Cluster operators change nothing in their cluster definitions. Each marked object is re-applied to add the annotation. So is every object that depends on a marked object, directly or through other objects, because its `kix.run/depends-on` annotation names the changed object's new hash. These changes are to object metadata only, and pod templates do not change, so pods do not restart. The exception is a pod template that carries an object's `out.identityHash` as a `checksum/*` annotation (grafana, valkey, and plausible do this for their ConfigMaps and Secrets): its pods roll when that object depends on a marked one. Objects deployed by an earlier release are read as before until then.

### Added

- `cnpg-cluster` can copy databases from another PostgreSQL server when the Cluster is created, through the new `import` option and the `importSource`, `importPassword`, and `importCa` dependencies. Kix derives the network policy between the Cluster's pods and the source.
- The `service-ref` package names a Service Kix does not render, with the pod labels and ports network policy needs, so a server another tool installed can be a dependency.
- `filebrowser` creates or updates the users listed in the new `users` option on every start, with passwords from a `filebrowserUsers` secret, each scoped to a folder and with command execution off. The new `tokenExpirationTime` option sets how long a login lasts.

### Changed

- `cnpg-cluster` refuses `extraSpec.bootstrap.initdb.import`. Set the `import` option instead, which wires the source as a dependency and derives its network policy.
- Security patch upgrades: `immich` 3.3.5, `cilium` 1.19.10, `grafana` 13.1.8, and `prometheus` 3.13.5.
- `filebrowser` keeps its database on the storage claim at `/data/database` and serves `/data/files`, so users survive a restart. The Deployment uses the `Recreate` strategy, because only one process can hold the database file.

### Fixed

- `kix diff` and `kix deploy` no longer stop on a false data migration when a stateful package removes a custom resource that holds no data and adds another, such as a PodMonitor replaced by a PrometheusRule. They read the object's `kix.run/holds-data` annotation, and judge an object without one by its storage fields and API group as before.
- `kix diff` and `kix deploy` no longer report a data migration when a stateful package removes one object and adds another of a different kind that holds no data, such as an import marker replaced by a PodDisruptionBudget. Objects of different kinds now count as a migration only when both may hold data: a custom resource, or a built-in kind that declares storage. A renamed object of the same kind still counts as a migration.
- `kix diff` shows one changed value inside a list item as one change to that value, not as the item removed and a new one added. Lists of objects with a `metadata.name`, such as a VirtualMachine's `dataVolumeTemplates`, match items by that name, and `creationTimestamp: null` on one side no longer counts as a difference. In `-o json` output, the `path` of an added or removed list item now gives its real index in the list.
- `kix diff` and `kix plan` against the cluster no longer show changes to objects the build does not change, such as an empty `value` the API server dropped. `kix diff` now lists drift (fields someone changed on the cluster, and who changed them) on any machine, also when it finds no other difference, and says how many objects it could not check for drift (the new `drift_unchecked` field in `-o json`).
- `kix diff` and `kix plan` against the cluster no longer list an import marker (such as `secret-ref-*`) as a removed package after a failed deploy. The marker shows under the package that declares it. An object that moved to another package and changed now shows only under its new package, with no removal under the old one.
- `kix diff` and `kix plan` against the cluster now show an object that moved to another package and changed as removed from its old package and added to its new one, on any machine, when the deployed record was written by this release. Records from Kix 0.5 still show it only under its new package.

## 0.5.0 - 2026-11-04

The first numbered release. Binaries published before it report the version
`0.1.0+<build number>`, one for each push to main.
