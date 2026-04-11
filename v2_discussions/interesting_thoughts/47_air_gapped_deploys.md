# Air-Gapped Deploys — Automatic Support

## Working Document — March 2026

**Status:** Exploration
**Related:** `46_thin_operator_production_plan.md` (OCI artifact transport), `29_deploy_architecture.md` (deploy pipeline)

---

## 1. The Question

Can kix automatically support air-gapped deploys — clusters with no internet access — without requiring manual image mirroring or special per-package configuration?

---

## 2. Why kix Is Unusually Well-Positioned

Most K8s tooling treats container images as opaque strings buried in YAML. kix has two structural advantages:

### 2.1 Structured Image References

Every package declares images as structured attributes:

```nix
image = {
  repository = "ghcr.io/immich-app/immich-server";
  tag = "v2.0.0";
  pullPolicy = "IfNotPresent";
};
```

These aren't strings embedded in templates — they're typed Nix values. kix can enumerate every image reference in a cluster evaluation **at eval time**, without parsing YAML or guessing.

### 2.2 Complete Dependency Graph

The Nix store DAG guarantees **closure completeness** — if a resource is in the evaluation, everything it needs is in the graph. Combined with structured images, we can guarantee: "here is every container image this cluster will ever try to pull."

### 2.3 No Runtime Fetching

kix packages don't `fetchurl` external resources. CRDs are pre-bundled. The only external dependencies at deploy time are container images and the OCI manifest artifact (from doc 46). That's a small, well-defined surface.

---

## 3. What Air-Gapped Actually Requires

An air-gapped deploy needs:

1. **Manifest transport** — get the K8s manifests into the cluster somehow
2. **Image transport** — get every container image into a registry the cluster can reach
3. **Image rewriting** — manifests must reference the internal registry, not the public one
4. **Completeness guarantee** — nothing is missing; the deploy won't fail because an init container image was forgotten

kix can already do (1) via OCI artifacts. The interesting question is (2), (3), and (4).

---

## 4. Proposed Design

### 4.1 Image Manifest Generation — `kix images`

A new CLI command that extracts all container images from an evaluated cluster:

```bash
$ kix images cluster-nw1
ghcr.io/immich-app/immich-server:v2.0.0
goharbor/harbor-core:v2.12.2
goharbor/harbor-jobservice:v2.12.2
nginx:1.27-alpine
quay.io/prometheus/alertmanager:v0.28.1
...
```

Implementation: evaluate the cluster, walk all resource manifests, extract `spec.containers[*].image`, `spec.initContainers[*].image`, and `spec.template.spec.containers[*].image` from every resource. Since we have structured image attributes in packages, we could also extract these directly from the Nix evaluation — but walking the manifests is more robust (catches images set in raw overrides too).

Output formats:
- Plain list (default) — one `registry/repo:tag` per line
- `--format skopeo` — a `skopeo sync` source YAML
- `--format json` — structured output with per-package grouping

This alone is useful even without full air-gap support — it answers "what images does my cluster need?" which is valuable for security scanning, pre-pulling, and capacity planning.

### 4.2 Image Mirroring — `kix images mirror`

```bash
$ kix images mirror cluster-nw1 --to registry.internal.corp/kix-mirror
```

This would:
1. Run `kix images` to get the full image list
2. For each image, `skopeo copy` (or equivalent) from source to `<target-registry>/kix-mirror/<original-path>:<tag>`
3. Report progress and failures

The naming scheme preserves the original path to avoid collisions:
- `nginx:1.27-alpine` → `registry.internal.corp/kix-mirror/docker.io/library/nginx:1.27-alpine`
- `ghcr.io/foo/bar:v1` → `registry.internal.corp/kix-mirror/ghcr.io/foo/bar:v1`

### 4.3 Image Rewriting — Cluster-Level Registry Override

The key insight: since images are structured Nix values, we can rewrite them at the cluster level without touching packages.

**Option A: Cluster-level overlay**

```nix
# clusters/air-gapped-prod/default.nix
{
  cluster.registryMirror = "registry.internal.corp/kix-mirror";
  # All image references are automatically rewritten:
  # "ghcr.io/foo/bar:v1" → "registry.internal.corp/kix-mirror/ghcr.io/foo/bar:v1"
}
```

This would work as a module overlay that intercepts all `image.repository` values and prepends the mirror prefix. Packages don't know or care — they declare `ghcr.io/foo/bar` and the cluster config transparently rewrites it.

**Option B: Post-eval manifest rewriting**

Instead of doing it in Nix, the CLI rewrites image references in the generated manifests before applying. Simpler to implement but less principled — the Nix evaluation wouldn't reflect what's actually deployed.

