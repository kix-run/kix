# 2026-10-02 · `kix/lib/vocab/compose.nix` · `kix.mkEnvVars` sorts env vars by name, so a value that uses `$(VAR)` may not expand.

`mkEnvVars` builds the list with `lib.mapAttrsToList`, which orders it by name. Kubernetes expands `$(VAR)` in an env value only when `VAR` comes earlier in the list. In `kix/packages/ingress-nginx`, `env.APP_NS = "$(POD_NAMESPACE)"` renders before `POD_NAMESPACE` and stays a literal string. Every package that renders `kix.options.env` through `kix.mergeEnv` and `kix.mkEnvVars` has the same behaviour, and the `env` option descriptions do not mention it.
