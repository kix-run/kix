# Changelog

What changed in each Kix release. Kix uses semantic versioning and is still
below 1.0: a minor release (0.5 to 0.6) may break things, and a patch release
(0.5.0 to 0.5.1) does not. Each breaking entry says what to change when you
upgrade.

A release lists its changes under these headings:

- **Breaking (shows an error):** Kix stops with an error that says what to
  change.
- **Breaking (no error):** nothing fails, but the result is different. Read
  these first.
- **Upgrade notes:** nothing to change, but worth knowing before you upgrade.
- **Added**, **Changed**, and **Fixed**.

Every pull request that changes something a Kix user sees adds a line under
`## Unreleased`. `CLAUDE.md` § Versioning and breaking changes says what
counts as breaking.

## Unreleased

### Upgrade notes

- The first deploy after the upgrade applies again each import marker (a `PackageInstance` named `secret-ref-*` or `service-ref-*`) that two packages share, to update its `kix.run/package` annotation. Only annotations change. The first `kix diff` or `kix plan` after the upgrade still reads the index the previous release recorded, which lists such a marker under both packages, so it shows the marker as removed from the package that no longer lists it. Nothing is deleted.

### Changed

- When a namespace is over its ResourceQuota, the error now lists every object Kix could not count, grouped by kind, so you can see that the real usage may be higher. Before, it left out custom resources whose kind declares no `usesAtLeast`. A kind whose `usesAtLeast` returns `{ }` runs nothing and is left out of the list; the packages in this repository now declare that for their kinds that only hold configuration, such as PrometheusRule, ServiceMonitor, Certificate, and CiliumNetworkPolicy. Each limit that is over now gets its own error.
- The JSON schemas of the `kix diff -o json` document and the `kix deploy --log-format json` log now say that later versions of Kix may add fields and new types of line. A program that reads them should skip the ones it does not know.
- When a deploy waits more than 10 seconds on one object, the `waiting` line now also says how many objects wait on it and names up to three of the objects that depend on it directly. The `--log-format json` `waiting` line gains `holds` and `holds_total`.
- `kix list` and cluster lookups now say when the flake has no outputs for your computer's system, and how to add it, instead of reporting the cluster as missing.

### Fixed

- An object that two package instances list, such as a provider's Secret reference that a consumer holds as a part, now belongs to the instance that built it. Before, its owner could switch between the two on any unrelated change to either package.

## 0.6.0 - 2026-11-06

### Breaking (shows an error)

- A stateful package (`lifecycle = "stateful"`) now fails to build if it creates a custom resource whose type does not say whether it holds data. Kix uses this to tell a real data migration from a harmless swap of objects. To fix the build, add `holdsData = true` to each type whose objects hold data you would lose if they were deleted, such as a database or a storage pool. Add `holdsData = false` to the others, such as monitoring rules, certificates, or policies. Set it where the type is declared: the `scope.mkCRD`, `scope.mkCRDRef`, or `kix.mkImport` `crds` entry. Create those custom resources with `scope.mkCR`, so that they carry the setting. The packages in this repository already do this.
- `cnpg-cluster` no longer accepts `extraSpec.bootstrap.initdb.import`, and the build stops with an error. Use the new `import` option instead. It also sets up the dependency on the source database and the network policy to reach it.

### Breaking (no error)

- `filebrowser` now shows only a `files` folder at the top of its storage claim. Release 0.5 showed the whole claim. When you upgrade, move the files already on the claim into a new `files` folder at its top. Otherwise File Browser does not show them. File Browser now keeps its own database on the same claim, at `/data/database`, so its users survive a restart. Its Deployment now uses the `Recreate` strategy, because only one copy of File Browser can use the database file at a time.

### Upgrade notes

