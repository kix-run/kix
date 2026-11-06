# 2026-11-06 · `kix/packages/traefik/default.nix` · traefik keeps its own copy of the `kix.guardArgs` flag matcher.

Traefik reads flag names in any letter case, and any key under a provider (`--providers.kubernetescrd.*`) turns that provider on. `kix.guardArgs` matches exact, case-sensitive flags only, so traefik keeps a local matcher (`reasonFor`, `argProblems`) that lower-cases the flag and refuses a whole flag family by prefix. The wording follows `guardArgs`, but a change to the shared matcher does not reach it.
