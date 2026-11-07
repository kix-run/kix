# 2026-11-07 · `cli/Cargo.toml` · `serde_yml` 0.0.12, a direct dependency of `kix-cli` and `kix-lib`, is unsound and unmaintained.

RustSec RUSTSEC-2025-0068 marks it unsound and unmaintained, and it pulls in `libyml` (RUSTSEC-2025-0067) and `unsafe-libyaml` (unmaintained). `cargo audit` reports these as warnings on every build. Replacing it changes the code that writes YAML, so a replacement must keep `kix build` output byte for byte.
