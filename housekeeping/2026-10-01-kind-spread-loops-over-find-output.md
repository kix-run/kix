# 2026-10-01 · `scripts/kind-spread.sh` · The CRD apply loop splits `find` output on whitespace.

Line 50 runs `for f in $(find result-spread/ ...)`, which shellcheck reports as SC2044. A path with a space or glob character would be split or expanded, so the loop would apply the wrong files or none. The rendered file names have no spaces today, so the problem does not show yet.
