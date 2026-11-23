---
name: crd-vendoring
description: Maintain the CRDs and operator roles that Kix packages vendor from upstream. Use this skill when adding a package that ships CustomResourceDefinitions, bumping an operator's version, when the CRD vendoring check fails in CI, or when scripts/vendor-crds.py itself breaks. Owns the judgement the script cannot make and keeps the script small.
---

# CRD vendoring

The rules live in `v2_discussions/146_crd_vendoring_and_upgrades.md`. Read
§5 before changing anything. Short form:

- A package whose operator installs and rewrites its own CRDs (stackgres,
  cilium, virt-operator for the kubevirt.io kinds) ships `scope.mkCRDRef`
  markers only, each with the `version` the operator's CRD serves
  (required). Never a competing copy.
- Every other operator package vendors the full upstream objects under
  `kix/packages/stable/<pkg>/crds/`, one `<metadata.name>.json` per CRD, from the
  public URLs in `crds/sources.txt`. An experimental package keeps them
  under `kix/packages/experimental/<pkg>/crds/` and `rbac/`. The script reads
  both folders, and a package name given to it selects the package of that
  name at either level.
- `scope.crd.fromKind` stubs are for kinds Kix invents. A stub for an
  upstream kind is a defect; the migration table in doc 146 §6 lists the
  ones that remain.
- An operator whose upstream bundle ships its RBAC vendors those roles
  under `kix/packages/stable/<pkg>/rbac/`, one `<kind>-<name>.json` per ClusterRole
  or Role (`:` in a name becomes `_`), from `rbac/sources.txt`. Every URL
  there names the roles to take as `Kind/name`; other kinds are refused,
  because the package builds its own ServiceAccount and bindings. The
  package feeds each file's `rules` to `scope.rbac.mkClusterRoleSet` or
  `mkRoleSet` (kubevirt, cdi).

The script is `scripts/vendor-crds.py`, run as
`uv run scripts/vendor-crds.py [pkg ...] [--check]` (in a plain shell:
`nix shell nixpkgs#uv -c uv run --frozen scripts/vendor-crds.py`). It is
deliberately dumb: fetch, keep the CustomResourceDefinition documents (or,
under `rbac/`, the named roles), sort, write. CI runs `--check` on every pull request that touches a package.

## 1. A new package that ships CRDs

1. Decide the route above and say which one in the comment on the package's
   `crds` block, with the upstream path.
2. Find where the upstream keeps its CRDs. In order of likelihood: the Helm
   chart's `crds/` directory; a kubebuilder `config/crd/bases/` directory; a
   release asset such as `<name>.crds.yaml` or the operator bundle
   (`kubevirt-operator.yaml` carries its CRD among Deployments; the script
   ignores the other kinds). Pin the tag to the same version the package
   pins for the image.
3. Write `crds/sources.txt`: one URL per line, `#` comments allowed. A
   bundle URL may be followed by the CRD names to take from it. Say in a
   comment which option in `default.nix` the tag follows.
4. Run the script for that package. Load the files in Nix with the pattern
   the velero package uses:
   ```nix
   crdFile = file: (builtins.fromJSON (builtins.readFile ./crds/${file})).spec;
   crds.backups = scope.mkCRD { spec = crdFile "backups.velero.io.json"; holdsData = false; };
   ```
   Give the CRDs to the controller's `requires`. A CRD in a `*.k8s.io` group
   needs its `api-approved.kubernetes.io` annotation carried over (see
   snapshot-controller) or the apiserver refuses it.
5. If a CRD only matters while an optional component runs, gate it on that
   component's `enabled` option. Upstream umbrella charts condition each
   driver's subchart the same way. Put a shared cluster-wide API group
   (`snapshot.storage.k8s.io`, `gateway.networking.k8s.io`) in its own
   package (`snapshot-controller`, `gateway-api`) that claims a role in
   `kix/lib/eval/roles.nix` (`snapshotController`, `gatewayApi`). Environments
   that pre-install the group provide that role with
   `kix.mkImport { roles = [ ... ]; crds = [ ... ]; }`. Controllers that serve
   the group take the role as a dependency and build custom resources from its
   `out.crds`. Do not vendor a second copy of those CRDs in a controller
   package, even when upstream's install bundle includes them (as Envoy
   Gateway's `install.yaml` does).
6. Add the new kinds to the package's RBAC tables, or, for a package with
   `rbac/sources.txt`, take the operator's roles from the same bundle. Run the package's kind
   smoke (`scripts/kind-operators.sh` for the operator set).

## 2. A version bump

1. Move the tag in `crds/sources.txt` (and `rbac/sources.txt`), `release`,
   and the image digests in `default.nix` in the same change. Operator
   packages refuse an `image.tag` of another major.minor than `release`
   (`kix.image.checkRelease`),
   and for kubevirt and cdi the kix-lib test
   `kubevirt-cdi-sources-match-release` fails when a sources.txt URL is not
   at `release`, so a half-done bump fails the checks. Operand image
   digests are per-release (`crane digest <ref>`).
2. Run the script for the package and read the diff before committing:
   - A **version that vanished** from `spec.versions`: a live cluster that
     still stores objects at that version rejects the apply. Say so in the
     pull request and name the migration. Until the CLI guard in doc 146
     §5.6 exists, this is the reviewer's job.
   - A **storage version that moved**: `mkCRD` builders follow the first
     listed version today (doc 146 §5.5). Check the CR builders still
     stamp the version the operator serves.
   - A **conversion webhook** that appeared: the script refuses it. Doc 146
     §8 says why; design the Service naming before vendoring.
   - **New kinds and rules**: add kinds to RBAC (a vendored `rbac/` changes
     with the bundle; read its diff like the CRDs') and, when a consumer
     will write them, to the package's `out.crds.<Kind>`.
3. Run the kind smoke.

## 3. The check fails in CI

`STALE` means the committed file differs from what the URL serves. Either
someone bumped the image without rerunning the script (run it, commit), or
upstream rewrote a tagged file in place (rare; read the diff, then commit
the refresh with a note). `ORPHAN` means a committed file has no source:
delete it or add its URL. `ERROR` names a URL that no longer resolves:
fix `sources.txt` first, see §4.

## 4. The script itself broke

Fix `sources.txt` before touching the script. The failures that arrive with
upstream releases are layout moves (a chart moved its `crds/`, a project
switched to release assets), and those are data.

Change the script only for a failure in fetch, parse, or render. A package
whose upstream is genuinely not a public URL (an OCI-only chart, CRDs
generated at build time) gets `crds/update.py` exposing
`crds() -> list[dict]`, built on `scripts/vendor_crds/`, with a comment
saying why the URL list did not fit. Do not add that case to the driver.

After any change to `scripts/vendor-crds.py` or `scripts/vendor_crds/`:

- run the unit tests (`uv run python -m unittest vendor_crds.test_vendor_crds`
  from `scripts/`) and `--check` across every package;
- confirm the constraints from doc 146 §5.3 still hold: no package or
  project name in the script, no network outside `fetch`, no writes outside
  `crds/` and `rbac/`, driver and module together under roughly 300 lines;
- list every package on the `update.py` path and ask whether it could
  return to `sources.txt`.

If a constraint no longer holds, the change belongs in a package's data,
not in the script. Say so in the pull request rather than shipping the
exception.
