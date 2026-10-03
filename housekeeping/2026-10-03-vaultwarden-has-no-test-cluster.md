# 2026-10-03 · `kix/packages/vaultwarden` · Vaultwarden renders only in the ludo clusters, so a change to it has no cheap rendered-output check.

`clusters/` has no test cluster that instantiates vaultwarden; only
`ludo/services.nix` does. Comparing its manifests before and after a change
means building ludo, which is the slowest build in the repo.
`every-package-evaluates` evaluates its defaults but renders no database
dependency.
