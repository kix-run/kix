# 2026-10-09 · `cli/kix` · `cargo check -p kix-lib --features nix-ffi` fails in the dev shell.

The `nix-bindings-*-sys` build scripts fail ("failed to run custom build
command") inside `nix develop`, so nothing checks `eval/ffi.rs`. A change that
breaks the FFI backend, or deletes something only it calls, goes unnoticed.
