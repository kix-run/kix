# Cluster Diff Tools

Compare kix-generated manifests against a live Kubernetes cluster.

## Quick Start

```bash
# 1. Build kix manifests
nix build .#cluster-nw1 --extra-experimental-features pipe-operators

# 2. Dump the live cluster (matching only what kix declares)
./scripts/kix-dump.py --match-kix ./result --context nw1-prod cluster-dump/

# 3. Compare
./scripts/kix-diff.py ./result cluster-dump/
```

Or use the devenv shortcut:

```bash
kix-check nw1 nw1-prod
```

## kix-dump.py

Dumps live cluster resources into a directory of normalized YAML files, organized by namespace.

```
cluster-dump/
  _cluster/          # cluster-scoped resources
  kube-system/
  monitoring-system/
  ...
  README.md          # dump metadata, command used, skipped resources
```

**Modes:**

| Flag | What it fetches |
|------|----------------|
| `--match-kix <dir>` | Exactly the resources that exist in a kix output directory |
| `--managed` | All resources with `app.kubernetes.io/managed-by=kix` label |
| `--namespaces ns1,ns2` | All resources in the given namespaces |
| `--all` | Everything across all namespaces + cluster-scoped |

`--match-kix` is the tightest comparison. `--all` is useful for discovery.

**Normalization:** Server-side fields (uid, resourceVersion, managedFields, status, etc.) are stripped. Secret data is stripped — only metadata and type are kept.

**Skipped resource types:** Ephemeral/runtime resources (pods, replicasets, events, jobs, endpoints, etc.) are excluded from broad dumps. See the generated `README.md` in the dump directory for the full list.

## kix-diff.py

Compares a kix output directory against a cluster dump and produces a structured markdown report on stdout. Progress goes to stderr.

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

- **Summary** — counts of identical, modified, kix-only, cluster-only resources
- **Probable renames / moves** — resources that likely exist under a different name, with structural diffs. Uses mutual best-match + structural similarity filtering to avoid false positives.
- **kix-only** — resources kix declares but the cluster doesn't have
- **Cluster-only** — resources in the cluster that kix doesn't declare
- **Modified** — resources that exist in both but differ, with JSON-path diffs
- **Identical** — resources that match exactly (collapsed)

**Diff format:** Differences are shown by JSON path, not as unified diffs:

```
  ~ $.spec.replicas:
      kix:     1
      cluster: 3
  + $.spec.strategy.type: 'RollingUpdate'    (cluster only)
  - $.spec.template.spec.nodeSelector: ...   (kix only)
```

Both scripts auto-detect the directory layout (flat `{ns}--{name}-{kind}.yaml` from nix build, or nested `{ns}/{name}-{kind}.yaml` from dump).
