# 2026-09-20 · Code comments obscure current contracts with history and rhetoric.

`kix/lib/env.nix:15` describes the removed `_envScope` design; `kix/lib/default.nix:70`
retells a fixed export bug. `kix/lib/vocab/compose.nix:120` defends `isPinned` as
"Not dead code." `kix/lib/core/facts.nix:18` mixes an important dependency constraint
with metaphors and emphasis. `cli/kix/src/registry/mod.rs:3` similarly mixes a
module contract with a design argument. The new CLAUDE.md rules guide future
comments; these existing passages still need a focused cleanup.
