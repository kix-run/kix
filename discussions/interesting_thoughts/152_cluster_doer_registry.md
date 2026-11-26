# 152: A cluster registry of doers

## Status

Idea (2026-09-28). No near-term driver.

## The idea

`kix.untrackedRef { kind; name; by; }` names the resource that creates an
object Kix does not render. Kix checks `by` against a denylist of built-in
kinds that create nothing a manifest names (`core/markers.nix` `passiveKinds`) and
accepts every other kind, because an unknown custom resource may be
reconciled by an operator that creates objects.

A registry of doers would turn that around. A doer is a kind whose
controller creates or reconciles other objects: Job, Deployment,
StatefulSet, and the custom kinds an operator reconciles (`SGCluster`,
cert-manager's `Certificate`). A package that ships CRDs would declare,
next to its `mkCRD` entries, which of its kinds are doers and, optionally,
which kinds they create. The cluster would collect those declarations the
way it collects CRDs.

With the registry, `by` could require a known doer, and could check that
the doer creates the named kind: `by = self.certificate` for a Secret
passes, and `by = self.certificate` for a ConfigMap fails at eval. Unknown
kinds would warn instead of passing silently.

## Open questions

- Where the declaration lives: on `mkCRD`, beside `factBehavior`, or in
  package `meta`.
- Whether "creates kind X" is worth modelling, or whether "is a doer" is
  enough.
- How a CRD reference (`mkCRDRef`) to a CRD installed outside Kix declares
  its doers.
