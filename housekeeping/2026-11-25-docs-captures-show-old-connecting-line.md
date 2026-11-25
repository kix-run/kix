# 2026-11-25 · `docs/src/command-output/` · Recorded deploy outputs still show `Connecting to cluster...`.

`kix plan` and `kix deploy` now print `Connecting to context <name> (<server>)...`, and the first deploy of an unbound definition prints a note on binding. Eleven captured sidecars under `docs/src/command-output/` still hold the old line. They need a capture run against a kind cluster (`docs/nix/captures.nix`).
