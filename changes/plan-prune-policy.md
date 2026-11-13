+++
kind = "silent"
cli = ["kix plan", "PlanFlags.prune", "PlanFlags.prune_mode"]
+++
In the plan document (`kix plan -o json` and saved `.kixplan` files), `flags.prune` is now a string that says what the deploy does with orphans: `delete` with `--prune`, `skip` with `--skip-orphan-check`, and `warn_only` otherwise. It was `true` or `false`, and `flags.prune_mode` is gone. A script that reads `flags.prune` as true or false must compare it with `"delete"` instead. `kix deploy --plan` refuses a plan file saved by an earlier Kix and names its schema version.
