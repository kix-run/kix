# 2026-11-24 · `kix/packages/experimental/{volsync,arc,snapshot-controller}` · Packages that likely guard Go `flag` programs do not set `parser = "go"`.

These packages guard controller-runtime or CSI sidecar flags with `kix.guardArgs`, and their programs probably parse flags with Go's `flag` package, which reads `-flag` as `--flag`. No comment or upstream reference in the package says so, so they still use the default `"gnu"` parser, and `extraArgs = [ "-leader-elect=false" ]` passes the guard. Check each program's `main.go` and set `parser = "go"` where it holds.
