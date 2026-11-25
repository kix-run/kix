# 2026-10-03 · `kix/lib/eval/auto.nix` · Setting an optional dependency to `null` cannot say "no provider".

`null` means "not wired" throughout the library (`resolveArg`, `auto.nix`), so
auto-resolution still binds the dependency by alias. A cluster that wants no
gateway, no `otlp` endpoint, or no other optional provider in a namespace that
has one has no way to say so. `kix.expose` works around this for `gateway` by
binding only an instance that claims the gateway contract. A distinct value,
or an explicit "unwired" marker, would let a cluster opt out.

The same gap now refuses a valid backup setup. A `stackgres-object-storage`
instance that uses pod credentials (`useIAMRole`) picks up any Secret aliased
`storageCredentials` in its namespace, such as one meant for a `cnpg-cluster`,
and is refused with `[K5962]`. Its only fix is to remove the other alias.
