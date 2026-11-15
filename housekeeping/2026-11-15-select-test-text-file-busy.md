# 2026-11-15 · `cli/kix-cli/tests/select_test.rs` · `self_upgrade_installs_the_newest_release_and_moves_the_link` fails now and then with "Text file busy".

Under a full `cargo test --workspace`, the test once failed at `stdout_of` (line 102) with `ExecutableFileBusy` (ETXTBSY): it runs a program file that another thread still holds open for writing. It passed on the next three runs of the target alone. A likely cause is a file that one test thread wrote and runs while another thread forks, so the child inherits the open write handle. It costs a red CI run now and then.
