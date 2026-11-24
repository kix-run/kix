# 2026-11-24 · `scripts/copy-pass` · `--list` leaves out a large new Nix file whose strings people read.

The Nix check pipes `grep -vE ... <<<"$added"` into `grep -qE`. Under
`set -o pipefail`, `grep -q` exits at its first match, the first `grep` dies
of SIGPIPE when its output is larger than the pipe buffer, and the pipeline
reports failure. So a big file, such as a new package's `default.nix` with
hundreds of added lines, is never listed, and the Copy pass workflow does
not ask for a pass on it. Seen with `kix/packages/experimental/keda/default.nix`;
passing the file by name works around it.
