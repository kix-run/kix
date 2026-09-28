# 2026-09-27 · `cli/kix-cli/src/commands/gc.rs` · `kix gc --hard` attributes a package's PackageInstance to `package: _cluster`.

In the garbage list, `ConfigMap/widgets-settings` in namespace
`d8gc-widgets` shows `package: d8gc-widgets/widgets`, while
`PackageInstance/widgets` from the same package shows `package: _cluster`.
The reader cannot tell from the list which package the marker belonged to.
