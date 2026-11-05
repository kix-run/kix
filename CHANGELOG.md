# Changelog

What changed in each Kix release. Kix uses semantic versioning and is still
below 1.0: a minor release (0.5 to 0.6) may break things, and a patch release
(0.5.0 to 0.5.1) does not. Each breaking entry says what to change when you
upgrade.

Every pull request that changes something a Kix user sees adds a line under
`## Unreleased`, in one of the sections Breaking, Added, Changed, or Fixed.
`CLAUDE.md` § Versioning and breaking changes says what counts as breaking.

## Unreleased

### Added

- `cnpg-cluster` can copy databases from another PostgreSQL server when the Cluster is created, through the new `import` option and the `importSource`, `importPassword`, and `importCa` dependencies. Kix derives the network policy between the Cluster's pods and the source.
- The `service-ref` package names a Service Kix does not render, with the pod labels and ports network policy needs, so a server another tool installed can be a dependency.
- `kix plan` and `kix deploy` warn when Kubernetes would not keep, or did not keep, a field as the build sets it: a field a CRD's schema drops, or a value a mutating admission webhook changes. `kix plan` lists these fields in a new `not_kept` section, and `kix deploy` prints a warning after the apply (a `fields_not_kept` line in `--log-format json`). Neither stops the deploy.

### Changed

- `cnpg-cluster` refuses `extraSpec.bootstrap.initdb.import`. Set the `import` option instead, which wires the source as a dependency and derives its network policy.

### Fixed

- `kix diff` and `kix deploy` no longer report a data migration when a stateful package removes one object and adds another of a different kind that holds no data, such as an import marker replaced by a PodDisruptionBudget. Objects of different kinds now count as a migration only when both may hold data: a custom resource, or a built-in kind that declares storage. A renamed object of the same kind still counts as a migration.
- `kix diff` shows one changed value inside a list item as one change to that value, not as the item removed and a new one added. Lists of objects with a `metadata.name`, such as a VirtualMachine's `dataVolumeTemplates`, match items by that name, and `creationTimestamp: null` on one side no longer counts as a difference. In `-o json` output, the `path` of an added or removed list item now gives its real index in the list.
- `kix diff` and `kix plan` against the cluster no longer show changes to objects the build does not change, such as an empty `value` the API server dropped. `kix diff` now lists drift (fields someone changed on the cluster, and who changed them) on any machine, also when it finds no other difference, and says how many objects it could not check for drift (the new `drift_unchecked` field in `-o json`).
- `kix diff` and `kix plan` against the cluster no longer list an import marker (such as `secret-ref-*`) as a removed package after a failed deploy. The marker shows under the package that declares it. An object that moved to another package and changed now shows only under its new package, with no removal under the old one.

## 0.5.0 - 2026-11-04

The first numbered release. Binaries published before it report the version
`0.1.0+<build number>`, one for each push to main.
