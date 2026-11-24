# 2026-11-13 · `kix/contracts/` · The contract helpers and `kix.checkSecretKeys` still take a `who` string, so their errors carry no `instance` or `package` field.

`kix.contracts.secret.helpers.use` (which calls `kix.checkSecretKeys` in
`kix/lib/vocab/compose.nix`), `smtp.helpers.settings`, `oidc.helpers.client`,
`redis.helpers.requirePlaintext`, and each contract's `check` and
`assertions` put `who` at the start of the message and call plain
`kix.fail`. `kix check -o json` then gives the instance only inside the
text. About 30 packages pass `who` to `secret.helpers.use` alone. The
same holds for `helpers.mergeCollide` in `kix/lib/eval/helpers.nix`, whose
callers in `eval/view.nix`, `eval/import.nix`, and `helm.nix` pass a text
context. `kix.mergeGuarded`, `kix.mergeEnv`, `kix.guardArgs`, and
`kix.storage.mkClasses` take `scope` and no longer have this problem.
