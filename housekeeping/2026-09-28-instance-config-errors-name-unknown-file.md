# 2026-09-28 · `kix/lib/eval/resolve.nix` · Module errors name every instance and injection definition `<unknown-file>`.

`evaluateInstanceConfig` wraps each instance config value and each dependency injection as a module with no `_file`, so a conflict reads "In `<unknown-file>'" and does not say which instance or which consumer set the value. The package's own `config` module is named `package config of <ns>/<inst>`; `wrappedModules` and `injectionModules` could carry the instance and the injection `source` the same way.
