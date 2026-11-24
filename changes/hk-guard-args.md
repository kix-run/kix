+++
kind = "added"
library = ["kix.mergeArgs"]
+++
`kix.mergeArgs`, which replaces `kix.guardArgs` for package authors, matches flags as the deployed program reads them. Its `parser` argument takes `"go"` for programs that use Go's `flag` package (treating `-flag` and `--flag` as the same flag), `"go-arg"` for alexflint/go-arg (which also accepts three or more dashes), `"paerser"` for Traefik (matching like `"go"` and ignoring letter case), or `"gnu"` for getopt, clap, pflag, and kingpin. An entry with `families` rejects both a flag and any `<flag>.<name>` sub-flags, an entry with `defaults` passes default flags that are omitted when `extraArgs` sets them, and `id` attaches a change record ID (such as `"K4740"`) to rejected-flag errors.
