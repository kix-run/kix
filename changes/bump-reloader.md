+++
kind = "silent"
packages = ["experimental/reloader"]
+++
`reloader` runs reloader 1.4.24 instead of 1.4.22. The first deploy after you upgrade restarts the reloader pods once. Reloader 1.4.24 no longer serves `/debug/pprof` on port 9090. To keep profiling, set `extraArgs = [ "--enable-pprof" ]`, which serves it on port 6060 of each pod. To go back, deploy the previous Kix version: reloader 1.4.22 starts on the state 1.4.24 leaves.
