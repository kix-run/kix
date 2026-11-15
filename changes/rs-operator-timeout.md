+++
kind = "error"
cli = ["kix deploy --operator --timeout", "kix deploy --operator --on-error continue", "kix deploy --operator --reconcile", "kix deploy --operator --skip-orphan-check", "kix deploy --operator --force-conflicts", "kix deploy --operator --log-format", "kix deploy --operator --group-by"]
id = "K7218"
+++
`kix deploy --operator` now refuses the flags the Kix operator does not carry out: `--timeout`, `--on-error continue`, `--reconcile`, `--skip-orphan-check`, `--force-conflicts`, and a `--log-format` or `--group-by` other than the default. Before, Kix accepted them and ignored them. Remove them from `kix deploy --operator` commands.
