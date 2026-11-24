+++
kind = "added"
library = ["kix.mergeArgs"]
+++
Package authors can use `kix.mergeArgs` to build a container's argument list (or flag attribute set) from the package's flags and `extraArgs`, stopping the build when `extraArgs` sets a flag the package reserves. Its required `parser` argument matches flags the way the program reads them: `"gnu"` (getopt, clap, pflag, and kingpin), `"go"` (Go's `flag` package, where `-flag` and `--flag` are the same), `"go-arg"` (alexflint/go-arg, which accepts any number of leading dashes), or `"paerser"` (Traefik, which matches like `"go"` and ignores letter case). Entries in `args` and `after` can pass unlocked flags, `{ defaults = ...; }` flags that `extraArgs` replaces, or reserved flags (`flags`, `names`, and `<flag>.<name>` `families`) with `from` or `reason` and an optional `fix`. Set `id` to attach a change ID (such as `"K4740"`) to rejected-flag errors.