**Recommendation: Option A.** It keeps the Nix evaluation as the source of truth. The diff output shows the actual image references that will be deployed. The store hashes reflect the real content. Everything stays honest.

### 4.4 Completeness Guarantee

The combination of (4.1) and (4.3) gives us a strong completeness property:

1. `kix images` extracts **every** image from the evaluated cluster
2. `kix images mirror` copies **every** extracted image to the internal registry
3. The registry override rewrites **every** image reference to point to the mirror
4. If an image is missing from the mirror, the eval still references the mirror path — the failure is a clear "image not found in mirror" rather than a silent timeout or network error

We could go further: `kix images verify --registry registry.internal.corp/kix-mirror` checks that every image the cluster needs actually exists in the mirror registry. Run this in CI before deploying.

---

## 5. The Bundle Approach (Alternative)

Instead of a registry mirror, bundle everything into a single transportable artifact:

```bash
$ kix bundle cluster-nw1 --output cluster-nw1-bundle.tar
```

This would produce a tarball containing:
- The OCI manifest artifact (kix-packages.json, graph, manifests)
- Every container image as OCI image layers
- A loader script that pushes images to a specified registry and creates the Activation CR

Pros: Single file to transport across the air gap. No ongoing mirror sync.
Cons: Potentially huge (many GB). Doesn't help with incremental updates. Basically reinventing `docker save`.

This is a nice-to-have on top of the mirror approach, not a replacement.

---

## 6. Edge Cases and Open Questions

### 6.1 Images Not Declared in Package Config

Some images are referenced outside the structured `image` attribute:
- Operator-managed workloads (e.g., a CRD that specifies an image in its spec)
- Helm charts imported via `helm-to-kix` that embed image strings
- ConfigMaps containing image references (e.g., Argo workflow templates)

For the manifest-walking approach, we'd catch anything in standard K8s `image` fields. But images referenced in arbitrary ConfigMap data or CRD specs would be missed.

**Mitigation:** Packages can declare additional images via metadata:

```nix
meta.additionalImages = [
  "busybox:1.36"  # used by operator internally
];
```

### 6.2 Image Digests vs Tags

Air-gapped registries sometimes don't preserve digests correctly. Should kix normalize to tags, or preserve `@sha256:...` references?

Recommendation: preserve whatever the package declares. If a package uses a digest, mirror the digest. If it uses a tag, mirror the tag. Don't transform.

### 6.3 Multi-Architecture Images

`skopeo copy` handles multi-arch manifests natively. No special kix logic needed — but worth documenting that the mirror includes all architectures unless filtered.

### 6.4 Init Containers and Sidecars

These are in standard K8s fields (`initContainers`, `ephemeralContainers`) so the manifest walker catches them. Istio-style sidecar injection happens post-deploy and is outside kix's scope — the service mesh's own mirroring story applies.

### 6.5 Nix Evaluation Itself

If the Nix eval machine is also air-gapped, `nix build` needs access to flake inputs. This is a standard Nix problem (use `nix copy --to` to pre-populate the store, or use a Nix binary cache mirror). Not kix-specific, so out of scope here — but worth mentioning in docs.

---

## 7. Implementation Effort

| Component | Effort | Depends On |
|---|---|---|
| `kix images` (image list extraction) | Small | Existing eval pipeline |
| `kix images mirror` (skopeo wrapper) | Small | `kix images` |
| `kix images verify` (mirror completeness check) | Small | `kix images` |
| `cluster.registryMirror` (Nix overlay) | Medium | Module system design |
| `kix bundle` (full offline bundle) | Medium-Large | `kix images` + OCI artifact |

The first three are independently useful and low-effort. The registry overlay is the architecturally interesting piece. The bundle is a nice-to-have.

---

## 8. Why This Is Hard Elsewhere, Easy Here

| Tooling | Image Discovery | Rewriting | Completeness |
|---|---|---|---|
| Raw YAML / kustomize | Regex/AST parsing of arbitrary YAML | sed/kustomize image transformer | Hope and grep |
| Helm | `helm template` + parse output | `--set image.registry=...` per chart | Chart-specific, no standard |
| kix | Structured eval, walk manifests | Single cluster-level overlay | Guaranteed by store closure |

The structural advantage is real: kix *knows* what images a cluster uses, rather than guessing from string patterns.

---

## 9. Summary

kix can support air-gapped deploys with relatively little new machinery because:

1. **Images are structured data**, not embedded strings — enumeration is trivial
2. **The store DAG is complete** — nothing is missing from the graph
3. **Cluster-level overlays can rewrite all image references** without touching packages
4. **OCI artifacts already solve manifest transport** (doc 46)

The minimum viable path is: `kix images` (extract) + `cluster.registryMirror` (rewrite) + `kix images mirror` (transport). Everything else is convenience on top.
