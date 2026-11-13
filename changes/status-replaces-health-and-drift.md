+++
kind = "error"
cli = ["kix health", "kix drift", "kix status --operator"]
id = "K6116"
+++
`kix status` now does the work of `kix health` and `kix drift`, which are removed. Run `kix status <cluster> --check presence` in place of `kix health <cluster>`, and `kix status [cluster] --check drift` in place of `kix drift`. `kix status --operator` is also removed, because its view by package is now what `kix status` shows. Each old form stops with an error that names the new one.
