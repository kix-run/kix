# 71: k9s Plugin — Kix-Aware Cluster Browsing

**Status:** Draft
**Related:** `29_compiler-design.md` (annotation model), `68_live_cluster_compatibility.md`

## Problem

When browsing a live cluster in k9s, every resource is a flat list of YAML. There's no visibility into kix concepts — which package owns a resource, what its dependencies are, or what would break if you deleted it. You have to mentally map between k9s and `kix graph` / `kix list` output.

kix already stamps rich metadata onto every deployed resource (`kix.dev/*` annotations, `app.kubernetes.io/managed-by=kix` label). This data is sitting right there on the cluster — but k9s doesn't surface it.

## Proposal

A set of k9s plugins (YAML-defined keyboard shortcuts) that read kix annotations from live resources via `kubectl` and surface package/DAG context directly in the k9s terminal. **Pure kubectl + jq — no nix, no kix CLI, no result dir required.**

### Plugin set

#### 1. Package Context (`Shift-P`)

*"What package owns this resource?"*

Reads `kix.dev/package` and `kix.dev/package-namespace` annotations from the selected resource. Displays package name, namespace, and identity hash.

```yaml
plugin:
  kix-package:
    shortCut: Shift-P
    description: "Show kix package info"
    scopes:
      - all
    command: kubectl
    args:
      - get
      - $RESOURCE_NAME
      - $NAME
      - -n
      - $NAMESPACE
      - -o
      - "jsonpath=Package: {.metadata.annotations.kix\\.dev/package}\nNamespace: {.metadata.annotations.kix\\.dev/package-namespace}\nIdentity: {.metadata.annotations.kix\\.dev/identity-hash}\nDepends-on: {.metadata.annotations.kix\\.dev/depends-on}\n"
```

#### 2. Package Siblings (`Shift-S`)

*"Show all resources in the same package."*

Reads the `kix.dev/package` annotation from the selected resource, then lists all resources cluster-wide with that same annotation value. Uses the `app.kubernetes.io/managed-by=kix` label selector to scope the scan to kix-managed resources only.

```bash
#!/usr/bin/env bash
# kix-siblings.sh
set -euo pipefail
PKG=$(kubectl get "$1" "$2" -n "$3" -o jsonpath='{.metadata.annotations.kix\.dev/package}')
NS=$(kubectl get "$1" "$2" -n "$3" -o jsonpath='{.metadata.annotations.kix\.dev/package-namespace}')

echo "=== Package: $PKG (ns: $NS) ==="
echo ""

# List all kix-managed resources in the package namespace, filter by package annotation
kubectl get all,configmap,secret,serviceaccount,role,rolebinding,networkpolicy,pvc \
  -n "$NS" \
  -l "app.kubernetes.io/managed-by=kix" \
  -o json | \
  jq -r --arg pkg "$PKG" \
    '.items[] | select(.metadata.annotations["kix.dev/package"] == $pkg) |
     "\(.kind)/\(.metadata.name)"' | sort
```

#### 3. DAG Neighbors (`Shift-D`)

*"What does this depend on, and what depends on it?"*

