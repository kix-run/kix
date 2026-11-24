# 2026-11-24 · `kix/lib/vocab/cloud-identity.nix` · The refusals of `use` and `useIdentity` do not say which dependency holds the bad value.

The two functions receive the dependency's value, not its name, so their errors set no `dependency` field and say "this instance passes" or "this dependency". On a package with two credentials dependencies (one per ServiceAccount), the reader must guess which one is meant. A package can work around it by wrapping the call, but none does. Passing the name to the functions, or having the scope report the dependency, would fix every caller at once.
