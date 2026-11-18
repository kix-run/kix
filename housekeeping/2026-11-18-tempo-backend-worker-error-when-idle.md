# 2026-11-18 · `experimental/tempo` · An idle Tempo backend worker logs an error every 15 seconds.

Tempo 3.1.1 logs `error calling scheduler` at error level, with `no jobs found`, every time its backend worker asks for work and gets none, in a single-binary pod with no compaction or retention work pending. The noise hides real errors in `kix logs tempo`. Source: `modules/backendworker/backendworker.go:543` in grafana/tempo v3.1.1.
