# 2026-09-18 · `clusters/`, `ludo/` · The scorecard is off by default and no cluster in `clusters/` enables it.

Only ludo turns it on, and only for the architecture rules. A package can
rot for months without any build noticing: harbor carried 15
`distinctSameKindLabels` errors and an empty database password until
`clusters/test-harbor.nix` ran it under `kix.rules` in full.
