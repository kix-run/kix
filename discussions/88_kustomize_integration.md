# 88: Kustomize Integration — `importKustomization` as a Build-Time Resource Import

**Status:** Design Doc
**Related:** `87_helm_integration_v2.md`, `86_helm_dag_reconstruction.md`, `29_compiler-design.md`

---

## Context

Doc 87 redesigns Helm integration around `importChart` — a build-time helper
that runs `helm template` via IFD and returns a structured resource collection.
The package author gets full control: `resources.get`, `mkParts`, DAG linking,
compile-time validation. The cluster definition shrinks to
`package = packages.foo; config.values = { ... };`.

Kustomize is the other major K8s configuration tool. Many upstream projects
ship kustomize bases (ArgoCD, Flux, Cert-Manager's alternative install,
Knative, Crossplane, Tekton). Users overlay environment-specific patches on
top. The question: can kix import kustomize outputs with the same compiler
guarantees as Helm, and what's the right API?

---

## How Kustomize Works (for context)

Kustomize is a **pure build-time tool**. There is no runtime component, no
operator, no server-side logic. `kustomize build <dir>` reads a
`kustomization.yaml` and produces final YAML. Everything is resolved at build
time.

### Core concepts

| Concept | What it does | Runtime? |
|---------|-------------|----------|
| **Bases** | Reference other kustomization directories (local or remote git URLs). Composable — bases can reference bases. | No — resolved at build time |
| **Overlays** | A kustomization that references a base and layers patches/transformers on top. The standard env separation pattern (`base/`, `overlays/dev/`, `overlays/prod/`). | No |
| **Resources** | Raw YAML files listed in `kustomization.yaml`. Just file references. | No |
| **Patches** | Strategic merge patches or JSON patches applied to base resources. Can target by kind/name/group. | No |
| **Generators** | `configMapGenerator` and `secretGenerator` create ConfigMaps/Secrets from files or literals. Appends content hashes to names for rolling updates. | No |
| **Transformers** | `namePrefix`, `nameSuffix`, `commonLabels`, `commonAnnotations`, `namespace`, `images`, `replicas`. Bulk mutations applied to all resources. | No |
| **Replacements** | (Formerly `vars`.) Cross-resource field substitution — e.g., inject a Service's name into a ConfigMap's data field. Resolved at build time by reading the source field and writing the target field. | No |
| **Components** | Reusable kustomization fragments that can be included by multiple overlays. Like mixins. | No |
| **Remote bases** | Git URLs with ref pinning: `github.com/org/repo//path?ref=v1.0.0`. Kustomize clones at build time. | No |
| **Helm inflation** | Kustomize can render Helm charts as a generator (`helmCharts` field). The rendered output becomes resources that patches/transformers act on. | No |

### Key insight: everything is build-time

Unlike Helm (which historically had Tiller and still has `helm install` as a
deploy-time operation), kustomize has **zero runtime semantics**. It's a YAML
preprocessor. This means:

1. **Every kustomize feature can be captured at compile time.** There is nothing
   that "has to stay at runtime." The entire kustomize pipeline is a pure
   function: `kustomization.yaml + inputs → YAML output`.

2. **Kustomize's parameterization model (overlays) is structurally different
   from Helm's (values).** Helm has a single `values.yaml` that consumers
   override. Kustomize uses overlay directories with patches. There's no
   `kustomize build --set foo=bar` equivalent.

3. **Kustomize doesn't have a package registry.** Charts come from Helm repos
   or OCI registries. Kustomize bases come from git URLs or local paths. The
   fetching story is different.

---

## Design

### The fundamental bet

