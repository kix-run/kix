# 2026-11-06 · kix-examples cluster files · The example cluster files still set `name` to the same value as their key in `mkFlake`.

Since a cluster listed in `kix.lib.mkFlake` takes its name from its key, the `name = "..."` line in kix-examples files such as `tutorials/02-hello-world/cluster.nix` is redundant. The docs now say a listed cluster needs no `name`, but the snippets they embed from kix-examples still show one, so the text and the example disagree. Remove the line from every kix-examples cluster file whose key equals its name, then recapture the tutorial snippets.
