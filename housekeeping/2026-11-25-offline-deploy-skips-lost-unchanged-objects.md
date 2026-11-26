# 2026-11-25 · `kix deploy --offline` · An offline deploy does not recreate an unchanged object that is missing or being deleted.

The plan made with `--offline` reads nothing, and once the deploy connects
it reads only the last runs of its Jobs. An unchanged object that is missing
or being deleted stays a skip, so the deploy can still report success while
the object is gone. The connected plan lists the build's kinds and catches
it. See `run_deploy_async` in `cli/kix-cli/src/commands/deploy/mod.rs`.
