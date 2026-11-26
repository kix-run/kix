# Scripts

Helper scripts for building, testing, checking, and releasing Kix.

- Run every script from the repository root.
- Python scripts that start with a `# /// script` block declare their own dependencies. Run the file directly or with `uv run` to install them.
- `parity/`, `change_records/`, and `vendor_crds/` hold the shared Python code for these scripts and their unit tests.

## Find a script

### Cluster builds and kind tests

| Script | Run by | What it does |
| --- | --- | --- |
| [`kix-manifests.sh`](#build-and-check-cluster-manifests) | Other scripts, by hand | Writes a cluster's manifests to a directory through `kix build`, including clusters that use Helm. |
| [`cluster-checks.sh`](#build-and-check-cluster-manifests) | By hand | Runs the schema check and alert rule tests for one cluster on manifests from `kix-manifests.sh`. |
| `kix-rollback-check.sh` | By hand | Builds one cluster, a variant of it, and the first cluster again, then checks that the first and last builds are identical. |
| `kind-gateway.sh`, `kind-mayastor.sh`, `kind-operators.sh`, `kind-spread.sh`, `kind-velero.sh`, `kind-virtualization.sh` | By hand | Each script creates a kind cluster, deploys the test cluster named in its header, and checks the result. `kind-spread-config.yaml` configures the three-zone cluster for `kind-operators.sh` and `kind-spread.sh`. |
| `test-monitoring-integration.sh` | By hand | Deploys `clusters/test-monitoring-native.nix` to a new kind cluster and checks that Prometheus, Alertmanager, and Grafana work. |

### Live-cluster comparison

| Script | Run by | What it does |
| --- | --- | --- |
| [`kix-dump.py`](#dump-a-live-cluster) | By hand | Dumps live cluster resources into a directory of normalized YAML files. |
| [`compare-cluster-dump.py`](#compare-a-build-with-a-dump) | By hand | Compares a Kix build with a dump from `kix-dump.py` and reports the differences. |
| `cnp-diff.py` | By hand | Compares the Cilium network policies of a build and a dump by the access they allow, whatever their names. |
| `summarize-report.py` | By hand | Summarizes the JSON report from `compare-cluster-dump.py --json-output`. |

### Package bumps and CRD vendoring

| Script | Run by | What it does |
| --- | --- | --- |
| [`vendor-crds.py`](#refresh-vendored-crds) | CRD vendoring workflow, `crd-vendoring` skill | Refreshes the CRDs and operator roles that packages vendor, or checks them with `--check`. |
| `vendor-clickhouse-crd-schemas.py` | By hand, when bumping `clickhouse-operator` | Vendors the Altinity operator's CRD schemas into the package. |
| [`check-bump.sh`](#verify-a-package-version-bump) | Bump agent workflow, `package-authoring` skill | Reports whether a package version bump is complete. |

### Pull request checks and change records

| Script | Run by | What it does |
| --- | --- | --- |
| `change-kind.py` | Change kind workflow | Builds a set of clusters at a pull request's base and head, then checks its change records against what changed. |
| [`change-records.py`](#check-change-records-and-write-the-changelog) | Changelog workflow, `release` skill | Checks the change records under `changes/` and writes `CHANGELOG.md` from them. |
| `copy-pass` | Authors, before a pull request | Hands changed user-facing text to Antigravity for an edit (see `CLAUDE.md`, "User-facing text"). |
| `private-names` | Private names workflow, `pre-commit` and `commit-msg` hooks | Refuses added lines, commit messages, and pull request text that contain a name from a list of private names kept outside the repository. |

### Release signing

| Script | Run by | What it does |
| --- | --- | --- |
| `sign-release.sh` | Release job and release rehearsal in `.github/workflows/cli-tests.yml` | Runs as `scripts/sign-release.sh <dist-dir>` to sign a release's `SHA256SUMS` with the key in `KIX_RELEASE_SIGNING_KEY` (see `cli/kix/release-keys/README.md`). |
| `sign-index.sh` | `pages.yml`, release rehearsal in `cli-tests.yml` | Signs the release index (`releases/index.json`) that `kix.run` serves. |

## Build and check cluster manifests

Kix fulfills Helm chart fetching and rendering (`fetchHelmChart` and `importChart`), so `nix build .#cluster-<name>` cannot build clusters that use Helm directly.

### Write manifests to a directory

```bash
scripts/kix-manifests.sh <flake-dir> <cluster> <out-link>
```

Evaluates `<cluster>` through `kix build -o json` and writes the standard `<namespace>/<name>-<kind>.yaml` directory tree to `<out-link>` using `kix.mkManifests`.

`kix-manifests.sh` chooses which `kix` executable to run in this order:

1. The executable named by `KIX`, if set.
2. `nix run <flake-dir>#kix`, when the project's `kix.toml` sets `library = "self"` (as this repository does), so Kix and the Kix library come from the same checkout.
3. `kix` on `PATH` in any other project, which runs the version named in the project's `flake.lock`.

### Run schema and alert rule checks

```bash
scripts/cluster-checks.sh <flake-dir> <cluster> [<rules-test.yaml>]
```

Builds the manifest directory with `kix-manifests.sh`, then runs both `kixChecks.schemaCheck` (`kubeconform`) and `kixChecks.rulesCheck` (`promtool`) against it.

## Compare a build with a live cluster

Run these three commands to compare a compiled cluster against a running cluster:

```bash
# 1. Write the cluster's manifests to ./result
./scripts/kix-manifests.sh . <cluster> ./result

# 2. Dump the live cluster, only the objects the build declares
./scripts/kix-dump.py --match-kix ./result --context <context> cluster-dump/

# 3. Compare
./scripts/compare-cluster-dump.py ./result cluster-dump/
```

In the `devenv` shell, `kix-check <cluster> [<context>]` runs all three steps.

Both `kix-dump.py` and `compare-cluster-dump.py` detect the directory layout automatically: flat `{ns}--{name}-{kind}.yaml` files, or nested `{ns}/{name}-{kind}.yaml` files as `kix-manifests.sh` and `kix-dump.py` write them.

### Dump a live cluster

`kix-dump.py` organizes dumped files by namespace:

```
cluster-dump/
  _cluster/          # cluster-scoped resources
  kube-system/
  monitoring-system/
  ...
  README.md          # dump metadata, command used, and skipped resources
```

Select which resources to fetch with one of these flags:

| Flag | What it fetches |
| --- | --- |
| `--match-kix <dir>` | Exactly the resources in a Kix output directory. Gives the tightest comparison. |
| `--managed` | All resources with the `app.kubernetes.io/managed-by=kix` label. |
| `--namespaces ns1,ns2` | All resources in the given namespaces. |
| `--all` | All namespaced and cluster-scoped resources. Useful for discovery. |

During a dump, `kix-dump.py` normalizes and filters resources:

- **Server-side fields**: Strips `uid`, `resourceVersion`, `managedFields`, `status`, and other server-populated fields.
- **Secrets**: Strips `Secret` data and keeps only `metadata` and `type`.
- **Skipped resource types**: Excludes ephemeral and runtime resources such as `pods`, `replicasets`, `events`, `jobs`, `endpoints`, and similar types from broad dumps. The generated `README.md` in the dump directory lists every skipped resource.

### Compare a build with a dump

`compare-cluster-dump.py` writes a structured Markdown report to stdout (or JSON with `--json-output`) and writes progress to stderr.

```bash
# View in terminal
./scripts/compare-cluster-dump.py ./result cluster-dump/

# Copy to clipboard for LLM
./scripts/compare-cluster-dump.py ./result cluster-dump/ | pbcopy

# Save to file
./scripts/compare-cluster-dump.py ./result cluster-dump/ > drift-report.md

# Ignore specific JSON paths
./scripts/compare-cluster-dump.py ./result cluster-dump/ --ignore-path '*.annotations'
```

The Markdown report contains six sections:

| Section | Contents |
| --- | --- |
| **Summary** | Counts of identical, modified, Kix-only, and cluster-only resources. |
| **Probable renames / moves** | Resources that likely exist under a different name, with structural diffs. Mutual best-match and structural similarity filtering avoid false positives. |
| **`kix-only`** | Resources Kix declares that the cluster does not have. |
| **Cluster-only** | Resources in the cluster that Kix does not declare. |
| **Modified** | Resources that exist in both and differ, with JSON-path diffs. |
| **Identical** | Resources that match exactly (collapsed). |

Differences are shown by JSON path:

```
  ~ $.spec.replicas:
      kix:     1
      cluster: 3
  + $.spec.strategy.type: 'RollingUpdate'    (cluster only)
  - $.spec.template.spec.nodeSelector: ...   (kix only)
```

## Refresh vendored CRDs

`vendor-crds.py` reads both `kix/packages/stable/<pkg>/crds/` and `kix/packages/experimental/<pkg>/crds/`:

- **Public URLs**: Listed in `crds/sources.txt`, one URL per line, with optional CRD names to take from a bundle.
- **Other upstreams**: Implemented in `crds/update.py`, exposing `crds() -> list[dict]` against `scripts/vendor_crds/`.

CI runs `vendor-crds.py --check` on every pull request that touches a package and fails on drift. The `crd-vendoring` skill maintains vendored CRDs.

```bash
uv run scripts/vendor-crds.py                # every package
uv run scripts/vendor-crds.py velero arc     # just these
uv run scripts/vendor-crds.py --check        # what CI runs
```

## Verify a package version bump

```bash
scripts/check-bump.sh <package-dir> <old-version> [<base-commit>]
```

`check-bump.sh` checks each requirement of a package upgrade:

- The working tree is committed.
- No old image digest remains outside release history and recorded test fixtures.
- A change record was added.
- Vendored CRDs and roles are current.
- The Kix library tests pass.
- The CLI snapshot tests pass, when a snapshot named `<old-version>`.

The script prints one line for each check, lists every place `<old-version>` still appears, and ends with `check-bump: PASS` or `check-bump: FAIL`. The `package-authoring` skill ("Upgrading the version a package pins") explains when to run it.

## Check change records and write the changelog

`changes/README.md` defines the change record format. `scripts/change_records/` holds the parser and logic for `change-records.py` so other scripts can import the parser.

- The Changelog workflow runs `check`.
- The `release` skill runs `bump` and `release`.

```bash
scripts/change-records.py check                   # every record's format
scripts/change-records.py changelog               # the next release's section
scripts/change-records.py release 0.10.0          # move records, write CHANGELOG.md
cd scripts && python3 -m unittest change_records.test_change_records
```
