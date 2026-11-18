# Scripts

Every script in this folder, what runs it, and what it is for. Run them from
the repository root. Scripts that start with a `# /// script` block declare
their own Python dependencies, so `uv run` or running the file directly
installs them.

| Script | Run by | What it does |
|---|---|---|
| `change-kind.py` | Change kind workflow | Builds a set of clusters at a pull request's base and head and checks its change records against what changed. |
| `change-records.py` | Changelog workflow, release skill | Checks the change records under `changes/` and writes the changelog from them. |
| `copy-pass` | Authors, before a pull request | Hands the changed user-facing text to Antigravity for an edit (CLAUDE.md, "User-facing text"). |
| `vendor-crds.py` | CRD vendoring workflow, crd-vendoring skill | Refreshes the CRDs and operator roles packages vendor, or checks them with `--check`. |
| `vendor-clickhouse-crd-schemas.py` | By hand, when bumping clickhouse-operator | Vendors the Altinity operator's CRD schemas into the package. |
| `sign-release.sh` | Release job in `cli-tests.yml` | Signs a release's `SHA256SUMS`. |
| `kix-manifests.sh` | Other scripts, by hand | Writes a cluster's manifests to a directory through `kix build`, so it works for clusters that use Helm. |
| `cluster-checks.sh` | By hand | Runs the schema check and the alert rule tests of one cluster on those manifests. |
| `kix-rollback-check.sh` | By hand | Builds one cluster, a variant of it, and the first again, and checks the first and last builds are identical. |
| `kind-gateway.sh`, `kind-mayastor.sh`, `kind-operators.sh`, `kind-spread.sh`, `kind-velero.sh`, `kind-virtualization.sh` | By hand | Each creates a kind cluster, deploys the test cluster its header names, and checks the result. |
| `test-monitoring-integration.sh` | By hand | Deploys `clusters/test-monitoring-native.nix` to a new kind cluster and checks that Prometheus, Alertmanager, and Grafana work. |
| `kix-dump.py` | By hand | Dumps live cluster resources into a directory of normalized YAML. |
| `compare-cluster-dump.py` | By hand | Compares a Kix build with a dump from `kix-dump.py` and reports the differences. |
| `cnp-diff.py` | By hand | Compares the Cilium network policies of a build and a dump by the access they allow, whatever their names. |
| `summarize-report.py` | By hand | Summarizes the JSON report of `compare-cluster-dump.py --json-output`. |

`parity/`, `change_records/`, and `vendor_crds/` hold the code these scripts
share, and their tests.

## Compare a build with a live cluster

```bash
# 1. Write the cluster's manifests to ./result
./scripts/kix-manifests.sh . <cluster> ./result

# 2. Dump the live cluster, only the objects the build declares
./scripts/kix-dump.py --match-kix ./result --context <context> cluster-dump/

# 3. Compare
./scripts/compare-cluster-dump.py ./result cluster-dump/
```

In the devenv shell, `kix-check <cluster> [<context>]` runs all three.

## kix-manifests.sh and cluster-checks.sh

Because Helm chart fetching and rendering (`fetchHelmChart` and `importChart`) are fulfilled by Kix rather than plain `nix build`, clusters that use Helm cannot be built directly with `nix build .#cluster-<name>`.

- `scripts/kix-manifests.sh <flake-dir> <cluster> <out-link>` evaluates the cluster through `kix build -o json` and writes the standard `<namespace>/<name>-<kind>.yaml` directory tree using `kix.mkManifests`.
- `scripts/cluster-checks.sh <flake-dir> <cluster> [<rules-test.yaml>]` builds the manifest directory with `kix-manifests.sh` and runs both `kixChecks.schemaCheck` (`kubeconform`) and `kixChecks.rulesCheck` (`promtool`) against it.
- `scripts/check-bump.sh <package-dir> <old-version> [<base-commit>]` reports whether a package version bump is complete. It checks that the tree is committed, that no old image digest remains outside release history and recorded test fixtures, that a change record was added, that vendored CRDs and roles are current, and that the library tests pass. It runs the CLI snapshot tests when a snapshot named the old version. It prints one line for each check, lists every place the old version still appears, and ends with `check-bump: PASS` or `check-bump: FAIL`. The package-authoring skill, "Upgrading the version a package pins", says when to run it.
- `scripts/sign-release.sh <dist-dir>` signs a release's `SHA256SUMS` with the key in `KIX_RELEASE_SIGNING_KEY`, for the release job and the release rehearsal in `.github/workflows/cli-tests.yml` (`cli/kix/release-keys/README.md`).

