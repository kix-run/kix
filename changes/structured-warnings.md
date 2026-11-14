+++
kind = "changed"
library = ["kix.fail", "scope.fail"]
cli = ["kix check -o json", "kix plan", "kix build", "kix deploy", "kix diff -o json"]
+++
`kix build`, `kix plan`, `kix deploy`, `kix bundle`, `kix diff`, and the other commands that build a cluster now print the Kix library's warnings to stderr, as `kix check` lists them. A plan file and `kix diff -o json` list them in `warnings`, and `kix plan -o markdown` shows them in a section of their own. Each warning now has the fields of a library error: the instance is in `instance` and no longer at the start of `message`, and a warning can name an `object`, `option`, `dependency`, `clusterOption`, `fix`, and `id`. `kix check -o json` includes these fields. A package's `warnings` may return records with these fields as well as strings. A warning or error with a field in the wrong form shows the same error everywhere: Kix leaves out the field and says why. A warning with such a field stops the build.