- The first deploy after the upgrade applies some objects again. You do not need to change your cluster definitions. Kix now adds a `kix.run/holds-data` annotation to some objects: `"true"` or `"false"` on custom resources whose type declares `holdsData`, and `"true"` on PersistentVolumeClaims, PersistentVolumes, and StatefulSets that create storage. Kix applies each of these objects again to add the annotation. It also applies again every object that depends on one of them, because Kix records each dependency's new hash. Only annotations change, so most pods do not restart. Pods in `grafana`, `valkey`, and `plausible` may restart once. Their pod templates carry a checksum of a ConfigMap or Secret, and that checksum changes when the ConfigMap or Secret depends on an annotated object.
- That first deploy is also the first time the new warning about fields Kubernetes did not keep (see Added) checks these objects. It may list fields that a CRD has been dropping for a long time.
- The `kix deploy --log-format json` log has a new type of line, `fields_not_kept`. A program that checks each line against the 0.5 schema rejects it. Check against the updated `cli/kix-cli/schema/deploy-log.schema.json`, or skip lines whose `type` you do not know.
- Each deploy now saves an index of the build's packages in the Activation record, under `status.packageIndex`. You do not need to do anything. Older Kix ignores the field, and records without it work as before.

### Added

- `cnpg-cluster` can copy databases from another PostgreSQL server when the Cluster is created, through the new `import` option and the `importSource`, `importPassword`, and `importCa` dependencies. Kix derives the network policy between the Cluster's pods and the source.
- The `service-ref` package names a Service Kix does not render, with the pod labels and ports network policy needs, so a server another tool installed can be a dependency.
- `kix plan` and `kix deploy` warn when Kubernetes would not keep, or did not keep, a field as the build sets it: a field a CRD's schema drops, or a value a mutating admission webhook changes. `kix plan` lists these fields in a new `not_kept` section, and `kix deploy` prints a warning after the apply (a `fields_not_kept` line in `--log-format json`). The in-cluster operator records a Kubernetes Warning event with reason `FieldsNotKept`. Neither stops the deploy.
- `filebrowser` creates or updates the users listed in the new `users` option on every start, with passwords from a `filebrowserUsers` secret, each scoped to a folder and with command execution off. The new `tokenExpirationTime` option sets how long a login lasts.

### Changed

- Security patch upgrades: `immich` 3.3.5, `cilium` 1.19.10, `grafana` 13.1.8, and `prometheus` 3.13.5.

### Fixed

- `kix diff` and `kix deploy` no longer report a data migration, and stop the deploy, when a stateful package removes one object and adds another that holds no data. Two examples are an import marker replaced by a PodDisruptionBudget, and a PodMonitor replaced by a PrometheusRule. Objects of different kinds now count as a migration only when both may hold data. Kix reads that from the object's `kix.run/holds-data` annotation. An object without the annotation, such as one an earlier release deployed, holds data when it is a custom resource or a built-in kind that declares storage. A renamed object of the same kind still counts as a migration.
- `kix diff` shows one changed value inside a list item as one change to that value, not as the item removed and a new one added. Lists of objects with a `metadata.name`, such as a VirtualMachine's `dataVolumeTemplates`, match items by that name, and `creationTimestamp: null` on one side no longer counts as a difference. In `-o json` output, the `path` of an added or removed list item now gives its real index in the list.
- `kix diff` and `kix plan` against the cluster no longer show changes to objects the build does not change, such as an empty `value` the API server dropped. `kix diff` now lists drift (fields someone changed on the cluster, and who changed them) on any machine, also when it finds no other difference, and says how many objects it could not check for drift (the new `drift_unchecked` field in `-o json`).
- `kix diff` and `kix plan` against the cluster no longer list an import marker (such as `secret-ref-*`) as a removed package after a failed deploy. The marker shows under the package that declares it.
- `kix diff` and `kix plan` against the cluster show an object that moved to another package and changed as removed from its old package and added to its new one, on any machine. This needs a deployed record written by this release. Against a record from Kix 0.5, the object shows only under its new package.

## 0.5.0 - 2026-11-04

The first numbered release. Binaries published before it report the version
`0.1.0+<build number>`, one for each push to main.
