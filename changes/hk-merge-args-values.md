+++
kind = "added"
library = ["kix.argValues"]
packages = ["experimental/reloader", "experimental/external-dns"]
+++
`kix.argValues { parser; } "--flag" args` returns the values that a list of command-line words, or an attribute set of flags, gives one flag. It matches words as `kix.mergeArgs` does under the same `parser`, and reads a value written after `=`, attached to a one-letter flag, or as the next word. `reloader` and `external-dns` now read `extraArgs` with it. As a result, `reloader` accepts `--namespaces`, `--namespaces-to-ignore`, and `--resource-label-selector` with the value as a separate word, which it used to reject.
