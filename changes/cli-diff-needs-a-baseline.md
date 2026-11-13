+++
kind = "error"
cli = ["kix diff", "kix diff --context"]
id = "K3143"
+++
`kix diff <cluster>` no longer compares the build with the live cluster. Use `kix plan <cluster> --read-only`, which does the same comparison with only `get` and `list` permission, takes `-o text|markdown|json|yaml` and `--detail`, and prints the same plan document. `kix diff` now only compares the build with another build and never contacts a cluster: give it `--from PATH` (a build, a snapshot, or an export), `--from-bundle FILE`, or `--bundle FILE` alone. `kix diff <cluster>` with none of these fails with an error that names `kix plan --read-only`.
