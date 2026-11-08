# Changelog

What changed in each Kix release. Kix uses semantic versioning and is still
below 1.0: a minor release (0.5 to 0.6) may break things, and a patch release
(0.5.0 to 0.5.1) does not. Each breaking entry explains what to update when
you upgrade.

Each release groups changes under these headings:

- **Breaking (shows an error):** Kix stops with an error that tells you what to
  change.
- **Breaking (no error):** nothing fails, but behavior or output changes. Read
  these first.
- **Upgrade notes:** nothing to change in your code, but worth knowing before
  you upgrade.
- **Added**, **Changed**, and **Fixed**.

## Unreleased

### Changed

- Errors about `kix.toml`, the `nix` builder, the Kix library version, and Helm are shorter. Each one says what is wrong and how to fix it. Scripts that match these messages word for word need updating.

### Fixed

- The `kix.toml` reference page shows its error messages correctly. In 0.7.0 that page stopped the docs site from building.

## 0.7.0 - 2026-11-07

**Before you upgrade**, check these items in your cluster definitions, packages, and scripts. The sections below explain each change.

- Clusters in `kix.lib.mkFlake` that call `kix.buildCluster` without `name` and were deployed with Kix 0.6: add `name = "cluster";` to keep their deploy history.
- `kix.buildCluster` calls outside `kix.lib.mkFlake` without `name`: set `name`.
- `ttlSecondsAfterFinished` on a package Job or in `kix.healthCheck`: remove it.
- Dependencies served by an instance in another namespace: add `deps.<arg> = ref.<namespace>.<instance>` to the consumer, or add `meta.scope = "cluster"` to the provider package.
- `k8sVersion`: make sure it matches the Kubernetes version running on the cluster.
- Broken objects left behind by an earlier deploy: fix them, because deploys that depend on them now fail.
- VictoriaMetrics `extraArgs`: remove flags that the packages now set, and use the options named in the error.
- `kix.withMountsOn`: check that every container name exists in the workload.
- Scripts that look for `completed` in `kix health` output: look for `healthy` instead.
- Scripts or CI jobs that run `nix build .#cluster-<name>-activation`, or that run `nix build` or `nix flake check` on a cluster with Helm charts: switch to `kix build`, `kix bundle`, or `kix diff --from-bundle`, or set `builder = "nix"` in `kix.toml`.
- Machines that run `kix` from `PATH` without its `libexec/kix` folder: install the full release archive, or set `KIX_RUNTIME_DIR`.
- Helm `extraFlags` items that put a flag and its value in one string, such as `"--set a=b"`: split them into separate list items.
- Helm charts that require Helm 3: set `helmVersion = "3"`. The default is now Helm 4.
- Project `flake.lock` files: run `kix lib update` after installing Kix 0.7 so the Kix library version matches Kix.
- Scripts that compare YAML from `kix build`, `kix export`, or `-o yaml` as text, or look for single-quoted values: update them for double quotes.

### Breaking (shows an error)

