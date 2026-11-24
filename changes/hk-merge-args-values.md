+++
kind = "added"
library = ["kix.argValues"]
packages = ["experimental/reloader", "experimental/external-dns"]
+++
Existing `reloader` and `external-dns` configurations need no changes. In `reloader`, `extraArgs` now accepts `--namespaces`, `--namespaces-to-ignore`, and `--resource-label-selector` with the value as the next list item (such as `[ "--namespaces" "apps" ]`) in addition to `--flag=value`. Both packages now read `extraArgs` with the new `kix.argValues { parser; } "--flag" args` helper, which package authors can use to collect every value passed for a flag in an argument list or flag attribute set. `kix.argValues` uses the same `parser` rules as `kix.mergeArgs` and reads values after `=`, attached to a single-letter flag (under `"gnu"`), or from the next list item.
