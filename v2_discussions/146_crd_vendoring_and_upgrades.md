# 146: CRD vendoring and upgrades

**Status:** Design Doc / Accepted (§5.1 to §5.4 shipped 2026-09-19; §5.5, §5.6 and the §6 migrations open)
**Related:** `archive/50_operator_crd_upgrades.md` (ordering, settled), `archive/21_crd-discussion.md` (`mkCRD` / `mkCRDRef` / `mkCR`), `140_catalogue_versions_and_upgrade_windows.md` (when a cluster moves), `55_shared_resource_ownership.md` (CRD ownership across activations)

---

## 1. Problem

Every operator package carries CRDs, and every upstream project changes them:
new kinds, new served versions, dropped versions, tightened schemas. Kix
applies CRDs before the controllers that need them (doc 50 covers why the
ordering half is solved), but the repository has no process for the content
half. Nothing says how a CRD gets into a package, nothing refreshes it when
the pinned version moves, and nothing checks that the two agree.

PR #118 vendored full CRD bundles for velero, arc, infisical-operator and
openebs because their controllers refuse to start without them. That made the
question concrete: four more packages now carry upstream JSON that will go
stale at the next bump.

## 2. Where CRDs come from today

Four routes, found by reading the packages on 2026-09-19.

| Route | Packages | Refreshable? | Validates specs? |
|---|---|---|---|
| Vendored upstream object, read at eval | velero, arc, infisical-operator, openebs (`<pkg>/crds/*.json`); one file each in cert-manager, kubevirt, cdi | By hand. Provenance is a comment | Yes |
| Hand-written stub via `scope.crd.fromKind` | cert-manager, prometheus-operator, kubevirt, cdi, most victoria-metrics-operator kinds | Never stale, carries no schema | No: `preserve-unknown-fields` |
| Rendered from the pinned Helm chart (`importChart`, `importChartCrds`) | kube-prometheus-stack, cilium (helm) | Bump chart version and hash | Yes |
| Operator installs its own; Kix ships a `mkCRDRef` marker and waits | stackgres (`INSTALL_CRDS`), cilium, velero's optional upgrade-crds Job | Not Kix's | Not Kix's |

One package has a repeatable process. `scripts/vendor-vm-crd-schemas.py`
reads the operator tag from the package, fetches the upstream bundle, writes
sorted JSON, and fails `--check` on drift. ROADMAP already records that
nothing runs the check automatically.

The stub route has a structural limit: `fromKind` models one served version,
`withVersion` renames it, and `withSchema` stamps one schema onto every
version. It cannot express what upstream actually ships.

## 3. What deploy does with a CRD

The mechanics that matter for an upgrade, from `cli/kix/src/cluster/`:

- Server-side apply with field manager `kix`. The CRD `spec.versions` list is
  atomic, so two managers that disagree on it conflict, and
  `--force-conflicts` is the only way through.
- A CRD barrier: dependents of a CRD wait for `Established=True` and one
  discovery refresh that started after it (`scheduler.rs`).
- Readiness is `Established=True` only (`readiness.rs::check_crd_ready`).
- Prune has no special case for CRDs. A CRD that leaves the closure is an
  orphan like any other, and deleting a CRD deletes every CR of that kind
  cluster-wide.
- `mkCRD` gives the CR builders the first listed version
  (`kix/lib/scope/builders.nix`, `builtins.head crdSpec.versions`).

Two of these have already bitten. cdi-operator rewrites its own CRD to drop
`v1alpha1`, so every redeploy after the first conflicted on `spec.versions`
until the package filtered that version out. And the kubevirt package still
declares stubs for VirtualMachine and its siblings that virt-operator also
creates; only the KubeVirt CRD reaches the closure today, so the first
consumer CR would drag a stub into the same fight.

## 4. Multiple versions per CRD

This is the shape of upstream data, not a feature to add. In the vendored
files today:

| CRD | Versions |
|---|---|
| `kubevirts.kubevirt.io` | v1 (storage), v1alpha3 |
| `cdis.cdi.kubevirt.io` | v1beta1 (storage), v1alpha1 (filtered out, see §3) |
| `volumesnapshots.snapshot.storage.k8s.io` | v1 (storage), v1beta1 (not served) |

Vendoring whole objects carries this for free. What follows from it is
small: the builders must pick the storage version, and the deploy must refuse
to drop a version the apiserver still lists in `status.storedVersions`, since
that apply is rejected and the cluster needs a storage-version migration
first. Consumers writing CRs at a non-storage version is rare and gets an
override, nothing more.

## 4a. Optional components and their CRDs

The openebs package nulls a driver's CRDs when that driver is off: a cluster
that runs only LVM registers the three `local.openebs.io` kinds and nothing
from `zfs.openebs.io`. That gate arrived with PR #118, so it was worth
checking against upstream rather than taking it as a decision.

