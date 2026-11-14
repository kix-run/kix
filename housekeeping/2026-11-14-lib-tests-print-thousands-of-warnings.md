# 2026-11-14 · `kix/lib/tests` · A passing run of the library tests prints 700 warning lines.

`nix build .#checks.x86_64-linux.kix-lib-tests` prints 706 `trace:` lines for a run that passes. It printed 19,037 until the library stopped printing the warnings it also keeps in each cluster's list. The lines left come from warnings that exist only as `builtins.trace` calls: 335 say that a cluster capability is unset, and most of the others say that a workload's availability was capped. The one line that matters, the name of a failing test, still comes last.

In an experiment on 2026-11-13, agents on a cheap model stopped this check or skipped it in every one of six runs, and said the output was the reason. The lines go away when those warnings reach the cluster's list. Related: `2026-11-13-trace-only-library-warnings-stay-hidden.md`.
