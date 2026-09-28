# 2026-09-27 · `cli/kix-cli/src/commands/` · Progress status lines write `\r\x1b[2K` to stderr with `--no-color` and without a TTY.

`kix deploy --log-format line --no-color 2>&1 | cat` and `kix gc --no-color`
still emit carriage returns and the ANSI clear-line sequence around
`Evaluating cluster ...`, `Building ...`, `Reading N packages...`, so the
captured log is one long line of escape codes before the plan.
`gc.rs` and `deploy.rs` write the sequence directly.
