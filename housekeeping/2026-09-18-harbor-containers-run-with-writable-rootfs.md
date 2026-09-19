# 2026-09-18 · `kix/packages/harbor/default.nix` · `security.readOnlyRootfs` warns on all six harbor containers.

Upstream's chart does not set `readOnlyRootFilesystem` either. Turning it
on needs a writable emptyDir per scratch path (nginx temp dirs,
`/etc/core/ca`, registry upload state) and nobody has mapped those paths
yet.
