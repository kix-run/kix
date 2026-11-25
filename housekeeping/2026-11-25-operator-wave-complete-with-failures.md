# 2026-11-25 · `cli/kix-cli/src/commands/operator.rs` · `kix deploy --operator` prints a wave that failed as Complete.

During an operator deploy that stopped at a Secret it could not decrypt, the watch printed `✓ Wave 1: Complete (0/1 applied, 1 failed)`. The wave's status in `status.waves` says `Complete` although its only object failed, so the line contradicts itself. Look at where the engine's checkpoint marks a wave `Complete` (`record_waves`) and at `Progress::lines`.
