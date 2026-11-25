# 2026-11-25 · `kix/lib/scope/builders.nix` · `scope.mkCRD` ignores arguments it does not know.

`mkCRD` reads each argument with `attrs.<name> or <default>`, so a misspelt
`controler`, `crRequire`, or `holdData` builds without a word and drops the
setting. A misspelt `controller` silently loses the delete order and the
controller line of a stuck delete. `scope.mkCRDRef` takes named arguments
and refuses an unknown one, so the two declarations behave differently.
