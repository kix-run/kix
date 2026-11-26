+++
kind = "fixed"
cli = ["kix gc", "kix gc --full-scan"]
+++
`kix gc` and `kix gc --full-scan` no longer delete resources written by a deploy that failed, a `kix deploy --only` run, or a deploy that is queued or still running. Before, gc compared these resources against the active deployment's build alone, and deleted any resource that deploy had created or updated. gc now lists these resources under "Kept for an unfinished deploy", grouped by the deployment record that wrote them. Run `kix deploy <cluster>` to finish or replace that deploy, then run `kix gc` again.
