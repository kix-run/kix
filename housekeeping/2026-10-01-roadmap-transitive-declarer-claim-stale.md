# 2026-10-01 · `ROADMAP.md` · The scorecard entry still says `annotationDomainOwnership` cannot see a declarer reached through another dependency.

The "Scorecard rules" bullet ends with "Still open: `architecture.annotationDomainOwnership`
cannot see a declarer that is a dependency of a dependency". It can:
`eval/instance.nix` passes `transitiveDepTargets` as the rule's
`resolvedDepTargets`, and HANDBOOK.md documents the rule as accepting a
declarer "direct or through another dependency", with the
Ingress to cluster-issuer to cert-manager chain as its example.