It matches. The openebs umbrella chart conditions each driver's subchart on
`engines.local.<driver>.enabled`, so a disabled driver renders no CRDs at
all; each driver chart also carries `crds.<driver>.enabled` plus `keep`, and
`crds.csi.volumeSnapshots.enabled`, because the snapshot group is shared and
the umbrella installs it once from its own `openebs-crds` subchart. The
wider ecosystem gates at the package level, not the component level:
cert-manager and kube-prometheus-stack have one `crds.enabled` switch for
ownership (someone else may install them) and `keep` so a Helm uninstall
does not cascade-delete every CR; arc uses Helm's `crds/` directory, which
Helm installs once and never touches again; velero has an upgrade hook Job.

So the rule is: a CRD is gated by the enable option of the controller that
reconciles it, which is what a subchart condition is. A shared cluster-wide
group gets an ownership toggle (`snapshotCrds` in openebs). No lib support;
the gate is a one-line `if` in the package.

## 5. Design

### 5.1 One rule for choosing a route

1. **The operator installs and rewrites its own CRDs** (stackgres, cilium,
   virt-operator for the kubevirt.io kinds): ship `mkCRDRef` markers only.
   Never a competing copy.
2. **Otherwise the package vendors the full upstream objects.** This is the
   default for every operator package.
3. **Stubs via `fromKind` are for kinds Kix invents** (`packageinstances`,
   `activations`). A stub for an upstream kind is a defect.

Each package says which case applies in the comment above its `crds` block,
with the upstream path the files came from.

### 5.2 Vendored layout

```
kix/packages/<pkg>/crds/
  sources.txt                       # public URLs the files come from
  <metadata.name>.json              # one upstream object per CRD
```

Each JSON file is the whole upstream document, keys sorted, two-space
indent, so a refresh diff reads as what moved upstream. The package loads
them with the pattern PR #118 uses:

```nix
vendored = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
crds.backups = scope.mkCRD { spec = vendored "backups.velero.io.json"; };
```

`sources.txt` is a text file of public URLs, one per line, `#` comments
allowed. A URL may be a single CRD or a whole bundle; the script keeps every
CustomResourceDefinition document it finds and ignores the rest, so an
operator's release manifest is a valid source. A bundle URL may be followed
by the names of the CRDs to take from it:

```
# velero v1.15.2, the server image tag in default.nix
https://raw.githubusercontent.com/vmware-tanzu/velero/v1.15.2/config/crd/v1/bases/velero.io_backups.yaml
https://raw.githubusercontent.com/vmware-tanzu/velero/v1.15.2/config/crd/v2alpha1/bases/velero.io_datauploads.yaml

# cert-manager release asset, only the Certificate schema for now
https://github.com/cert-manager/cert-manager/releases/download/v1.17.1/cert-manager.crds.yaml certificates.cert-manager.io
```

A package can draw from several upstreams at several versions in one file
(openebs carries lvm, zfs and the snapshot CRDs from three projects).
Trimming (the cdi `v1alpha1` filter) stays in the package's Nix, where the
reason sits next to the code, not in the vendoring.

The tag in a URL is the pin. Nothing mechanical ties it to the package's
image pin; the skill's bump procedure moves both in one change and the
kind smoke catches a controller that disagrees with its CRDs. An earlier
draft had a `sources.nix` with a tag the script cross-checked against the
package; it was dropped for a file anyone can read and edit without
evaluating anything.

### 5.3 The script

`scripts/vendor-crds.py` is the driver and `scripts/vendor_crds/` the
shared module (fetch with retry, YAML to sorted JSON, the conversion-webhook
refusal, `sources.txt` parsing). The driver discovers every
`kix/packages/*/crds/` that has a `sources.txt` or an `update.py`, runs the
packages through a thread pool (eight by default; a full refresh of the
catalogue takes about fifteen seconds), writes or, with `--check`, compares
and exits non-zero. A committed `.json` no source produces is reported as an
orphan and removed on a write. It runs without Claude, in CI, on every pull
request that touches a package (`.github/workflows/crd-check.yml`, with the
unit tests in `scripts/vendor_crds/test_vendor_crds.py`). That is the only
drift detector, so it has to stay deterministic and dumb.

The escape hatch: a package whose upstream is not a public URL (an OCI-only
chart, CRDs generated at build time) ships `crds/update.py` exposing
`crds() -> list[dict]`, built on the shared module, with a comment saying
why the URL list did not fit. The driver calls it in place of the data
path. No package needs it today.

Constraints, checked by the skill's review step (§5.4):

- No package or project name in the script. Anything project-specific lives
  in that package's `sources.txt`, or failing that its `update.py`.
- No network outside the one fetch function. No writes outside `crds/` and
  `rbac/`.
- Driver and module together under roughly 300 lines (274 at landing).
  Past that, the special case belongs in a package or the design is wrong.

### 5.4 The skill

`.claude/skills/crd-vendoring/SKILL.md` is the maintainer. It runs at three
moments: a new package that carries CRDs, a version bump, and a red `--check`
in CI. It owns the judgement the script cannot make:

