+++
kind = "added"
library = ["kix.guardArgs"]
+++
`kix.guardArgs` takes four new arguments. `parser` says how the program reads its flags: `"gnu"` (the default, unchanged), `"go"` for Go's `flag` package, which reads `-flag` and `--flag` as the same flag, or `"paerser"` for Traefik, which also ignores letter case. `ownedFamilies` refuses a flag and every flag under it, `defaults` lists flags the package passes unless `extraArgs` sets the same flag, and `id` adds a change record id to each refusal.
