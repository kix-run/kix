+++
kind = "fixed"
cli = ["kix gc", "kix gc --full-scan"]
+++
`kix gc` and `kix gc --full-scan` no longer delete resources written by a failed deploy, a `kix deploy --only` run, or a deploy that is queued or still running. Previously, `kix gc` compared cluster objects only against the active deployment's build and could delete resources that an unfinished deploy had created or updated. `kix gc` now keeps those resources and lists them under "Kept for an unfinished deploy", grouped by deployment record. To clean them up, run `kix deploy <cluster>` to finish or replace the unfinished deploy, then run `kix gc <cluster>` again.
