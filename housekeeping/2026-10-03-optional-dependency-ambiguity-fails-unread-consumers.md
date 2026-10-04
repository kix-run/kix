# 2026-10-03 · `kix/lib/eval/resolve.nix` · An optional dependency that two instances answer fails the consumer even when the consumer never reads it.

`resolveArg` decides whether an optional argument (`x ? null`) is present by
resolving it, and throws "matches instances in multiple namespaces" when two
candidates answer. Evaluation hits that throw when the build function is
called, before the package can look at a toggle. So a package cannot keep a
dependency optional behind its own option: with `defaultAliases =
[ "oidcProvider" ]` on keycloak, two Keycloak instances failed every grafana,
harbor, and immich in the cluster, OIDC on or off. keycloak answers no alias
for this reason, and clusters wire `deps.oidcProvider = ref.<ns>.<instance>`
by hand. The same holds for any optional alias two instances can answer
(`tempo`, `loki`). Test: `oidc-grafana-two-providers` in
`kix/lib/tests/units/oidc.nix`.
