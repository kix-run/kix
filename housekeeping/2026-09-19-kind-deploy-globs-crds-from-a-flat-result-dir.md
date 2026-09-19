# 2026-09-19 · `devenv.nix` kind-deploy · The CRD-first apply globs `result/*-customresourcedefinition.yaml`, but the manifest dir is nested by namespace, so the glob matches nothing and the plain apply fails on the PackageInstance kind.

`nix build .#cluster-<name>` writes `result/<namespace>/…` and
`result/_cluster/…`. The `kind-deploy` script in `devenv.nix` looks for CRD
files at the top level, finds none, then `kubectl apply -f result/` reports
`no matches for kind "PackageInstance"` on every PackageInstance file.
`scripts/kind-spread.sh` works around it with `find`. Hit 2026-09-19 while
proving derived pod spread on a kind cluster.
