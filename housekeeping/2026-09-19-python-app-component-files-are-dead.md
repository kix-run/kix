# 2026-09-19 · `kix/packages/python-app` · `backend.nix`, `caddy.nix`, `frontend.nix`, `redis.nix`, `config.nix`, `migration.nix` and `helpers.nix` are imported by nothing; `default.nix` re-declares everything they hold.

A half-finished split. Anyone reading the directory picks the wrong file
to edit, and a fix in one copy is silent in the other: the migrate Job in
`default.nix` now goes through `scope.mkJob`, while the copy in
`migration.nix` still builds it with `scope.mkResource`, which the lib
refuses, so the dead copy would fail the moment it was wired in. Finish
the split or delete the files. `kix/packages/openebs` had the same shape
(`mayastor.nix`, `common.nix`) and lost the dead files in the same change.
