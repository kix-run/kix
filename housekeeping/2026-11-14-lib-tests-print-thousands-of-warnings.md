# 2026-11-14 · `kix/lib/tests` · A passing run of the library tests prints 118 trace lines.

`nix build .#checks.aarch64-darwin.kix-lib-tests` prints 118 `trace:` lines for a run that passes. It printed 19,037 until the library stopped printing the warnings it also keeps in each cluster's list. The lines left are `ASSERTION FAILED` lines from tests that expect a build to fail, and `[kix] auto-instantiated` and `[kix] activated optionals` notes. The one line that matters, the name of a failing test, still comes last.

In an experiment on 2026-11-13, agents on a cheap model stopped this check or skipped it in every one of six runs, and said the output was the reason. Related: `2026-11-13-trace-only-library-warnings-stay-hidden.md`.
