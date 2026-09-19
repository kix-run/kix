# 2026-09-19 · `kix/lib/modules.nix` `global` · The `global` option cannot pass a value to packages, and its description points at a mechanism that does not exist.

`global` is described as "cluster-wide configuration values, packages
read these via `_kixOptions` defaults". Nothing in `kix/lib` defines or
reads `_kixOptions`. What the code does instead (`kix/lib/eval/resolve.nix`,
the `{ config = clusterConfig.global or { }; }` module) is feed every key
of `global` into every package's option evaluation, so a key that any one
package does not declare fails the whole build with "option does not
exist". No cluster in the tree sets `global`. This matters as soon as we
want one operator decision (an availability profile, say) to reach every
package: the only broadcast channel we advertise is this one.
