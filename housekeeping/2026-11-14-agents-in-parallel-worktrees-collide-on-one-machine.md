# 2026-11-14 · development machine · Several agents working in separate worktrees on one machine get in each other's way.

Seen on 2026-11-13 with up to eleven agents, each with its own worktree and kind cluster:

- `kind create cluster` and `kind delete cluster` change the current context in the shared `~/.kube/config`, so one agent's kubectl can reach another's cluster. A unit test that reads the current context failed for the same reason.
- Each worktree that runs a cargo test builds its own target directory under `$XDG_CACHE_HOME/kix-cargo-target`, about 2.4 GB for the snapshot test alone. That filled a 492 GB disk, which already held 329 GB of these caches, 68 GB of them for worktrees that no longer existed.
- Two agents forwarded the same local port, and one wrote test data into the other's Grafana.
- `crane auth login` writes to the shared `~/.docker/config.json`.

The `package-authoring` skill's kind steps mention none of this.
