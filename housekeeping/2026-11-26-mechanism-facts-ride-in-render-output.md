# 2026-11-26 · `kix/lib/vocab/cloud-identity-mechanisms.nix` · Facts about a mechanism that do not depend on the identity come back from `render`.

`servesHostNetwork`, `podEnvFix`, and the variable names in `podEnv` are the same for every identity, yet `render` returns them with each rendered value, because `mkMechanism` was being changed on another branch at the same time. Once both branches merge, move the constant facts to `mkMechanism` arguments and keep only the value-dependent parts (`podEnv` values) in `render`.