- `kix deploy`, `kix plan`, and the operator now stop when `k8sVersion` does not match the cluster's running Kubernetes version. Set `k8sVersion` to the version named in the error, rebuild, and deploy. `"1.31"` matches any 1.31.x release, and `"1.31.4"` matches only 1.31.4. `kix rollback` prints a note and continues. Clusters without `k8sVersion` are not checked. See [`k8sVersion`](https://kix.run/docs/reference/cluster-configuration/#clusterprovider-k8sversion-and-clusterkubernetesuid).
- `kix deploy` now fails when an object in the deploy depends on an existing object that is not ready, even if this deploy did not change that object. Fix the broken object and deploy again, or pass `--on-error continue` to deploy everything that does not depend on it. See [Set the readiness timeout](https://kix.run/docs/how-to/operate-a-cluster/deploy-with-dry-run-timeouts-pruning-and-log-tui-output-modes/#set-the-readiness-timeout).
- `kix.buildCluster` no longer defaults `name` to `cluster`. Outside `kix.lib.mkFlake`, pass `name` to `kix.buildCluster`. Inside `kix.lib.mkFlake`, clusters now default to their attribute key in `clusters`. If Kix 0.6 already deployed a `mkFlake` cluster under the old default name `cluster` and `name` is still unset, `kix plan` and `kix deploy` stop so you do not start a separate deploy history and leave old objects behind. Add `name = "cluster";` to keep the old name and deploy history, or set `name = "<key>";` to start fresh under the new name and delete the old records yourself.
- Package Jobs may no longer set `ttlSecondsAfterFinished`, and `kix.healthCheck` no longer accepts that argument. Remove the field from your packages. Finished Jobs now stay on the cluster until a later build removes them, so Kix does not treat them as missing and run them again. CronJob `jobTemplate` definitions may keep `ttlSecondsAfterFinished`, and Kix strips it automatically from Jobs rendered by Helm charts.
- `victoria-metrics-agent`, `victoria-metrics-operator`, and `victoria-metrics-cluster` now reject `extraArgs` flags that Kix manages through package options:
  - In `victoria-metrics-agent`, remove `remoteWrite.url` (set by the `vmCluster` dependency) and `promscrape.config` (managed by the operator).
  - In `victoria-metrics-operator`, remove `--zap-log-level` (use `logLevel` instead), `--leader-elect`, and `--health-probe-bind-address`.
  - In `victoria-metrics-cluster`, remove `retentionPeriod` and `replicationFactor` from `vmstorage.extraArgs`, `vmselect.extraArgs`, and `vminsert.extraArgs` (use the `retentionPeriod` and `replicationFactor` options instead), and remove `httpListenAddr` from `vmselect.extraArgs` and `vminsert.extraArgs` (`out.serviceUrl` and `out.remoteWriteUrl` use ports 8481 and 8480).
- `kix.withMountsOn` now fails the build when the target container name does not exist in the workload, instead of adding an unmounted volume. Fix the container name in `kix.withMountsOn` using the container and init container names listed in the error.
- Kix now stops if the Kix library in `flake.lock` is from 0.6.0 or earlier, or if it expects different Helm 3 and Helm 4 versions than your installed Kix. Run `kix lib update` when Kix is newer than `flake.lock`, or upgrade Kix when `flake.lock` is newer.
- Under the default `kix` builder, clusters that use Helm charts (`kix.helmChart`, `scope.helm.importChart`, or `scope.helm.importChartCrds`) can no longer be built or checked with `nix build .#cluster-<name>` or `nix flake check` (`schema-cluster-<name>` and `rules-cluster-<name>`), and `kix.lib.mkFlake` no longer exports `packages.<system>.cluster-<name>-activation`:
  - To check or build a cluster, run `kix check <cluster>`, `kix build <cluster>`, `kix diff <cluster>`, or `kix deploy <cluster>` (or `scripts/kix-manifests.sh` and `scripts/cluster-checks.sh` in this repository).
  - To save a baseline for `kix diff`, run `kix bundle <cluster> before.kixbundle` and `kix diff <cluster> --bundle after.kixbundle --from-bundle before.kixbundle` (or `kix export <cluster> --out ./manifests` for plain YAML).
  - To keep using `nix build`, `nix flake check`, and `packages.<system>.cluster-<name>-activation`, set `builder = "nix"` in `kix.toml` and run `git add kix.toml`.
- `extraFlags` on `kix.helmChart`, `scope.helm.importChart`, and `scope.helm.importChartCrds` now passes each list item as a single argument to `helm template` instead of splitting on spaces. Split combined flags such as `[ "--set a=b" ]` into `[ "--set" "a=b" ]`, or write `"--set=a=b"`.
- Kix no longer runs `helm`, `kubectl`, or `sops` from `PATH`, and runs `nix` from `PATH` only when `builder = "nix"` is set in `kix.toml`. Instead, Kix uses the tools in `libexec/kix/` next to `bin/kix` (or in `KIX_RUNTIME_DIR`). If `kix` is installed without `libexec/kix/`, it stops with an error. Unpack the full release archive or set `KIX_RUNTIME_DIR`.
- A required dependency that exists only in another namespace now fails the build, and the error prints the `deps` line to add. Packages now default to `meta.scope = "namespace"` (accepted values are `"cluster"` and `"namespace"`). To connect across namespaces, add `deps.<arg> = ref.<namespace>.<instance>` to the consumer, or set `meta.scope = "cluster"` on the provider package (which also limits `availablePackages` to at most one instance). Shared packages in this repository already set `meta.scope = "cluster"`. Packages that claim a role or declare a `cluster:` conflict, `kix.mkImport` stand-ins, and instances created from `availablePackages` or `optional = true` still bind across namespaces. See [Instances and composition](https://kix.run/docs/reference/instances-and-composition/).

### Breaking (no error)

- YAML printed by `kix build`, `kix export`, `kix snapshot save`, and `-o yaml` now uses double quotes instead of single quotes, and leaves values unquoted where YAML allows (such as `kix.run/identity-hash` values and `20Gi`). The data itself is unchanged. Update scripts that compare this YAML as text or search for single quotes.
- `kix health` now reports finished Jobs as `healthy` instead of `completed`, and reports deleted Jobs as missing. Update scripts that check `kix health` output to look for `healthy`.
- An optional dependency (`x ? null`) whose only match is in another namespace now uses its default value instead of binding across namespaces. Kix prints a warning with the `deps` line to add if you want to connect them.
- Helm charts now render with Helm 4 (`4.3.1`) by default instead of Helm 3 (`3.19.1`). Set `helmVersion = "3";` on `kix.helmChart`, `scope.helm.importChart`, or `scope.helm.importChartCrds` if a chart requires Helm 3.
- Deploy receipts and SLSA provenance statements (`source.dirty`) now check only tracked Git files when deciding whether the working tree is dirty. Untracked files no longer mark a build dirty.

### Upgrade notes

- On the first `kix diff`, `kix plan`, or `kix deploy` after upgrading:
  - `kix diff` or `kix plan` may show a `secret-ref-*` or `service-ref-*` PackageInstance as removed from one package. Nothing is deleted, and the first deploy clears it.
  - On clusters with `cilium`, switching the default Helm version to Helm 4 drops three empty keys (`debug-verbose`, `nodeport-addresses`, and `policy-cidr-match-mode`) from the `cilium` ConfigMap. This restarts the Cilium agent, the Cilium operator, and workloads whose checksum annotations depend on them.
  - Kix re-applies Cilium network policies, Velero Backups, Restores, and Schedules, CDI DataVolumes, the controller Deployments of cert-manager (controller and cainjector), kubevirt, cdi, prometheus-operator, victoria-metrics-operator, and clickhouse-operator, PackageInstance records for `persistent-volume-claim`, `storage-classes`, `stackgres-cluster`, and `cnpg-cluster`, and objects that depend on them. Only metadata changes on these objects, so most pods do not restart. Pods whose templates include a checksum of a ConfigMap or Secret that depends on a network policy restart once (such as `grafana`, `loki-logs`, and `immich-server`).
  - The setup Jobs of `reflector` and `ingress-nginx`, cert-manager's `startupapicheck` Job, and all `kix.healthCheck` probes run once more. The bootstrap Jobs of `stackgres-database` and `clickhouse-database` run again only if Kubernetes already deleted them; existing Jobs are patched in place to drop `ttlSecondsAfterFinished`.
  - Because Kix re-applies most objects and now checks the readiness of unchanged objects they depend on, the first deploy checks almost every object on the cluster and fails if an earlier deploy left one broken.
- A cluster that still runs a build from Kix 0.6 with the in-cluster operator will keep re-running its self-deleting Jobs on every reconcile until you deploy a build from Kix 0.7.
- The first command you run after upgrading (`kix build`, `kix check`, `kix list`, `kix graph`, `kix inspect`, `kix images`, `kix status`, or `kix compliance audit`) refreshes `<cache dir>/kix/eval-cache.db` and downloads your locked flake inputs (`nixpkgs`, about 400 MB unpacked) and Helm charts into Kix's local store (`$XDG_CACHE_HOME/kix/store` or `~/.cache/kix/store`), even if Nix is already installed on the machine. Setting `builder = "nix"` in `kix.toml` uses `/nix/store` instead.
- On macOS, Kix now stores its cache and local store in `$XDG_CACHE_HOME/kix` or `~/.cache/kix` instead of `~/Library/Caches/kix`. After upgrading, you can delete `~/Library/Caches/kix` to free disk space.
- Under the default `kix` builder, `./result` directories created by `nix build` before this release cannot be passed to `kix diff --from ./result`. Save baselines with `kix bundle <cluster> before.kixbundle` and compare with `kix diff <cluster> --from-bundle before.kixbundle`, or set `builder = "nix"` in `kix.toml`.
- Kix enforces stricter limits when reading YAML from snapshot folders and SOPS files: at most 64 levels of nesting and one million values from alias expansion. Parse errors now report the location as `at line L, column C`.
- Clusters that set `cluster.kubernetes.uid` now add a `kix.run/kubernetes-uid` label to their in-cluster Activation records. Older Kix versions ignore it.

### Added

- Kix now runs without a system Nix installation, `/nix` directory, or root access. Release archives (`x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`) bundle `bin/kix` with the Kix runtime in `libexec/kix/` (overridden by `KIX_RUNTIME_DIR`), which includes `nix` (`2.35.4`), `helm` (`4.3.1` and `3.19.1`), `kubectl` (`1.37.2`), `sops` (`3.12.1`), `manifest.json`, and `THIRD_PARTY_LICENSES` (with sources in `kix-<version>-third-party-sources.tar.zst`). Kix stores fetched and built files in Kix's local store at `$XDG_CACHE_HOME/kix/store` or `~/.cache/kix/store` (overridden by `KIX_STORE_ROOT`). See [Install and run Kix](https://kix.run/docs/how-to/start-and-inspect/install-and-run-the-kix-cli/).
- `kix.toml` beside `flake.nix` selects the project's builder (`builder = "kix"` by default, or `builder = "nix"`; `builder = "remote"` is reserved and rejected). Setting `builder = "nix"` (and staging it with `git add kix.toml`) uses the system `nix` on `PATH` (Nix 2.24 or later, not Lix) and `/nix/store`. This lets Kix use the machine's `nix.conf` binary caches and remote builders without needing `trusted-users`, supports `nix build` and `nix flake check` on clusters with Helm charts, and exports `packages.<system>.cluster-<name>-activation`. See [`kix.toml`](https://kix.run/docs/reference/kix-toml/).
- `kix doctor` checks your Kix runtime installation and the builder setting in `kix.toml` (with `--flake`). When `builder = "nix"`, it also checks for upstream Nix 2.24 or later and warns if `allow-import-from-derivation` is off. Failed checks show how to fix the problem on the next line. See [`kix doctor`](https://kix.run/docs/reference/cli/doctor/).
- `kix lib update [--dry-run]` updates the project's `kixpkgs` input in `flake.lock` to the `v<version>` tag matching the installed Kix without modifying `flake.nix`. See [`kix lib`](https://kix.run/docs/reference/cli/lib/).
- `helmVersion` (`"3"` or `"4"`, default `"4"`) on `kix.helmChart`, `scope.helm.importChart`, and `scope.helm.importChartCrds` selects between the Helm 4 (`4.3.1`) and Helm 3 (`3.19.1`) in the Kix runtime.
- `kix.lib.mkFlake` now exports `legacyPackages.<system>.kixLib`, so a flake that builds other outputs can merge `mkFlake` and build its own checks with the project's builder (`kixpkgs.lib.forPkgs` supports only the default `kix` builder). See [Use `mkFlake` inside a larger flake](https://kix.run/docs/how-to/start-and-inspect/use-mkflake-in-a-consuming-repo/#use-mkflake-inside-a-larger-flake).
- Clusters listed under `clusters` in `kix.lib.mkFlake` now use their attribute key as their default name unless `name` is set, so you do not have to write the name in both `flake.nix` and the cluster file.
- `cluster.kubernetes.uid` binds a cluster definition to a specific Kubernetes cluster (using the UID of its `kube-system` Namespace). `kix deploy`, `kix plan`, `kix gc`, `kix rollback`, and the operator refuse to run against a different cluster, and once deployed, the cluster refuses definitions that do not name its UID. `kix status` shows the UID in its header (and as `kubernetes_uid` in `kix status --operator -o json`). See [Bind a cluster definition to its Kubernetes cluster](https://kix.run/docs/how-to/operate-a-cluster/bind-a-cluster-definition-to-its-kubernetes-cluster/).
- `kix status` now shows the cluster's Kubernetes version under its ID, and `kix status --operator -o json` includes `kubernetes_version`.
- `kix deploy` now stops waiting immediately when a controller reports that a custom resource will not become ready until its spec changes, showing the condition, reason, and message instead of waiting for the readiness timeout. Built-in packages (including Cilium, Velero, and CDI) now declare these failure states. Package authors can add `readiness.failed` to CRD declarations as a list of `{ condition = { type; status; reason ? }; }` or `{ path; equals; }` entries, with an optional `hint`.
- A new scorecard rule, `architecture.controllerRequiresCrds`, warns when a package defines CRDs and runs a Deployment, StatefulSet, or DaemonSet, but none of its workloads depend on the CRDs. Listing CRDs only in `root.requires` orders downstream packages after the CRDs, not the package's own controller.
- `kix.withMountsOn` now accepts a list of container names as well as a single name, mounts into init containers, works on CronJobs, and allows mounting the same volume into several containers or paths in separate calls. `kix.mount.emptyDir` and `kix.mount.secret` also accept `readOnly`.
- You can now scan `kix` binaries for known vulnerabilities with `cargo audit bin`, syft, trivy, and grype without the source code. Release archives also include the release-time advisory report at `share/kix/cargo-audit.json` (and as `kix-<version>-<system>-cargo-audit.json` on the release). Releases with known dependency vulnerabilities are not published.

### Changed

- `kix` no longer wraps long error lines when writing to a log file or pipe, keeping paths and commands on a single line so you can search and copy them. Terminal output still wraps to the window width.
- When a missing dependency matches several instances in other namespaces, the error now prints a ready-to-paste `deps` line for each match.
- Failed Jobs now remain on the cluster and continue to be reported as failed on later deploys and reconciles. Kix does not delete a failed Job to retry it; change an input so the Job gets a new name, or delete the Job with `kubectl` and deploy again.
- During `kix deploy`, objects that wait more than 10 seconds now show how many downstream objects are waiting on them and name up to three direct dependents (`holds` and `holds_total` in `--log-format json`). When an object fails to deploy, the error also says how many dependent objects were skipped.
- When a namespace exceeds its ResourceQuota, Kix now reports a separate error for each exceeded limit and lists every object whose usage it could not count, grouped by kind. Custom resource kinds whose `usesAtLeast` returns `{ }` (configuration-only kinds such as PrometheusRule, ServiceMonitor, Certificate, and CiliumNetworkPolicy) are left out of the list.
- `kix.guardArgs` now checks flags given as an attribute set (such as VictoriaMetrics `extraArgs`, matching keys with or without leading dashes) as well as lists. Rejected-flag errors in `victoria-metrics-cluster`, `reloader`, and other packages now read `which this package does not accept:` followed by the reason and the option to set instead.
- `stackgres-cluster` and `cnpg-cluster` now report the PostgreSQL version they run as their package version, so `meta.compatibleWith` bounds on these packages check that version. Packages that have no version (such as `persistent-volume-claim` and `storage-classes`) no longer print `warning: package <name> has no version set` during a build or write `<undefined>` to `spec.version`.
- The JSON schemas for `kix diff -o json` and `kix deploy --log-format json` now state that future Kix versions may add fields and line types. Tools that read them should skip unknown fields and line types.
- `kix list` and commands that take a cluster name now explain when the flake has no outputs for your machine's system architecture and show how to add it, instead of reporting the cluster as missing.
- `kix logs` and `kix pf` now run the `kubectl` in the Kix runtime, and `kix deploy` decrypts SOPS secrets with the `sops` in the Kix runtime, so neither tool needs to be on `PATH`.
- Nix evaluation errors now show only the first three stack frames from your code, followed by `(stack trace truncated; run kix with -v to show the full trace)`. Pass `-v` (`--verbose`) to see the full trace.
- `valkey`'s metrics exporter sidecar now sets a CPU limit of `1` instead of `250m` to prevent throttling and `CPUThrottlingHigh` alerts during scrapes. Its pods restart once; set `metrics.resources.limits.cpu` to keep the old limit.

### Fixed

- Updated third-party libraries to fix 16 published security advisories (including TLS certificate validation and TLS downgrade issues) and replace unmaintained or unsound dependencies.
- `kix deploy` no longer counts a Deployment as ready while old pods are still running alongside a new pod that failed to start (for example, because its image does not exist). Kix now waits until all old pods are gone, shows how many old pods remain in the waiting message, and fails with the new pod's error.
- Shared objects listed by two package instances (such as a provider's Secret reference used by a consumer) now stay owned by the instance that built them, instead of switching owners on unrelated changes.
- When Cilium rejects a network policy (`Valid=False`, such as a rule with no `ingress` or `egress` section), `kix deploy` now fails immediately with Cilium's reason instead of waiting for the readiness timeout.
- cert-manager, kubevirt, cdi, prometheus-operator, victoria-metrics-operator, and clickhouse-operator now deploy their CRDs before their controllers. On a first deploy, controllers no longer crash and restart while waiting for the API server to serve their CRDs.
- The in-cluster operator, and `kix deploy` when the previous build is not on disk, no longer re-run completed setup Jobs.

## 0.6.0 - 2026-11-06

### Breaking (shows an error)

- Stateful packages (`lifecycle = "stateful"`) now fail to build if they create a custom resource whose CRD declaration does not set `holdsData`. Add `holdsData = true` to CRD declarations whose resources store data you would lose if deleted (such as databases or storage pools) and `holdsData = false` to others (such as monitoring rules, certificates, or policies) in `scope.mkCRD`, `scope.mkCRDRef`, or `kix.mkImport` `crds`, and create those resources with `scope.mkCR`. Built-in packages already set this.
- `cnpg-cluster` no longer accepts `extraSpec.bootstrap.initdb.import`. Use the `import` option instead, which also sets up the source database dependency and network policy.

### Breaking (no error)

- `filebrowser` now serves only a `files` folder inside its storage claim instead of the whole claim, and keeps its database on the same claim at `/data/database` (using the `Recreate` deployment strategy so users survive restarts). When upgrading, move existing files on the claim into a top-level `files` folder so File Browser continues to show them.

### Upgrade notes

- The first deploy after upgrading re-applies storage objects, custom resources that declare `holdsData`, and their dependents to add the `kix.run/holds-data` annotation. You do not need to change your cluster definitions. Most pods do not restart, though `grafana`, `valkey`, and `plausible` pods may restart once, and the new warning for fields dropped by Kubernetes (see Added) may report fields that CRDs have been dropping since earlier releases.
- `kix deploy --log-format json` adds a `fields_not_kept` line type. Update log validators to use `cli/kix-cli/schema/deploy-log.schema.json`, or skip line types you do not recognize.
- Deploys now save an index of the build's packages in the in-cluster Activation record under `status.packageIndex`. No action is needed, and older Kix versions ignore the field.

### Added

- `cnpg-cluster` can copy databases from another PostgreSQL server when creating a cluster via the new `import` option and the `importSource`, `importPassword`, and `importCa` dependencies, with automatic network policies between the cluster and the source.
- The `service-ref` package declares a Service managed outside Kix, along with its pod labels and ports, so Kix packages can depend on it and generate network policies for it.
- `kix plan` and `kix deploy` now warn when Kubernetes drops or alters a field from the build (for example, a field stripped by a CRD schema or changed by a mutating admission webhook). `kix plan` lists these under `not_kept`, `kix deploy` prints a warning after applying (`fields_not_kept` in `--log-format json`), and the in-cluster operator emits a `FieldsNotKept` Warning event. Neither stops the deploy.
- `filebrowser` adds a `users` option (with passwords from a `filebrowserUsers` secret) to create or update folder-scoped users with command execution disabled on every start, and a `tokenExpirationTime` option to set how long a login lasts.

### Changed

- Security patch upgrades: `immich` 3.3.5, `cilium` 1.19.10, `grafana` 13.1.8, and `prometheus` 3.13.5.

### Fixed

- `kix diff` and `kix deploy` no longer stop with a false data-migration error when a stateful package removes one object and adds another of a different kind that holds no data (such as replacing a PodMonitor with a PrometheusRule, or an import reference with a PodDisruptionBudget). Objects of different kinds now count as a migration only when both hold data. Renaming an object of the same kind still counts as a migration.
- `kix diff` now shows a changed value inside a list item as a single change instead of removing and re-adding the whole item. Lists of objects with `metadata.name` (such as a VirtualMachine's `dataVolumeTemplates`) are matched by name, `creationTimestamp: null` on one side is ignored, and `-o json` reports the real list index in `path`.
- `kix diff` and `kix plan` against a cluster no longer show false changes on objects the build did not change (such as an empty `value` dropped by the API server). `kix diff` also reports cluster drift (live edits and who made them) from any machine even when the build has no other changes, and reports how many objects it could not check for drift (`drift_unchecked` in `-o json`).
- `kix diff` and `kix plan` against a cluster no longer show import references (such as `secret-ref-*`) as removed packages after a failed deploy. When an object moves to another package and changes, `kix diff` and `kix plan` now show it under both the old and new packages (once deployed with Kix 0.6 or later).

## 0.5.0 - 2026-11-04

The first numbered release. Binaries published before it report the version
`0.1.0+<build number>`, one for each push to main.
