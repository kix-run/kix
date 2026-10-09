# 2026-10-09 · `cli/kix`, `cli/kix-cli` · `cargo doc --workspace` warns of an output filename collision at `doc/kix/index.html`.

kix-lib's library target and kix-cli's binary target are both named `kix`, so their docs are written to the same directory and one overwrites the other. Cargo prints "warning: output filename collision" on every workspace doc build, and the docs of one target are lost. Renaming one target, or setting `doc = false` on the kix-cli binary, removes it; the second also stops checking the CLI's doc links.
