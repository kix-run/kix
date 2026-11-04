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

### Changed

- `cnpg-cluster` refuses `extraSpec.bootstrap.initdb.import`. Set the `import` option instead, which wires the source as a dependency and derives its network policy.

### Fixed

- `kix diff` and `kix deploy` no longer report a data migration when a stateful package removes one object and adds another of a different kind that holds no data, such as an import marker replaced by a PodDisruptionBudget. Objects of different kinds now count as a migration only when both may hold data: a custom resource, or a built-in kind that declares storage. A renamed object of the same kind still counts as a migration.

## 0.5.0 - 2026-11-04

The first numbered release. Binaries published before it report the version
`0.1.0+<build number>`, one for each push to main.
