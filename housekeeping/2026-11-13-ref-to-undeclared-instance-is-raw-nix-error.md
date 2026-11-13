# 2026-11-13 · `kix/lib/eval/cluster.nix` · `ref.<ns>.<instance>` for an instance the cluster does not declare fails with a raw Nix error.

`ref` holds only the names `possibleInstanceNames` can produce. A typo, or a
ref to an instance a later commit adds, stops evaluation with "error:
attribute 'kix-data' missing" at the `deps` line and a 57-frame trace. No Kix
message names the instances that do exist. `checkRefTargets` in
`kix/lib/eval/resolve.nix` has a proper message, but it covers only names
from `availablePackages`.