1. Pick the route (§5.1) and write the comment.
2. Find where this upstream keeps its CRDs (chart `crds/`, kubebuilder
   `config/crd/bases/`, a release bundle) and write `sources.txt`.
3. Run the script. Read the refresh diff for: a version that vanished, a
   storage version that moved, a conversion webhook that appeared, a new
   kind that needs a line in the package's RBAC tables.
4. Run the package's kind smoke (`scripts/kind-operators.sh` for the
   operator set).
5. When the script itself failed: fix `sources.txt` first. Change the script
   only for a failure in fetch, parse or render, and re-check the §5.3
   constraints afterwards. A package that truly cannot use a URL gets
   `update.py`; the review lists every package on that path and asks
   whether it could return to data.

Step 5 is the part that keeps the script small over years. The failures
that arrive with upstream releases are layout moves, and those are data.
The skill is `.claude/skills/crd-vendoring/SKILL.md`.

### 5.5 Lib

- `mkCRD` gives the builders the version with `storage = true`, falling back
  to the first served one. `mkCR` accepts `version` for a consumer that
  needs an older API on purpose.
- `fromKind` stays single-version. Its doc comment says it is for kinds Kix
  invents.

### 5.6 CLI

Two guards, both surfaced in `kix diff` so the reviewer sees them before
anything runs:

- **Prune never deletes a CRD unless asked.** Orphaned CRDs are listed and
  skipped; `--prune-crds` deletes them. This is the one prune that cascades
  to user data.
- **A CRD apply must not drop a stored version.** Before applying, compare
  the new `spec.versions` with the live `status.storedVersions`. A version
  present live and absent in the manifest fails the deploy with the version
  named and the migration path stated. `--allow-crd-version-removal`
  overrides for the case where the migration was done out of band.

Readiness stays `Established=True`.

### 5.7 The bump procedure

One pull request moves the tag in `sources.txt` and the package's image pin,
reruns the script, and carries the CRD diff. The kind smoke is the test.
When a cluster takes the bump is doc 140's question; a CRD bundle is part of
the package revision like any other file, so pin coherence covers it.

## 6. Migration of what exists

| Package | Today | Move to |
|---|---|---|
| velero, arc, infisical-operator, openebs | vendored by hand (PR #118) | `sources.txt` added; the refresh reproduced every file byte for byte except a reformat of the three snapshot CRDs, which confirms the hand-vendored provenance (done) |
| victoria-metrics-operator | table plus `vendor-vm-crd-schemas.py` | `sources.txt` with the overlay bundle and the eight consumer names, old script deleted, files moved to `crds/` (done); `kinds.nix` stays for the indexer invariant |
| cert-manager | one vendored file (moved to `crds/`, `sources.txt` names it in the release asset), five stubs | all six vendored from the v1.21.2 release asset (done) |
| prometheus-operator | stubs with provenance annotations | all ten vendored from the release's stripped-down-crds.yaml, ClusterRole from the release's examples (done) |
| cdi | one vendored file (moved to `crds/`, from the operator bundle), filtered, plus stubs | keep the filter; vendor the rest or turn them into markers, whichever cdi-operator's behaviour dictates |
| kubevirt | one vendored file (moved to `crds/`, from the operator bundle) plus stubs virt-operator also creates | markers for every kubevirt.io kind except KubeVirt |

## 7. Alternatives considered

- **Fetch CRDs at eval time** with `fetchurl`. Rejected: the schema would not
  be in the diff, and the eval would need the network. The whole point is
  that a bump is a reviewable file change.
- **Generate CRD schemas from Go types or OpenAPI.** Rejected for now: it
  reintroduces a toolchain per upstream language for no gain over the
  published objects.
- **Keep stubs and accept no validation.** Rejected: the VictoriaMetrics work
  showed a mistyped `extraSpec` field reaching the operator instead of
  failing at apply.
- **Make the script clever** (per-project fetchers). Rejected: this is what
  the cleanup review exists to prevent.

## 8. Decided on 2026-09-19

- **Conversion webhooks.** Refused until designed. The script fails on a
  CRD whose `spec.conversion.strategy` is `Webhook`, so one cannot land
  unnoticed. `None` is accepted; it is what controller-gen emits. When the
  first package needs one, the Service it names has to be created under the
  package's own naming; decide then whether the package patches
  `clientConfig` in Nix or the lib offers a helper.
- **Trimming to enabled components.** A package decision, matching upstream
  (§4a). No lib support.
- **CI.** Its own workflow, `.github/workflows/crd-check.yml`, on pull
  requests touching packages or the script. It needs only Python with
  PyYAML from the locked project environment, so it runs on a GitHub-hosted
  runner rather than the Nix-provisioned Spindle machines.
- **Script shape.** Driver plus shared module, data by default, `update.py`
  as a documented exception, packages in parallel (§5.3).

## 9. Still open

- `mkCRD` on the storage version and the `mkCR` version override (§5.5).
- The two deploy guards (§5.6).
- The §6 migrations for cert-manager, prometheus-operator, cdi and kubevirt.
