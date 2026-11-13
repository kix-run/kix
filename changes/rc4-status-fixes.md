+++
kind = "changed"
cli = ["--output"]
+++
The help of each command now lists only the `-o` formats that the command prints, and names the flags a format needs. For example, `kix status --help` lists `text`, `json`, and `yaml`, and `kix plan --help` says that `json` and `yaml` need `--read-only`. A command refuses any other format. `kix history` now starts with "Deployment history for" instead of "Rollback: deployment history for". When `kix gc` has nothing to delete, it now counts the objects still in use instead of calling them unchanged, and says how many older deployment records it keeps for rollback.
