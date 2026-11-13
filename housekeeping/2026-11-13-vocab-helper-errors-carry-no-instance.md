# 2026-11-13 · `kix/lib/vocab/compose.nix` · Errors from `kix.mergeGuarded`, `kix.mergeEnv`, and `kix.guardArgs`, and the StorageClass check in `kix/lib/vocab/storage-class.nix`, carry no `instance` field, because the helpers take a `who` string.

Each helper puts `who` (such as `"reloader ns/name"`) at the start of the
message and calls plain `kix.fail`. `kix check -o json` then gives the
instance only inside the message text, and a tool cannot group the error
with its instance. The same holds for the secret key check in
`compose.nix` and for `helpers.mergeCollide` in `kix/lib/eval/instance.nix`.

The fix changes the helpers' signature: take `scope` (or its `fail`) in
place of `who`, and raise the error with `scope.fail`. About 170 call sites
in about 60 packages pass `who` today (`grep -rn 'inherit who' kix/packages`),
and several packages also build their own messages from `who`, so the
change is a sweep of its own.
