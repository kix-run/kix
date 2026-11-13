+++
kind = "error"
cli = ["kix graph --format", "--format tree", "--format dot", "--format json"]
id = "K4721"
+++
`kix graph --format tree|dot|json` is now `kix graph -o tree|dot|json`. `kix graph` prints a tree by default, as before, and `-o yaml` prints the JSON document as YAML. `kix graph --format` fails with an error that names the new form, and `kix graph -o text` and `-o markdown`, which printed the tree, are refused.
