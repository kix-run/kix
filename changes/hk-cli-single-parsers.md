+++
kind = "fixed"
+++
`kix deploy` and `kix plan` now leave fields listed in `ownership.cede` (`kix.run/cede-fields`) with the controller that owns them when a conflict is inside a list item keyed by multiple fields, such as a Service port matched by `port` and `protocol`. Previously, they stopped with a field ownership conflict. Running Kix when neither the current directory (or `--flake` path) nor any parent directory contains `flake.nix` now reports that no Kix project was found and tells you to run from the directory containing `flake.nix` or pass `--flake <path>`.
