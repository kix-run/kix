# 51 — Merkle-walk health check & enriched depends-on

## Problem

`kix health` currently requires a full `nix build` to produce the intended StoreGraph, then fetches every kix-managed resource from the cluster and compares Blake3 content hashes. This is slow and heavyweight — it rebuilds the world just to answer "is what I deployed still intact?"

Meanwhile, all the information needed to verify deployment integrity is *already on the cluster* in the form of `kix.dev/*` annotations. The identity-hash DAG is a Merkle tree: if the root hash matches and every child hash matches, the whole tree is sound.

## Two distinct health questions

1. **Integrity** (fast): "Is the dependency tree intact? Are all expected resources present with the correct identity hashes?" — answers "is the cluster running what we deployed?"
2. **Drift** (deep): "Has someone `kubectl edit`'d a resource?" — answers "has anything been mutated in place?" This requires content-hash comparison (the current approach).

These are different checks with different costs. Integrity is a graph walk with targeted GETs. Drift requires normalizing and hashing every resource body.

## Change 1: enrich `kix.dev/depends-on` with resource hints

### Current format

```
kix.dev/depends-on: "abc123,def456"
```

Bare identity-hashes. To resolve these, you need the full StoreGraph (hash → resource) or must LIST all managed resources and index by hash.

### New format

```
kix.dev/depends-on: "abc123:Namespace/_cluster/cert-manager,def456:CustomResourceDefinition/_cluster/certificates.cert-manager.io"
```

Pattern: `{identity-hash}:{kind}/{namespace}/{name}`

The `kind/namespace/name` triple is the same `ResourceId` used everywhere in kix. This lets the health check do a targeted GET (O(1) per dependency) instead of a full LIST + index. The `:hints` part is optional for backwards compatibility — a bare hash (no `:`) falls back to lookup-by-hash.

### Touched code

- `stamp.rs`: when writing `kix.dev/depends-on`, look up the ResourceId for each dep hash and append `:kind/ns/name`
- `graph.rs`: parse the enriched format. Split on `,`, then split on `:` — first part is hash, rest is hint. Hints are used for efficient fetching but hash remains the source of truth for edge resolution.

### Annotation size

A typical depends-on entry is ~80 chars (`abc123:CustomResourceDefinition/_cluster/certificates.cert-manager.io`). Even with 50 dependencies that's 4KB — well within the 256KB annotation limit.

## Change 2: Merkle-walk health check

### New flow (no nix build)

```
connect to cluster
  → find Active Activation CR
  → read its kix.dev/identity-hash
  → LIST resources where kix.dev/activations contains this hash
  → build map: identity-hash → live resource
  → for each resource:
      verify kix.dev/identity-hash annotation is present
      parse kix.dev/depends-on
      for each dependency hint:
        verify the target resource exists in our map
        verify its identity-hash matches the expected hash
  → report: intact / missing / hash-mismatch
```

### Two modes

- **`kix health <cluster>`** (default, fast): integrity check only. Walks the Merkle tree on the cluster. No nix build. Reports missing resources and hash mismatches.
- **`kix health <cluster> --deep`**: also runs the current content-hash drift detection. This *does* require a nix build (to get the intended manifests for comparison) or could compare against the resource body stored... somewhere. The deep check catches `kubectl edit` mutations.

### Edge cases

- **Activation CR missing**: first deploy hasn't happened yet. Report "no activation found" and exit.
- **Resource missing from cluster but in depends-on**: report as missing. The hint tells you exactly what's gone.
- **Hash mismatch**: resource exists but its identity-hash annotation differs from what depends-on expects. Something re-applied it outside of kix.
- **Dangling depends-on**: a dependency hash that doesn't resolve to any resource in the activation set. Could be a cross-activation reference or a bug.
- **Old-format depends-on (no hints)**: fall back to hash-only lookup against the activation resource set. Works, just can't do targeted GETs.

## Future: deep drift without nix build

The deep content-hash check currently requires a `nix build` to get the intended manifests. A future optimization could store the intended content-hash as another annotation (`kix.dev/content-hash`) at apply time. Then even deep drift detection becomes cluster-only: fetch resource, normalize, hash, compare against stored hash.

## Relation to existing roadmap items

- "Content-hash-based drift detection" — the `--deep` mode is this
- "Observability — enrich the graph with runtime health" — integrity check is the first step toward this
- "Open question: how does [the operator] handle hashes and drift?" — the Merkle walk is the answer; the operator runs the same integrity check in its reconcile loop
