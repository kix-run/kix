+++
kind = "security"
packages = ["experimental/reloader"]
cve = ["CVE-2026-111943", "CVE-2026-78661", "CVE-2026-97045"]
+++
`reloader` runs reloader 1.4.24 instead of 1.4.22. Reloader 1.4.23 moves to Go 1.26.10 (CVE-2026-111943), and 1.4.24 moves to golang.org/x/net 0.62.0 (CVE-2026-78661 and CVE-2026-97045). The first deploy after you upgrade restarts the reloader pods once. Reloader 1.4.24 no longer serves `/debug/pprof` on port 9090. To keep profiling, set `extraArgs = [ "--enable-pprof" ]`, which serves it on port 6060 of each pod. To go back, deploy the previous Kix version: reloader 1.4.22 starts on the state 1.4.24 leaves.
