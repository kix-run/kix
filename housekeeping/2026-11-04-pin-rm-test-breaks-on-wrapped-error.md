# 2026-11-04 · `cli/kix-cli/tests/commands_test.rs` · `pin_rm_removes_package_and_instance_pins_and_errors_when_missing` fails when the error message wraps.

The test checks that stderr contains `has no pin named`. The error names the pins file by its full path, and miette wraps the message to the terminal width. With a long temporary path, such as macOS's `/var/folders/...`, the line breaks between `has` and `no pin named`, so the check fails although the message is right. Seen on main at 9f35d2a4.
