+++
kind = "error"
cli = ["--current-activation"]
id = "K3428"
+++
`kix plan --current-activation` and `kix deploy --current-activation` are now `--offline`. They still compare the build with the last deploy from this machine without contacting the cluster. The old flag fails with an error that names `--offline`.
