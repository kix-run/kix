+++
kind = "error"
cli = ["kix deploy --operator --timeout", "kix deploy --operator --on-error continue", "kix deploy --operator --reconcile", "kix deploy --operator --skip-orphan-check", "kix deploy --operator --force-conflicts", "kix deploy --operator --log-format", "kix deploy --operator --group-by"]
id = "K7218"
+++
Remove unsupported flags from `kix deploy --operator` commands: `--timeout`, `--on-error continue`, `--reconcile`, `--skip-orphan-check`, `--force-conflicts`, `--log-format` (other than `pretty`), and `--group-by` (other than `package`). To use any of these flags, run `kix deploy` without `--operator`. Previously, `kix deploy --operator` accepted and ignored them. It now exits with an error before changing the cluster.
