+++
kind = "added"
packages = ["experimental/infisical-operator"]
library = ["kix.guardArgs"]
+++
If an `infisical-operator` instance passes a single-dash form of a package-managed flag in `extraArgs` (such as `-leader-elect=false`), remove that flag; `infisical-operator` now rejects single-dash spellings instead of passing them to the operator. Other cluster definitions and existing `kix.guardArgs` calls need no changes. `kix.guardArgs` now defaults `owned` to `{ }` and adds three optional arguments: `parser`, `ownedFamilies`, and `defaults`. `parser` selects how the target program parses flags: `"gnu"` (the default), `"go"` for Go's `flag` package (`-flag` and `--flag` match the same flag), or `"paerser"` for Traefik (like `"go"`, ignoring letter case). `ownedFamilies` rejects both a flag and any `<flag>.<name>` sub-flags, and `defaults` provides default flags that `kix.guardArgs` omits when the user's arguments set the same flag.
