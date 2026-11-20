+++
kind = "error"
id = "K5221"
+++
If you set `KIX_RELEASE_SOURCE` to a mirror of kix.run, copy `releases/index.json.sig` alongside `releases/index.json` and refresh both files at least once a week (each index expires seven days after kix.run signs it, and kix.run signs a new one daily). If `releases/index.json.sig` is missing, Kix stops with `[K5221]`. Users who install directly from kix.run need no changes. Kix now verifies the release index against a built-in signing key and rejects indexes that are unsigned, expired, or older than the newest index already saved on the machine. When an index is expired or older than the saved copy, Kix refuses to pick a release automatically, though an exact version (such as the one pinned in `flake.lock`) still installs with a warning.
