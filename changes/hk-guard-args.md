+++
kind = "added"
library = ["kix.guardArgs"]
+++
`kix.guardArgs` accepts four new optional arguments for package authors: `parser`, `ownedFamilies`, `defaults`, and `id`. Set `parser` to `"go"` for programs that use Go's `flag` package (treating `-flag` and `--flag` as the same flag), `"paerser"` for Traefik (matching like `"go"` and ignoring letter case), or keep the default `"gnu"`. Use `ownedFamilies` to reject both a flag and any `<flag>.<name>` sub-flags, `defaults` to pass default flags that are omitted when overridden, and `id` to attach a change record ID (such as `"K4740"`) to rejected-flag errors.