Kustomize is simpler than Helm for kix integration because:
- No values merging (kustomize doesn't have it)
- No release name / namespace injection (kustomize handles namespace via transformer)
- No CRD toggle (kustomize includes whatever the base lists)
- No hooks (kustomize has no lifecycle concept)

The hard part is **source management** — fetching remote kustomize bases with
proper pinning and hashing.

### New primitives

#### `fetchKustomization` — fetch a remote kustomize base

```nix
# Fixed-output derivation: clone a git repo subtree at a pinned ref.
fetchKustomization = {
  url,         # Git URL: "https://github.com/argoproj/argo-cd"
  path ? ".",  # Subdirectory within repo: "manifests/cluster-install"
  ref,         # Git ref: "v2.13.3" (tag), "abc1234" (commit), "main" (branch)
  hash,        # Nix SRI hash for reproducibility
}: <derivation>;
```

This is a fixed-output derivation (like `fetchHelmChart`). It clones the repo
at the given ref, extracts the subdirectory, and produces a store path
containing the kustomization directory. The hash ensures reproducibility —
same pattern as `fetchFromGitHub` in nixpkgs.

For local kustomization directories (in-repo or on disk), no fetcher is needed —
just pass the path directly.

**Why not use `fetchFromGitHub`?** We could, and for simple cases it works.
But kustomize bases often reference *other* remote bases via relative paths
within the same repo. `fetchKustomization` preserves the repo structure so
`kustomize build` can resolve relative references. If the kustomization is
self-contained (no parent-relative refs), `fetchFromGitHub` works fine as
a drop-in.

#### `importKustomization` — build-time resource import

```nix
importKustomization = {
  src,              # Path to kustomization dir (from fetchKustomization or local)
  scope,            # The package's scope (for mkResource/mkClusterResource)

  # ── Optional overrides ──────────────────────────────────────
  # These correspond to kustomize CLI flags and kustomize edit commands.
  # They're applied AFTER kustomize build, as kix-level patches, not
  # by modifying the kustomization.yaml.
  namespace ? null,         # Override namespace (kustomize --namespace)
  namePrefix ? null,        # Prepend to all resource names
  nameSuffix ? null,        # Append to all resource names
  commonLabels ? {},        # Merge into all resources' labels
  commonAnnotations ? {},   # Merge into all resources' annotations
  images ? [],              # Image overrides: [{ name, newName?, newTag?, digest? }]

  # ── Patch escape hatch ──────────────────────────────────────
  # Applied to the raw JSON resources after kustomize build, before wrapping.
  # Same role as helm.importChart's patchResources.
  patchResources ? lib.id,

  # ── Stripping ───────────────────────────────────────────────
  # Kustomize doesn't inject as much metadata as Helm, but some bases
  # add labels like app.kubernetes.io/managed-by: kustomize.
  strip ? {
    kustomizeLabels ? true;   # Strip managed-by: kustomize
    defaultStrategy ? true;   # Strip default RollingUpdate (same as helm)
  },
}:
<resource-collection>;
```

Returns the **exact same `resource-collection` type** as `helm.importChart`
(doc 87). Same `get`, `find`, `byKind`, `workloads`, `mkParts`, `depsOf`,
`edges`, `diagnostics` API. Packages built on kustomize and packages built on
Helm produce identical collection objects — the downstream code doesn't know
or care which tool generated the resources.

#### Implementation: IFD pipeline

```
kustomization directory (from fetchKustomization or local path)
    ↓
kustomize build (Nix derivation, runs kustomize CLI)
    ↓
Multi-document YAML output
    ↓
yq conversion to JSON array (same as helm pipeline)
    ↓
builtins.readFile + builtins.fromJSON (IFD step)
    ↓
Raw JSON resources
    ↓
patchResources (user hook)
    ↓
wrapResource (shared with helm — same wrapHelmResource, renamed)
    ↓
DAG linking pass (shared with helm — doc 86)
    ↓
resource-collection
```

The wrapping and DAG linking stages are **shared code** between Helm and
kustomize. `wrapHelmResource` gets renamed to `wrapImportedResource` (or
stays internal — the name doesn't matter to consumers). The DAG linking pass
from doc 86 works identically: it operates on wrapped resources regardless
of how they were generated.

The `kustomizeBuildDerivation` is straightforward:

```nix
kustomizeBuildDerivation = { src, ... }:
  pkgs.runCommand "kustomize-build" {
    nativeBuildInputs = [ pkgs.kustomize pkgs.yq-go ];
  } ''
    kustomize build "${src}" \
      | yq eval-all -o=json '[.]' \
      > $out
  '';
```

### What a kustomize package looks like

**ArgoCD — upstream kustomize base:**

```nix
# kix/packages/argocd/default.nix
{ scope, lib }:
let
  src = scope.kustomize.fetchKustomization {
    url = "https://github.com/argoproj/argo-cd";
    path = "manifests/cluster-install";
    ref = "v2.13.3";
    hash = "sha256-abc123...";
  };
in
{
  meta = {
    version = "2.13.3";
    provides = [ "gitops" "cd" ];
  };

  options = {
    images = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.str);
      default = [];
      description = "Image overrides passed to kustomize.";
    };
  };

  build = { self, config, clusterConfig }:
    let
      resources = scope.kustomize.importKustomization {
        inherit src scope;
        images = config.images;
      };
    in
    resources.mkParts {
      root = resources.get "Deployment" "argocd-server";
      out = {
        # Expose the ArgoCD server service for ingress wiring
        serverService = resources.get "Service" "argocd-server";
      };
    };
}
```

**Tekton Pipelines — simple import:**

```nix
# kix/packages/tekton-pipelines/default.nix
{ scope, lib }:
let
  src = scope.kustomize.fetchKustomization {
    url = "https://github.com/tektoncd/pipeline";
    path = "config";
    ref = "v0.60.0";
    hash = "sha256-def456...";
  };
in
{
  meta.version = "0.60.0";

  build = { self, config, clusterConfig }:
    let
      resources = scope.kustomize.importKustomization {
        inherit src scope;
      };
    in
    resources.mkParts {
      root = resources.get "Deployment" "tekton-pipelines-controller";
    };
}
```

**Local kustomization — in-repo manifests:**

```nix
# kix/packages/my-app/default.nix
{ scope, lib }:
{
  meta.version = "1.0.0";

  build = { self, config, clusterConfig }:
    let
      resources = scope.kustomize.importKustomization {
        src = ./manifests;  # local directory with kustomization.yaml
        inherit scope;
      };
    in
    resources.mkParts {
      root = resources.get "Deployment" "my-app";
    };
}
```

### Three tiers (mirroring Helm)

#### Tier 1: Inline kustomization — zero package

```nix
instances.argocd.argocd = {
  package = kix.kustomization {
    url = "https://github.com/argoproj/argo-cd";
    path = "manifests/cluster-install";
    ref = "v2.13.3";
    hash = "sha256-abc123...";
  };
};
```

`kix.kustomization` is the convenience wrapper (like `kix.helmChart`):
- Calls `fetchKustomization` + `importKustomization` internally
- Uses `mkParts` with auto-root
- Returns a package function with an `images` option
- No DI, no custom root, no `meta.provides`

#### Tier 2: Package with `importKustomization` — full control

Real package file, `resources.get`, custom `out`, CRD refs. The ArgoCD
example above.

#### Tier 3: Native package — no kustomize

Hand-wired resources. For when the kustomize base is more trouble than
it's worth.

### Kustomize overlays vs. kix options

This is the key design decision. Kustomize's parameterization model is
**overlays** — directories of patches layered on a base. Kix's
parameterization model is **options** — typed config values merged at the
cluster level.

**The position: kix options replace kustomize overlays.**

When a kustomize base is imported into kix, the overlay concept is
unnecessary. The package author doesn't ship `overlays/dev/` and
`overlays/prod/` — they expose kix options:

```nix
options = {
  replicas = lib.mkOption { type = lib.types.int; default = 1; };
  images = lib.mkOption { ... };
  enableHA = lib.mkOption { type = lib.types.bool; default = false; };
};
```

The cluster definition sets these options. The `build` function uses them
to choose which kustomize base to import (e.g., `cluster-install` vs
`ha/install`) or to apply post-build patches.

This is a natural fit because:
1. kix options are typed and validated at eval time — kustomize patches are
   not (a bad patch silently produces wrong YAML)
2. kix options compose through DI — kustomize overlays are directory-level,
   no cross-package composition
3. The cluster operator doesn't need to understand kustomize's overlay model —
   they just set config values

**For users who already have overlays:** The package can import a specific
overlay directory directly:

```nix
build = { config, ... }:
  let
    baseDir = if config.enableHA
      then "${src}/ha/install"
      else "${src}/cluster-install";
    resources = scope.kustomize.importKustomization {
      src = baseDir;
      inherit scope;
    };
  in ...;
```

The overlay is selected by kix config, not by kustomize's overlay mechanism.
Kustomize still resolves the base references internally — kix just points
at the right top-level directory.

### What about kustomize components?

Kustomize components are reusable fragments that can be included by multiple
overlays. In kix, this maps to either:

1. **Shared Nix functions** — if the component is reusable logic, make it a
   Nix function that multiple packages call
2. **kix dependency injection** — if the component provides a capability
   (e.g., "add mTLS sidecars"), it should be a kix package that consumers
   depend on

We don't need to model kustomize components in the kix API. They're an
internal detail of how the upstream project organizes its kustomization
directories. `kustomize build` resolves them.

### What about replacements (vars)?

Kustomize replacements are cross-resource field substitutions resolved at
build time. Example: inject a Service's clusterIP into a ConfigMap.

`kustomize build` resolves all replacements before producing output. kix
sees the final values, not the replacement directives. This is transparent —
no special handling needed.

### What about generators (configMapGenerator, secretGenerator)?

Generators create ConfigMaps and Secrets from files or literals, appending
content hashes to names for rollout triggering.

`kustomize build` runs generators and produces the final resources with
hashed names. kix sees regular ConfigMap/Secret resources. The name-hashing
behavior is preserved because we import the final output.

One consideration: kustomize's name-hashing means resource names change when
content changes. The kix content-addressing (identityHash) already handles
this — a changed ConfigMap gets a new identityHash, triggering a re-deploy
of resources that reference it. There's no conflict, but there is redundancy:
both kustomize and kix hash content. This is harmless.

### What about `kustomize build --enable-helm`?

Kustomize can render Helm charts via the `helmCharts` field. If someone's
kustomization uses this, `kustomize build --enable-helm` produces the
rendered output. We should support this:

```nix
kustomizeBuildDerivation = { src, enableHelm ? false, ... }:
  pkgs.runCommand "kustomize-build" {
    nativeBuildInputs = [
      pkgs.kustomize
      pkgs.yq-go
    ] ++ lib.optional enableHelm pkgs.kubernetes-helm;
  } ''
    kustomize build "${src}" \
      ${lib.optionalString enableHelm "--enable-helm"} \
      | yq eval-all -o=json '[.]' \
      > $out
  '';
```

Surface this as an option:

```nix
importKustomization = {
  # ...
  enableHelm ? false,  # Allow kustomize to render inline helm charts
};
```

---

## Kustomize vs. Helm: What's Different for kix

| Aspect | Helm | Kustomize | Impact on kix |
|--------|------|-----------|--------------|
| **Source** | OCI/HTTP chart registry | Git URL or local path | Different fetcher (`fetchKustomization` vs `fetchHelmChart`) |
| **Parameterization** | `values.yaml` deep merge | Overlays (directory-level patches) | kix options replace overlays; no `config.values` equivalent needed |
| **Output** | `helm template` → YAML | `kustomize build` → YAML | Same downstream pipeline (JSON parse → wrap → DAG link) |
| **Metadata injection** | Heavy (helm.sh/*, checksums, managed-by) | Light (managed-by: kustomize, sometimes build annotations) | Simpler stripping |
| **CRDs** | `--include-crds` flag | CRDs listed as resources (always included) | No toggle needed |
| **Hooks** | Helm hooks (pre/post-install, test) | None | No hook filtering needed |
| **Namespace** | `--namespace` flag | `namespace` transformer | Handled by scope |
| **Runtime component** | None (post-v2) | None | Both are pure build-time — identical for kix |

---

## What We Get for Free

Because `importKustomization` produces the same `resource-collection` as
`importChart`, everything from doc 86 and 87 applies automatically:

1. **DAG linking** — Service→Workload, RBAC→SA, volume→ConfigMap edges
2. **Compile-time validation** — orphan selectors, unmatched PDBs, missing refs
3. **Deploy ordering** — SAs before Deployments, ConfigMaps before workloads
4. **`mkParts` convenience** — compose the parts tree with one call
5. **`get`/`find`/`byKind` accessors** — explicit resource selection, loud failures
6. **Structured diagnostics** — warnings surfaced in `kix diff` and CLI
7. **Network policy generation** — doc 37's DI-derived CNPs work on kustomize packages

A kustomize-imported package is indistinguishable from a Helm-imported package
in the kix plan. The deploy engine, the operator, the diff tool — none of
them know or care about the source.

---

## Alternatives Considered

### A. Don't integrate kustomize — tell users to pre-render

Users run `kustomize build > manifests.yaml` and import via `mkImport` or
raw `mkResource` calls.

**Rejected because:** This loses the source pinning (`fetchKustomization` with
hash), makes version bumps manual, and doesn't compose with kix options.
It's the "copy-paste YAML" approach that kix exists to replace.

### B. Deep kustomize parsing — model overlays/patches in Nix

Parse `kustomization.yaml` in Nix, represent overlays as Nix attrsets,
implement strategic merge patch in Nix. This would let kix understand
the *structure* of kustomize configurations, not just the output.

**Rejected because:** Massive complexity for marginal benefit. Strategic merge
patch alone is ~500 lines of Go with OpenAPI schema awareness. Reimplementing
it in Nix is fragile and would constantly lag upstream. The output of
`kustomize build` already has all the information we need — the structure
is an implementation detail.

### C. Kustomize operator — runtime rendering

Run kustomize at deploy time (like Flux's kustomize-controller).

**Rejected because:** This contradicts kix's core thesis — compile-time
guarantees. Runtime rendering means no DAG linking, no compile-time
validation, no content-addressed store paths. If users want runtime
kustomize, they should use Flux directly.

### D. Model kustomize overlays as kix variants

Each overlay becomes a package variant: `packages.argocd.ha`,
`packages.argocd.standard`. The variant selects which overlay to
`kustomize build`.

**Considered but deferred.** This is a valid pattern for packages with
well-defined deployment modes (HA vs single-replica, with-ingress vs
without). But it's a package-level design choice, not something the
integration API needs to enforce. Package authors can do this with plain
Nix:

```nix
# argocd package with variant support
{ scope, lib }:
let
  mkVariant = overlayPath: { ... build using that overlay ... };
in
{
  standard = mkVariant "manifests/cluster-install";
  ha = mkVariant "manifests/ha/install";
}
```

This is just Nix — no special kustomize variant machinery needed.

---

## Migration / Compatibility

No breaking changes. `importKustomization` is a new primitive alongside
`importChart`. The shared infrastructure (resource wrapping, DAG linking)
is refactored to be source-agnostic, but the Helm API doesn't change.

### Shared code extraction

The wrapping and DAG linking code currently in `helm.nix` should be
extracted into a shared module (e.g., `kix/lib/import.nix` or
`kix/lib/resource-collection.nix`). Both `importChart` and
`importKustomization` call into this shared code:

```
helm.nix:     helmTemplateDerivation → JSON → shared.buildCollection
kustomize.nix: kustomizeBuildDerivation → JSON → shared.buildCollection

shared (import.nix):
  buildCollection: JSON resources → wrap → link → resource-collection
```

This avoids duplicating the wrapping, stripping, DAG linking, and
`mkParts` logic.

---

## Open Questions

### 1. Remote base resolution and network access

`kustomize build` on a directory that references remote bases
(`github.com/org/repo//path?ref=v1`) needs network access during the
Nix derivation. This is a problem: Nix derivations are sandboxed.

Options:
- **(a) Pre-fetch all remote bases.** `fetchKustomization` fetches the
  entire repo, so relative remote refs within the same repo work. But
  cross-repo refs (base A references base B in a different repo) still
  fail. We could provide a `fetchKustomizationWithDeps` that resolves
  and pre-fetches all transitive remote bases.
- **(b) Use `--load-restrictor none` with a pre-populated directory.**
  Fetch all referenced repos into a known directory structure, then run
  `kustomize build` with `--load-restrictor LoadRestrictionsNone` so it
  reads from the pre-fetched tree.
- **(c) Require self-contained kustomizations.** Only support
  kustomizations whose bases are either local (within the fetched repo)
  or inlined. Document this limitation. Users with cross-repo refs
  pre-render with `kustomize build` outside Nix and import the output.

Leaning toward **(a)** for the common case (most kustomize bases reference
paths within the same repo) with **(c)** as the documented fallback for
complex multi-repo setups.

### 2. Kustomize version pinning

Different kustomize versions can produce different output (especially
around strategic merge patch behavior and new features like replacements).
Should `importKustomization` let the package author pin the kustomize
version?

```nix
importKustomization = {
  # ...
  kustomizeVersion ? null,  # Pin kustomize version (default: pkgs.kustomize)
};
```

Leaning toward: use `pkgs.kustomize` (whatever the flake pins) by default.
Package authors who need a specific version can override `pkgs.kustomize`
in their flake inputs. This matches how Helm version pinning works (we
use whatever `pkgs.kubernetes-helm` provides).

### 3. Secrets in kustomize

`secretGenerator` creates Secrets from files or literals at build time.
The generated Secret contains the actual secret data in the kustomize
output. This is the same problem as Helm's Secret values — the secret
data ends up in the Nix store (world-readable).

This is a known issue for Helm too (doc 76-78 cover secrets). The same
solution applies: `mkSecretRef` for external secrets, SOPS for encrypted
secrets. Kustomize doesn't make this better or worse.

### 4. Strategic merge patch awareness for `patchResources`

`patchResources` operates on raw JSON after `kustomize build`. This is
plain JSON patching. If users want strategic merge patch semantics (merge
lists by key, not replace), they need kustomize to handle that — which
it already does, since patches are applied during `kustomize build`.

The `patchResources` escape hatch is for kix-level post-processing
(stripping fields, injecting annotations). It doesn't need strategic
merge semantics.

### 5. Should `importKustomization` support inline patches?

Helm has `values` for parameterization. Kustomize uses patches. Should
kix allow inline patches in `importKustomization`?

```nix
# Hypothetical — NOT proposed
importKustomization = {
  # ...
  patches ? [];  # Strategic merge patches applied after build
};
```

**Leaning no.** This reimplements kustomize inside kix. If users need
patches, they should either:
1. Write a kustomization overlay that applies the patches, and import that
2. Use `patchResources` for simple JSON-level mutations
3. Use kix options in the package for structured parameterization

The whole point of importing into kix is to use kix's composition model,
not to replicate kustomize's.

### 6. Interaction with `kix artifact push` / OCI transport

Both Helm charts and kustomize bases need to be fetchable in air-gapped
environments (doc 47). Helm charts are already OCI artifacts. Kustomize
bases are git repos — no standard OCI packaging.

For air-gapped kustomize, the options are:
- Bundle the fetched kustomization directory into the activation OCI artifact
- Require pre-rendering: `kustomize build` runs during `nix build`, the
  rendered output is what gets shipped (this is already what happens — IFD
  runs at build time)

The second option is free — `kustomize build` already runs at Nix eval
time. The rendered resources are in the Nix store, which is what gets
packaged into the OCI artifact. No special kustomize handling needed for
air-gapped.

---

## Implementation Plan

### Phase 0: Extract shared wrapping/linking code

Pull resource wrapping, DAG linking, and `resource-collection` construction
out of `helm.nix` into `kix/lib/import.nix`. `helm.nix` calls into
`import.nix`. Verify identical output for all existing Helm packages.

### Phase 1: `fetchKustomization` + `kustomizeBuildDerivation`

Implement the fetcher and build derivation. Test with a simple local
kustomization directory (add to `tests/`). Verify JSON output matches
`kustomize build | yq`.

### Phase 2: `importKustomization`

Wire `kustomizeBuildDerivation` → shared `buildCollection`. Verify the
resource collection has the same API as `importChart` output. Test with
a real upstream base (ArgoCD's `manifests/cluster-install`).

### Phase 3: First package migration

Migrate one package that's currently either raw YAML or Helm-wrapped but
whose upstream provides a kustomize base. ArgoCD or Tekton are good
candidates. Verify `kix diff` shows clean output.

### Phase 4: `kix.kustomization` convenience (Tier 1)

Implement the inline convenience wrapper for cluster definitions. Same
pattern as `kix.helmChart`.
