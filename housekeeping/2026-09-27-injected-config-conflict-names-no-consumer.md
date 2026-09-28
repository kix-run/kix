# 2026-09-27 · `kix/lib/eval/resolve.nix` · A conflict between a dependency's config and a consumer's injected config does not name the consumer.

Setting `sentinel.enabled = true` on a valkey that n8n uses fails with
"The option `sentinel.enabled' has conflicting definition values", and both
definitions are listed as `<unknown-file>`. The injection record carries
`source` (the consumer instance), but `evaluateInstanceConfig` passes the
injected config to `evalModules` without a `_file`, so the user cannot tell
which package asked for the other value.
