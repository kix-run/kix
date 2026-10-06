# 2026-10-06 · `lefthook.yml` · Every git hook passes without running when `lefthook` is not on PATH.

The hook scripts that lefthook installs in `.git/hooks/` print "Can't find
lefthook in PATH" and exit 0. A commit or push made outside the dev shell
therefore skips every check, including the `commit-msg` hook that refuses
`Co-Authored-By` trailers, and the only sign is that one line of output. Hit
2026-10-06 committing and pushing `kix-bundle` from a plain shell; fmt and
clippy had been run by hand.
