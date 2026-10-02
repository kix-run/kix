# 2026-10-01 · `kix/lib/meta.nix` · An instance cannot opt out of its package's default aliases.

An instance's `aliases` replace the package's `defaultAliases` only when the
list is non-empty; `aliases = [ ]` falls back to the defaults
(`instanceAliases != [ ]` in `meta.nix`). An instance that should answer no
alias has to carry an invented one that nothing reads. A staging ClusterIssuer
sets `aliases = [ "stagingClusterIssuer" ]` so that only the production issuer
answers `clusterIssuer` (`clusters/test-doc-how-tos.nix`, region
`stagingClusterIssuer`), and the user-facing guide has to explain the
workaround.
