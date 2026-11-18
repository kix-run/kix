+++
kind = "fixed"
cli = ["kix rollback --output"]
+++
For changed objects, `kix status` now names another field manager in `changed since deploy` and adds `--force-conflicts` to `Next:` only for fields that Kix does not co-own. Previously, it also counted fields co-owned with Kix, even though those fields still hold what Kix applied and do not conflict on deploy. In `kix status -o json` and `-o yaml`, each `foreign_owners` entry now includes `unshared_paths`, listing the field paths Kix does not co-own. `kix rollback --help` no longer shows `-o` (`--output`), because `kix rollback` prints only text; passing `-o text` still works.
