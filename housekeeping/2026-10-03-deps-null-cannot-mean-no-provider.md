# 2026-10-03 · `kix/lib/eval/auto.nix` · Setting an optional dependency to `null` cannot say "no provider".

`null` means "not wired" throughout the library (`resolveArg`, `auto.nix`), so
auto-resolution still binds the dependency by alias. A cluster that wants no
gateway, no `otlp` endpoint, or no other optional provider in a namespace that
has one has no way to say so. `kix.expose` works around this for `gateway` by
binding only an instance that claims the gateway contract. A distinct value,
or an explicit "unwired" marker, would let a cluster opt out.
