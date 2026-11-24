+++
kind = "added"
library = ["kix.mergeArgs"]
+++
Package authors can use `kix.mergeArgs` to merge a package's CLI flags with `extraArgs` while blocking overrides of package-owned flags. Its required `parser` argument matches flags the way the program parses them: `"gnu"` (for getopt, clap, pflag, and kingpin), `"go"` (Go's `flag` package, where `-flag` and `--flag` are the same), `"go-arg"` (alexflint/go-arg, which also accepts three or more leading dashes), or `"paerser"` (Traefik, which matches like `"go"` and ignores letter case). Entries with `families` block a flag and all `<flag>.<name>` sub-flags, entries with `defaults` pass default flags only when `extraArgs` does not set them, and `id` attaches a change record ID (such as `"K4740"`) to errors.
