+++
kind = "added"
library = ["kix.argValues"]
packages = ["experimental/reloader", "experimental/external-dns"]
+++
Package authors can use `kix.argValues { parser; } "--flag" args` to extract all values passed for a CLI flag from an argument list or a flag attribute set. It matches flag names using the same `parser` rules as `kix.mergeArgs` and reads values passed after `=`, attached to a single-letter flag (under `"gnu"`), or as the next list item. `reloader` and `external-dns` now use `kix.argValues` to inspect `extraArgs`, so `reloader` now accepts `--namespaces`, `--namespaces-to-ignore`, and `--resource-label-selector` with their value as a separate argument (such as `[ "--namespaces" "apps" ]`) as well as with `=`.
