# 2026-11-21 · `cli/kix-cli` · A command that evaluates nothing does not check that the right Kix runs.

In a project with a `[versions]` table, Kix picks the version for a cluster
before it parses its arguments (`cli/kix-cli/src/select.rs`). Nothing checks
that choice afterwards unless the command evaluates the project:
`prepare_evaluation` in `cli/kix-cli/src/dispatch.rs` compares the running
Kix with the cluster's library, and commands such as `kix rollback` and
`kix history` read deploy records only.

The scan and clap can disagree on which word is the cluster, and a
`KIX_SELECTED_BY` left in the environment skips the choice. Either way such
a command then runs on the Kix of the input `kix` for a cluster that
`[versions]` lists under another input.

A fix would compare the running Kix with the release the cluster's input
pins once clap has parsed the cluster, for every command that takes one,
and refuse when they differ.

Found by a review of kix#288 on 21 November 2026.
