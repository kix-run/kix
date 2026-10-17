# 2026-10-17 · `.git/hooks/*`, `lefthook.yml` · Every git hook needs a working Nix evaluation before lefthook starts.

Outside the devenv shell, `LEFTHOOK_BIN` is unset, so each hook runs `nix run --inputs-from . nixpkgs#lefthook`, which fetches the checkout as a flake input. Any Nix fault then blocks every commit and push, even a docs-only one: on 2026-10-17 a root-owned `$XDG_CACHE_HOME/nix` made every hook fail with `cannot open SQLite database ... fetcher-cache-v4.sqlite`, while lefthook itself had nothing to run.
