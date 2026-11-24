+++
kind = "added"
packages = ["experimental/infisical-operator"]
library = ["kix.guardArgs"]
+++
`kix.guardArgs` takes three new arguments. `parser` says how the program reads its flags: `"gnu"` (the default, unchanged), `"go"` for Go's `flag` package, which reads `-flag` and `--flag` as the same flag, or `"paerser"` for Traefik, which also ignores letter case. `ownedFamilies` refuses a flag and every flag under it, and `defaults` lists flags the package passes unless `extraArgs` sets the same flag. `infisical-operator` now refuses its owned flags written with one dash, such as `-leader-elect=false`, which it used to pass to the operator.
