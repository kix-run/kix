# 2026-11-19 · `scripts/check-bump.sh` · The "package changed" check fails a package whose version lives in another package's folder.

`immich-machine-learning` reads its tag and digest from `kix/packages/experimental/immich/release.nix`, so a bump changes no file in its own folder. The bump workflow still runs `check-bump.sh` on that folder and requires a change there, which pushes the agent toward an edit made only to satisfy the check. On the Immich 3.4.2 bump the agent made a real header fix instead, but the next bump will not have one.
