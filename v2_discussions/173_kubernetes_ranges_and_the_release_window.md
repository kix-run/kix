# 173: Kubernetes ranges and the release window

**Status:** RFC / Draft
**Related:** `155_platform_versions_and_compatibility.md` (principle 4, §5.4, §5.6), `172_package_version_upkeep.md`, `172b_bump_workflow_operations.md`, `140_catalogue_versions_and_upgrade_windows.md`, `127_compiler_target_model.md` (three-valued facts)

---

## 1. Problem

On 2026-11-18 the authoring skill began telling every version bump to encode
upstream's stated Kubernetes support in `meta.k8s`. `checkMetaStatic` refuses
a cluster whose `k8sVersion` is outside that range. The same day the ranges
stopped overlapping:

| Package | Range | Upstream's statement |
|---|---|---|
| `kube-state-metrics` 2.20.0 | 1.36 only | the client-go version it builds with; the rest is "best effort" |
| `external-secrets` | 1.37 only | one Kubernetes version for each release in its support table |
| `keycloak` 26.8.2 | 1.31 to 1.34 | "OpenShift 4.18-4.21, corresponding to Kubernetes API 1.31-1.34" |
| `infisical-operator` | 1.29 to 1.33 | a supported-versions list |

A cluster with `kube-state-metrics` and `keycloak` builds on no Kubernetes
version. A cluster with only `kube-state-metrics`, which is every cluster
with monitoring, must run exactly 1.36, and must move to exactly 1.37 in the
same step as the Kix release that bumps the package. The one way out is to
unset `k8sVersion`, which turns off every version check.

Each package followed the rule correctly. The rule produces a package set
that cannot be used, so the fault is in the rule and in what Kix has not yet
decided about its releases.

## 2. Two causes

**One range holds two different facts.** Doc 155's StackGres case was a real
break: operators 1.11 to 1.16 crash on Kubernetes 1.33, and upstream's
`kubeVersion` said so. Keycloak's upper bound is a different thing. Keycloak
calls no Kubernetes API that 1.35 changes, and upstream has only not said
that it supports 1.35. Doc 155 principle 4 already has the rule for this:
unknown warns, false fails. A version outside upstream's statement is
unknown. Today's rule treats it as false.

**Nobody owns the intersection.** A Kix release ships one version of each
package. Whether those versions share a Kubernetes version is a property of
the release, and nothing checks it. The first to find out is a user whose
build fails, and that user cannot fix it.

The second cause is the larger one. Fixing only the first leaves the set
able to drift apart again through real breaks.

## 3. What other projects do

Checked on the web on 2026-11-18, except where marked as from memory.

**Language package managers: lower bounds are facts, upper bounds are
predictions.** A lower bound says "this needs a feature that arrived in X",
which the author knows. An upper bound says "this will break in a version
that does not exist yet", which the author is guessing.

- Terraform's documentation tells reusable modules to "constrain only their
  minimum allowed Terraform and provider versions", so the user of the
  module can upgrade without changing it. Root modules pin.
- Python: Henry Schreiner's essay "Should You Use Upper Bound Version
  Constraints?" answers no for libraries, because a user cannot loosen a cap
  that a library sets. The Python packaging discussion on `requires-python`
  reaches the same view: add a cap only when you know the next release
  breaks you.
- Go modules have minimum versions only (from memory).
- npm's `engines` field warns by default and refuses only with
  `engine-strict` (from memory).
- Haskell kept upper bounds (the PVP) and had to add two repair tools:
  Hackage metadata revisions, which let a maintainer or trustee loosen or
  tighten bounds on a published release, and `allow-newer` for the user.
- Composer argues the other side: cap, then raise the cap in a new release
  after testing. That works when the release with the raised cap arrives
  quickly.

**Curated sets test the set.** Stackage, nixpkgs, and Linux distributions
pick one version of each package and test them together against a base. The
user never solves constraints. A package that fails against the base is
fixed, held back, or marked broken before the set ships. nixpkgs keeps
`meta.broken` and `meta.platforms` as refusals with a named override
(`allowBroken`, `allowUnsupportedSystem`) (from memory).

**Kubernetes platforms.**

- Helm's `kubeVersion` refuses, with no override at install. Charts that set
  an upper bound produce a steady stream of reports each Kubernetes release
  (Rancher's `< 1.25.0-0` chart, an Argo CD case on 1.32), and users patch
  `Chart.yaml` by hand. Most widely used charts set a minimum only.
- OLM's ClusterServiceVersion has `minKubeVersion` and no maximum (from
  memory). OpenShift adds `olm.maxOpenShiftVersion`, and the important
  detail is what it blocks: the cluster's upgrade to the next minor, with
  the message naming the operator. It does not stop a running operator.
- EKS add-ons keep several versions of each add-on. Each version lists the
  cluster versions it works with, and one is the default for each cluster
  version. RKE2 does the same by shipping charts with each Kubernetes
  release (doc 155 §3.2). Both are sets curated for each Kubernetes minor.
- Upstream projects publish "supported" or "tested" matrices as
  information. The Kubernetes project itself defines skew for its own
  components and leaves add-ons to state theirs.

The pattern across all of these:

1. Minimums are hard and come from a known need.
2. Maximums are hard only when a break is known. Otherwise they are
   information, or they gate the next platform upgrade.
3. Whoever ships a set of packages tests the set and owns its compatibility
   with the base.
4. A refusal that rests on a guess has an override.

Kix today breaks all four. So the problem is common and has known answers.
It is intractable only in the form Kix gave itself: treating every upstream
statement as a hard fact and expecting the facts to agree.

## 4. Does Kix need a different packaging strategy?

