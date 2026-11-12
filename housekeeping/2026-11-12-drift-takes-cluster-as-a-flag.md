# 2026-11-12 · `kix drift` · `kix drift` takes the cluster as `--cluster`, while every other cluster command takes it as an argument.

`kix drift dbtest` fails with "unexpected argument 'dbtest' found", though `kix status dbtest`, `kix health dbtest`, and `kix diff dbtest` work. A user who moves between the commands trips on it. Changing it is a CLI change, so it needs a change record with a `cli` field.
