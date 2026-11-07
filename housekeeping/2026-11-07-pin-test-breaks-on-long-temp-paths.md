# 2026-11-07 · `cli/kix-cli/tests/pin_test.rs` · `rm_removes_package_and_instance_pins_and_reverts_version_to_1` fails when the temporary directory path is long.

miette wraps the error at a fixed width, and the message starts with the pins file path. Under `nix develop`, `TMPDIR` is `/tmp/nix-shell.XXXXXX/`, which pushes the line break into `'ns/app image'`, so the test's `contains("'ns/app image'")` misses. The same check passes with a shorter path, so the result depends on where the test runs.
