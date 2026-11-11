# 2026-11-10 · `scripts/change-kind.py` · The change kind check does not build the kix-examples clusters.

The check builds only the clusters in this repository. Kix can build
kix-examples against a local library with `--override-input kixpkgs <dir>`,
but kix-examples is a separate private repository, and the workflow's
`GITHUB_TOKEN` cannot clone it. So a pull request can break or change an
example cluster without the check noticing. Adding it needs a token with read
access to `kix-run/kix-examples`.
