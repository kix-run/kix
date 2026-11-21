# A cluster on another input than `kix` never uses the eval cache

Commands on a cluster that `[versions]` in `kix.toml` lists under an input
other than `kix` evaluate the project from source every time. A cluster on
`kix` reads the eval cache.

Kix builds such a cluster with `--override-input kix <the locked input>`
(`GlobalArgs::input_overrides` in `cli/kix-cli/src/cli.rs`).
`LocalBuilder::source_fingerprint` in `cli/kix-core/src/eval/cli_backend.rs`
returns no fingerprint when any input is overridden, because an override
can point at a folder that changes. This override is different: it names a
revision that `flake.lock` pins, so it cannot change under the cache.

A fix would let the fingerprint include an override that names a locked
revision, and keep skipping the cache for the overrides a person passes.

Seen while building kix#288 on 21 November 2026.
