# 2026-11-11 · `cli/` messages · Messages that report a bug in Kix cannot say where to report it.

Kix has no public issue tracker or support address, so internal-error
messages say "This is a bug in Kix" and ask for the output of the command
run with `-v`, but name no place to send it. The release-signature refusal
in `cli/kix/src/release/mod.rs` says "Report this at https://kix.run",
which has no reporting page either.
Decision required from Adam: where users report Kix bugs, so messages can name it.
