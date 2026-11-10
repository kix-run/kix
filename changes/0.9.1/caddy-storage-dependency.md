+++
kind = "changed"
packages = ["caddy"]
+++
`caddy` takes an optional `storage` dependency, a claim for /data, so pods share certificates. Without it, /data stays an emptyDir.
