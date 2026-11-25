# 2026-11-25 · `cli/kix-cli/src/commands/gc/` · `kix gc` decides what to delete from the local files, so it deletes live objects when the files are ahead of or behind the cluster.

`kix gc <cluster>` builds the current files and deletes what that build no longer has. With the cluster on build A and the files at build B, it deletes instances that B drops although the cluster still runs A. `kix gc --full-scan` goes further: it lists every object whose build hash is not in the local build.

Seen on kind with the cluster on one build and the files at another: `kix gc lab --full-scan --dry-run` listed 18 live objects to delete, including a running Deployment and its Service. `kix deploy --only` leaves the cluster behind the files for as long as a rollout takes, and `kix deploy --only --prune` is refused for this reason, but `kix gc` is not.
