# 2026-11-07 · `cli/kix-cli` · `ratatui` 0.29 pins `lru` 0.12.5, which RustSec RUSTSEC-2026-0253 and RUSTSEC-2026-0002 mark unsound.

The fixed `lru` needs a newer `ratatui`, which changes the terminal UI API that `kix deploy`'s live view uses. `cargo audit` reports it as a warning on every build.
