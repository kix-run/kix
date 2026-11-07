# 2026-11-07 · `cli/kix-cli/src/commands/health.rs` · `store_path_for_hash` reads the whole store directory once for every hash it looks up.

`resolve_hash_to_rid` calls it per resource, and each call runs `read_dir` over the store until a name matches. Kix's own store is small, but under the `nix` builder the store is the machine's `/nix/store`, which can hold hundreds of thousands of entries, so `kix health` can get slow on a developer machine.
