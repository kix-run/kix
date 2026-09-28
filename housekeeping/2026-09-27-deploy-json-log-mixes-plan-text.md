# 2026-09-27 · `cli/kix-cli/src/commands/deploy.rs` · `kix deploy --log-format json` writes the plan and summary as plain text on the same stdout as the NDJSON events.

`--help` calls the format "NDJSON, one event per line, suitable for
CI/automation", but stdout also carries `Building cluster ...`, the
package plan, the orphan and `Kept:` lists, blank lines and
`Deploy complete: ...`. A consumer has to skip every line that does not
start with `{` before it can parse the stream.
