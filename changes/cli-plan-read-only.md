+++
kind = "added"
+++
`kix plan <cluster> --read-only` compares the build with the live cluster using only `get` and `list` permission, with no server-side dry run, so it works with read-only credentials such as a CI job on a pull request. It lists what it cannot check without a write (admission webhooks, field ownership conflicts, and refusals), prints `-o text`, `markdown`, `json`, or `yaml`, and writes a plan file with `--out`.
