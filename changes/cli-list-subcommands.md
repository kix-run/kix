+++
kind = "error"
cli = ["kix inspect", "kix images", "kix list packages --cluster"]
id = "K0450"
+++
`kix inspect <cluster>` is now `kix list resources <cluster>`, and `kix images <cluster>` is now `kix list images <cluster>` (it still takes `--sources`). `kix list packages --cluster <cluster>` is now `kix list packages <cluster>`. The output is unchanged. The old forms fail with an error that names the new one.
