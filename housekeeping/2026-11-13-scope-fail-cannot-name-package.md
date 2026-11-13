# 2026-11-13 · `kix/lib/core/error.nix` · `scope.fail` fills in the instance but cannot fill in the package name.

Packages have no `meta.name`, and an instance receives its package as a value, so the library never knows which package an instance runs. A package that wants its name in an error passes `package = "cnpg-database"` itself, which brings back a hand-written prefix. Tagging each package with its folder name in `kix/packages/by-level.nix` would let `scope.fail` fill it in.
