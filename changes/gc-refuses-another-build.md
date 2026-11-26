+++
kind = "error"
cli = ["kix gc"]
id = "K6276"
+++
`kix gc` and `kix gc --full-scan`, with or without `--dry-run`, refuse when the build your files make is not the build of the cluster's current deployment record, and delete nothing. Before, `kix gc` deleted what the files' build no longer had, so files ahead of or behind the cluster deleted objects the running build still used. Deploy the files first with `kix deploy <cluster>`, then run `kix gc <cluster>`, or deploy and delete in one step with `kix deploy <cluster> --prune`. `kix gc --operator` is unchanged.
