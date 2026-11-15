+++
kind = "error"
cli = ["kix deploy --operator --timeout"]
id = "K7218"
+++
`kix deploy --operator` no longer accepts `--timeout`. Before, the CLI accepted the flag but did not send it to the Kix operator, which waits for each resource with its own readiness timeout. Remove `--timeout` from `kix deploy --operator` commands.
