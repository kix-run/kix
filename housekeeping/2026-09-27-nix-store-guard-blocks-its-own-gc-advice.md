# 2026-09-27 · `.claude/hooks/nix_store_guard.py` · Below 12 GB free the guard refuses `nix store gc` too, although its refusal message says to run it.

The hook refuses every Nix command when the store volume is under 12 GB,
and the message names `nix store gc` and `nix store gc --max 50G` as the
remedy. Those commands are refused by the same check, so an agent that
reaches the floor cannot reclaim space the way it is told to. Hit on
2026-09-27 at 732 KB free; the disk had to be cleared by other means
(stale testcontainers and Docker images) before `nix store gc` would run.
