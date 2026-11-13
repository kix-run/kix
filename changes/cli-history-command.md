+++
kind = "error"
cli = ["kix rollback --list"]
id = "K5914"
+++
`kix rollback <cluster> --list` is now `kix history <cluster>`. It prints the same list of earlier deploys, and the same JSON with `-o json`. `kix rollback --list` fails with an error that names `kix history`.