## vendor-crds.py

Refreshes the CRDs every package vendors under `kix/packages/stable/<pkg>/crds/`
from the public URLs in that directory's `sources.txt` (one per line, with
optional CRD names to take from a bundle). `--check` fails on drift and runs
in CI on every pull request that touches a package. A package whose upstream
is not a public URL ships `crds/update.py` instead, exposing
`crds() -> list[dict]` against `scripts/vendor_crds/`. An experimental
package's CRDs live under `kix/packages/experimental/<pkg>/crds/`, and the
script reads both folders. The maintainer is the
`crd-vendoring` skill.

```bash
uv run scripts/vendor-crds.py                # every package
uv run scripts/vendor-crds.py velero arc     # just these
uv run scripts/vendor-crds.py --check        # what CI runs
```

## change-records.py

Checks the change records under `changes/` and writes the changelog from
them (`changes/README.md` has the format). The Changelog workflow runs
`check`, and the release skill runs `bump` and `release`. The logic lives in
`scripts/change_records/` so other scripts can import the parser.

```bash
scripts/change-records.py check                   # every record's format
scripts/change-records.py changelog               # the next release's section
scripts/change-records.py release 0.10.0          # move records, write CHANGELOG.md
cd scripts && python3 -m unittest change_records.test_change_records
```

## kix-dump.py

Dumps live cluster resources into a directory of normalized YAML files, organized by namespace.

```
cluster-dump/
  _cluster/          # cluster-scoped resources
  kube-system/
  monitoring-system/
  ...
  README.md          # dump metadata, command used, and skipped resources
```

**Modes:**

| Flag | What it fetches |
|------|----------------|
| `--match-kix <dir>` | Exactly the resources that exist in a Kix output directory |
| `--managed` | All resources with `app.kubernetes.io/managed-by=kix` label |
| `--namespaces ns1,ns2` | All resources in the given namespaces |
| `--all` | Everything across all namespaces + cluster-scoped |

`--match-kix` is the tightest comparison. `--all` is useful for discovery.

**Normalization:** Server-side fields (uid, resourceVersion, managedFields, status, etc.) are stripped. Secret data is stripped: only metadata and type are kept.

**Skipped resource types:** Ephemeral/runtime resources (pods, replicasets, events, jobs, endpoints, etc.) are excluded from broad dumps. See the generated `README.md` in the dump directory for the full list.

## compare-cluster-dump.py

Compares a Kix output directory against a cluster dump and produces a structured markdown report on stdout. Progress goes to stderr.

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

**Report sections:**

- **Summary**: counts of identical, modified, Kix-only, and cluster-only resources
- **Probable renames / moves**: resources that likely exist under a different name, with structural diffs. Uses mutual best-match and structural similarity filtering to avoid false positives.
- **kix-only**: resources Kix declares that the cluster does not have
- **Cluster-only**: resources in the cluster that Kix does not declare
- **Modified**: resources that exist in both but differ, with JSON-path diffs
- **Identical**: resources that match exactly (collapsed)

**Diff format:** Differences are shown by JSON path, not as unified diffs:

```
  ~ $.spec.replicas:
      kix:     1
      cluster: 3
  + $.spec.strategy.type: 'RollingUpdate'    (cluster only)
  - $.spec.template.spec.nodeSelector: ...   (kix only)
```

Both scripts detect the directory layout: flat `{ns}--{name}-{kind}.yaml` files, or nested `{ns}/{name}-{kind}.yaml` files as `kix-manifests.sh` and `kix-dump.py` write them.
