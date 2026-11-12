# 2026-11-12 · `kix/lib/modules.nix` · The `[K0549]` message lists every old package name only when the first one is met as an instance's `package`.

`movedNames` reads the raw `instances` definitions. An old name met first elsewhere, such as through `meta.peekPackageMeta` during auto-instantiation, still throws its own one-name message, and a definition under `mkIf` is not read.