Reads `kix.dev/depends-on` (comma-separated identity hashes) from the selected resource, then resolves those hashes to human-readable `Kind/name` by scanning all kix-managed resources for matching `kix.dev/identity-hash` annotations. Also finds reverse dependencies (resources whose `depends-on` contains this resource's identity hash).

```bash
#!/usr/bin/env bash
# kix-dag.sh — show direct dependencies and dependents
set -euo pipefail

HASH=$(kubectl get "$1" "$2" -n "$3" -o jsonpath='{.metadata.annotations.kix\.dev/identity-hash}')
DEPS=$(kubectl get "$1" "$2" -n "$3" -o jsonpath='{.metadata.annotations.kix\.dev/depends-on}')

# Build a lookup table: identity-hash → Kind/namespace/name for all kix resources
# Uses the managed-by label to scope the scan
LOOKUP=$(kubectl get all,configmap,secret,serviceaccount,role,rolebinding,clusterrole,clusterrolebinding,networkpolicy,pvc,crd \
  -A -l "app.kubernetes.io/managed-by=kix" -o json | \
  jq -r '.items[] |
    {hash: .metadata.annotations["kix.dev/identity-hash"],
     id: "\(.kind)/\(.metadata.namespace // "cluster")/\(.metadata.name)",
     deps: (.metadata.annotations["kix.dev/depends-on"] // "")} |
    @json')

echo "=== $1/$2 (ns: $3) ==="
echo "Identity: $HASH"
echo ""

# Forward deps: resolve hashes from depends-on
echo "--- Depends on ---"
if [ -n "$DEPS" ]; then
  for dep_hash in $(echo "$DEPS" | tr ',' '\n' | sed 's/^.*://'); do
    echo "$LOOKUP" | jq -r --arg h "$dep_hash" \
      'fromjson | select(.hash == $h) | "  → \(.id)"'
  done
else
  echo "  (none)"
fi

echo ""

# Reverse deps: find resources whose depends-on contains our hash
echo "--- Depended on by ---"
echo "$LOOKUP" | jq -r --arg h "$HASH" \
  'fromjson | select(.deps | split(",") | map(ltrimstr("requires:") | ltrimstr("extra:")) | any(. == $h)) | "  ← \(.id)"' \
  || echo "  (none)"
```

#### 4. Blast Radius (`Shift-B`)

*"If this resource disappears, what transitively breaks?"*

Same scan as DAG neighbors but walks the dependent chain recursively. Outputs a tree of all transitive dependents.

Implementation: a small script that iteratively collects dependents by hash until no new ones are found. Same `app.kubernetes.io/managed-by=kix` label-scoped scan, but with a BFS loop.

#### 5. Drift Detection (future — `Shift-H`)

*"Has this resource drifted from what kix deployed?"*

The `kix.dev/identity-hash` is a content hash of the intended state. A plugin could normalize the live resource (strip server-managed fields), hash it, and compare. This gives a boolean "drifted yes/no" without needing the nix store. A full diff would require the intended manifests (seeded mode).

Deferred — noted here as a natural extension.

## Design Decisions

### Self-contained (no kix CLI dependency)

The plugins use only `kubectl` and `jq`. This means:
- Works on any machine with cluster access (CI boxes, colleague laptops, jump hosts)
- No nix store or result dir needed
- Fast — no evaluation step
- Trade-off: can only surface information that's stamped as annotations/labels on live resources

### Label-scoped scanning

All resource scans use `-l app.kubernetes.io/managed-by=kix"` to avoid listing non-kix resources. This is already the label kix uses for `fetch_managed_resources()` in the CLI.

### Annotation-based DAG resolution

The `kix.dev/depends-on` annotation contains identity hashes, not names. Resolving hashes to names requires a cluster-wide scan of kix resources. This is O(n) in the number of kix resources but only runs on explicit user action (key press), so latency is acceptable for clusters up to a few hundred resources. For very large clusters, results could be cached in a temp file per session.

## Packaging

The plugins ship as:
1. A `plugins.yaml` file users can drop into `$XDG_CONFIG_HOME/k9s/plugins/kix.yaml`
2. A few helper scripts (`kix-siblings.sh`, `kix-dag.sh`, `kix-blast.sh`) that live in the kixpkgs repo and can be installed via nix (or just copied to PATH)
3. Simple plugins (package context) are inline `kubectl` calls — no script needed

Could also be a nix package (`packages/k9s-kix-plugins`) that symlinks everything into place.

## Open Questions

- **Resource type coverage**: The `kubectl get all,...` lists are incomplete — custom resources (CRDs managed by kix) won't appear unless explicitly listed. Could use the kube API discovery to dynamically list all types with the kix label, but that's slower. Pragmatic: start with common types, expand as needed.
- **Cluster-scoped resources**: ClusterRoles, ClusterRoleBindings, CRDs don't have a namespace. The scripts handle this (`namespace // "cluster"`) but the k9s `$NAMESPACE` variable will be empty for these — need to handle gracefully.
- **Key bindings**: `Shift-P/S/D/B` are proposals. Need to verify they don't conflict with built-in k9s bindings.
- **Performance**: For clusters with 500+ kix resources, the full scan for DAG resolution might take a few seconds. Worth measuring. Could pre-build an index file on deploy.
