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

- A package with `lifecycle = "stateful"` fails to build when it renders a custom resource whose kind does not declare `holdsData`. When you upgrade, add `holdsData = true` to the `scope.mkCRD`, `scope.mkCRDRef`, or `kix.mkImport` `crds` entry of each kind that keeps data deleting it loses (a database, a storage pool), and `holdsData = false` to the others (monitoring, certificates, policy). Build those custom resources with `scope.mkCR` so they carry the answer. The packages in this repository declare it already.
- Kix writes a `kix.run/holds-data` annotation (`"true"` or `"false"`) on custom resources whose kind declares `holdsData`, and `"true"` on PersistentVolumeClaims, PersistentVolumes, and StatefulSets with volume claim templates. Cluster operators change nothing. The first deploy after the upgrade updates these objects to add the annotation, and objects deployed by an earlier release are read as before until then.

### Added

- `cnpg-cluster` can copy databases from another PostgreSQL server when the Cluster is created, through the new `import` option and the `importSource`, `importPassword`, and `importCa` dependencies. Kix derives the network policy between the Cluster's pods and the source.
- The `service-ref` package names a Service Kix does not render, with the pod labels and ports network policy needs, so a server another tool installed can be a dependency.

### Changed

- `cnpg-cluster` refuses `extraSpec.bootstrap.initdb.import`. Set the `import` option instead, which wires the source as a dependency and derives its network policy.

### Fixed

- `kix diff` and `kix deploy` no longer stop on a false data migration when a stateful package removes a custom resource that holds no data and adds another, such as a PodMonitor replaced by a PrometheusRule. They read the object's `kix.run/holds-data` annotation, and judge an object without one by its storage fields and API group as before.
- `kix diff` and `kix deploy` no longer report a data migration when a stateful package removes one object and adds another of a different kind that holds no data, such as an import marker replaced by a PodDisruptionBudget. Objects of different kinds now count as a migration only when both may hold data: a custom resource, or a built-in kind that declares storage. A renamed object of the same kind still counts as a migration.
- `kix diff` shows one changed value inside a list item as one change to that value, not as the item removed and a new one added. Lists of objects with a `metadata.name`, such as a VirtualMachine's `dataVolumeTemplates`, match items by that name, and `creationTimestamp: null` on one side no longer counts as a difference. In `-o json` output, the `path` of an added or removed list item now gives its real index in the list.

## 0.5.0 - 2026-11-04

The first numbered release. Binaries published before it report the version
`0.1.0+<build number>`, one for each push to main.
