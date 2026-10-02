# 2026-09-27 · `cli/kix-cli/src/commands/deploy.rs` · `kix deploy --log-format json` writes the plan as plain text on the same stdout as the NDJSON events.

`--help` calls the format "NDJSON, one event per line, suitable for
CI/automation", but stdout also carries `Building cluster ...`, the
package plan, the orphan and `Kept:` lists, and blank lines. The run now
ends with a JSON `summary` object rather than the text summary line, but
a consumer still has to skip every line that does not start with `{`
before it can parse the stream.
