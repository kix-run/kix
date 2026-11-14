# 2026-11-14 · `kix/lib/tests` · A passing run of the library tests prints 19,000 warning lines.

`nix build .#checks.x86_64-linux.kix-lib-tests` printed 19,037 `trace:` lines (3 MB) on `main` at `5ca91ecc` for a run that passed. One message, "no DNS instance (alias 'dns') was found", accounts for 4,148 of them. Most of the rest are scorecard findings about the small packages the tests build (`app`, `db`, `dns`), each repeated 300 to 480 times. The one line that matters, the name of a failing test, comes last.

In an experiment on 2026-11-13, agents on a cheap model stopped this check or skipped it in every one of six runs, and said the output was the reason. Two of the three runs on `external-dns` then shipped a unit test that fails. The warnings come from many `builtins.trace` call sites in `kix/lib`, so the tests have no one place to turn them off. Related: `2026-11-13-trace-only-library-warnings-stay-hidden.md`.