No. One version of each package in a release is the Stackage and nixpkgs
model, and it works there. What those projects have and Kix lacks is the
promise about the base and the test that keeps it.

The alternative is the EKS model: several versions of each package, chosen
by `k8sVersion`. It gives every cluster a version upstream supports. It
also multiplies the vendored CRDs, roles, tests, and bumps by the number of
Kubernetes minors, when doc 172a already counts about 94 updates a month.
It should stay available as something one package does when it has no
other way (`stackgres-operator` already picks its kubectl image from
`k8sVersion`), and should not become the model.

## 5. Proposal

### 5.1 A release states its Kubernetes window

Each Kix release names the Kubernetes minors it supports, as data in the
library. A reasonable default is the minors the Kubernetes project
maintains on the release date, three at a time. Today that is 1.34 to 1.36.

A cluster whose `k8sVersion` is outside the window gets a warning that
names the window. Packages' hard ranges still decide refusal.

### 5.2 `meta.k8s` separates what fails from what upstream states

```nix
meta.k8s = {
  # Refuses. Each bound needs evidence of a failure.
  minVersion = "1.30";
  reason = "[K....] the validatingadmissionpolicies collector reads admissionregistration.k8s.io/v1, served from 1.30";

  # Warns. Upstream's statement, with its source.
  supported = { minVersion = "1.36"; maxVersion = "1.36"; };
};
```

Evidence for a hard bound is an API version the operand reads or the
package emits that the Kubernetes version does not serve, a startup check in
the operand's source, an upstream issue, or a failed test. "Upstream lists
only these versions" goes in `supported`.

A warning for a version outside `supported` says what is known: "keycloak
26.8.2: upstream states support for Kubernetes 1.31 to 1.34, and this
cluster targets 1.36." A scorecard rule can raise it to an error for a
cluster that needs vendor support for everything it runs. That keeps the
strict reading available as a choice.

### 5.3 CI checks the set against the window

A test fails when a stable package's hard range does not cover the release
window. The bump that narrows a range is the one that fails, in the pull
request that makes it, where someone can act:

- make the package work across the window (kube-state-metrics leaves the
  two MutatingAdmissionPolicy collectors out of `--resources` below 1.36),
- hold the bump, or
- narrow the window in the same pull request, with an `error` change
  record, as a visible decision about the release.

Experimental packages get the same check as a warning in CI, since they may
break in any release.

The smoke-test cluster runs on kind at both ends of the window. This is the
evidence behind the window, and it is the part that costs CI time.

### 5.4 The compiler checks emitted API versions

Kix holds every manifest at build time. With a vendored list of the group
versions and kinds each Kubernetes minor serves, the build can refuse an
object whose `apiVersion` the target does not serve, and name the package.
Pluto and kubent do this after the fact for removals. This needs no work
from package authors and replaces most hand-written bounds for the manifest
half. Doc 155 open question 9 already lists it. Hand-written hard bounds
remain for what an operand does at run time, which manifests do not show.

### 5.5 The ceiling gates the Kubernetes upgrade

Doc 155 §5.6 already proposes the lookahead: warn when `k8sVersion` is the
newest version a package's hard range accepts. That is OLM's
`maxOpenShiftVersion` idea, and it is where an upper bound does its real
work. No change here; this doc only confirms it.

## 6. What this changes for the cases in §1

| Package | Hard range | Supported (warns outside) |
|---|---|---|
| `kube-state-metrics` 2.20.0 | 1.30 and later, with the two collectors conditional below 1.36 | 1.36 |
| `keycloak` 26.8.2 | none known | 1.31 to 1.34 |
| `external-secrets` | to be established from its API use | 1.37 |
| `stackgres-operator` | upstream's range, since doc 155 shows it is a real break | same |

A cluster on 1.36 with monitoring and Keycloak builds, with one warning.

## 7. Alternatives considered

- **Keep one range and add an acceptance on the instance.** Smaller. Every
  cluster with monitoring would carry an acceptance and edit it at each
  bump, and the set could still drift apart unnoticed.
- **Patch the two packages.** Leaves both causes in place.
- **Drop upper bounds entirely.** Loses the StackGres case, which is the
  reason `meta.k8s` exists.
- **A catalogue for each Kubernetes minor.** See §4.

## 8. Costs and risks

- Every range written on 2026-11-18 needs sorting into hard and supported.
  About 30 packages. An agent can do it from the comments the bumps left,
  which name each source.
- Hard bounds need evidence, which is more work for each bump than copying
  a table. When the evidence is missing the bound is absent, and a real
  break can pass. The kind runs at both ends of the window and §5.4 are
  what catch it.
- Warnings that never go away get ignored. A cluster on 1.35 would carry a
  kube-state-metrics warning until it upgrades.
- The window check can hold a bump for a long time when upstream needs the
  newest Kubernetes.

## 9. Open questions

1. **The window's size and source.** The minors Kubernetes maintains (three),
   or wider to include what managed providers still run under extended
   support?
2. **How warnings outside `supported` are shown.** One summary line in
   `kix check` with detail on request, or one line for each package?
3. **Does `supported` gate anything by default**, or only through the
   scorecard rule?
4. **Experimental packages and the window.** Warn in CI, or check nothing?
5. **Where the hard range may depend on `config`.** kube-state-metrics needs
   `k8sVersion` in `build` to choose its collectors. The housekeeping entry
   on `otel-collector` asks the related question for ranges that apply only
   when an option is on.
6. **The served-API data for §5.4.** Vendor it from the Kubernetes OpenAPI
   for each minor, or from the API removal schedule only?
7. **Order of work before 0.10.0.** §5.2 with the reclassification unblocks
   users. §5.1 and §5.3 stop it from recurring. §5.4 can follow.
