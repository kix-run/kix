# Cluster Diff Tools

Compare Kix-generated manifests against a live Kubernetes cluster.

## Quick Start

```bash
# 1. Build Kix manifests into ./result (works for all clusters, including Helm charts)
./scripts/kix-manifests.sh . nw1 ./result

# 2. Dump the live cluster (matching only what Kix declares)
./scripts/kix-dump.py --match-kix ./result --context nw1-prod cluster-dump/

# 3. Compare
./scripts/kix-diff.py ./result cluster-dump/
```

Or use the devenv shortcut:

```bash
kix-check nw1 nw1-prod
```

## kix-manifests.sh and cluster-checks.sh

Because Helm chart fetching and rendering (`fetchHelmChart` and `importChart`) are fulfilled by Kix rather than plain `nix build`, clusters that use Helm cannot be built directly with `nix build .#cluster-<name>`.

- `scripts/kix-manifests.sh <flake-dir> <cluster> <out-link>` evaluates the cluster through `kix build -o json` and writes the standard `<namespace>/<name>-<kind>.yaml` directory tree using `kix.mkManifests`.
- `scripts/cluster-checks.sh <flake-dir> <cluster> [<rules-test.yaml>]` builds the manifest directory with `kix-manifests.sh` and runs both `kixChecks.schemaCheck` (`kubeconform`) and `kixChecks.rulesCheck` (`promtool`) against it.
- `scripts/sign-release.sh <dist-dir>` signs a release's `SHA256SUMS` with the key in `KIX_RELEASE_SIGNING_KEY`, for the release job and the release rehearsal in `.github/workflows/cli-tests.yml` (`cli/kix/release-keys/README.md`).

## vendor-crds.py

Refreshes the CRDs every package vendors under `kix/packages/stable/<pkg>/crds/`
from the public URLs in that directory's `sources.txt` (one per line, with
optional CRD names to take from a bundle). `--check` fails on drift and runs
in CI on every pull request that touches a package. A package whose upstream
is not a public URL ships `crds/update.py` instead, exposing
`crds() -> list[dict]` against `scripts/vendor_crds/`. The maintainer is the
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

## kix-diff.py

Compares a Kix output directory against a cluster dump and produces a structured markdown report on stdout. Progress goes to stderr.

```bash
# View in terminal
./scripts/kix-diff.py ./result cluster-dump/

# Copy to clipboard for LLM
./scripts/kix-diff.py ./result cluster-dump/ | pbcopy

# Save to file
./scripts/kix-diff.py ./result cluster-dump/ > drift-report.md

# Ignore specific JSON paths
./scripts/kix-diff.py ./result cluster-dump/ --ignore-path '*.annotations'
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

Both scripts auto-detect the directory layout (flat `{ns}--{name}-{kind}.yaml` from nix build, or nested `{ns}/{name}-{kind}.yaml` from dump).
