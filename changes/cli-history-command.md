+++
kind = "error"
cli = ["kix rollback --list"]
id = "K5914"
+++
`kix rollback <cluster> --list` is now `kix history <cluster>`. It lists the deploy that runs on the cluster and the earlier deploys `kix rollback` can go back to, prints the same JSON with `-o json`, also takes `-o yaml`, and changes nothing on the cluster. `kix rollback --list` fails with an error that names `kix history`.
