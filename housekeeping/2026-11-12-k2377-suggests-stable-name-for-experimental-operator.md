# 2026-11-12 · `kix/lib/eval/auto.nix` · The operator-placement refusal suggests `packages.stackgres-operator` and then says to write the experimental name "if" the package is experimental.

Kix knows the package's level when it writes the message. For `stackgres-operator` the first suggestion does not evaluate, so a user who copies it gets a `[K0549]` error next.
