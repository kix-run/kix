# 2026-11-07 · `cli/kix/Cargo.toml` · `kix-lib` depends on `rand` 0.8.5, which RustSec RUSTSEC-2026-0097 marks unsound.

The advisory applies with a custom logger that calls `rand::rng()`. The fix is in `rand` 0.9, a new major version with renamed APIs, so it is more than a lock file update.
