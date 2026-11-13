+++
kind = "error"
cli = ["--output", "-o text", "-o markdown", "-o yaml"]
id = "K2184"
+++
Each command now refuses an `-o` format it does not print. Kix stops before the command runs, exits 1, and lists the formats the command prints. Before, Kix ignored the value and printed its default. These command lines now fail: `kix build -o text` and `-o markdown` (use `-o yaml`), `kix graph -o text` (use `-o tree`), `kix compliance sbom -o text` and `kix compliance attest -o text` (use `-o json`), `-o markdown` on any command except `kix plan`, `kix deploy --dry-run`, and `kix diff`, `-o yaml` on `kix drift`, and `-o json` or `-o yaml` on a command that prints only text, such as `kix deploy`, `kix gc`, or `kix doctor`. `kix pin` now also prints YAML with `-o yaml`. The reference page "Output formats" lists the formats of each command.
