+++
kind = "fixed"
state = true
+++
`kix rollback --operator` now makes the earlier deployment record current again and supersedes the current one, as `kix rollback` does. Before, it pointed the current record at the earlier build, so `kix history` showed the earlier deploy twice. `kix deploy --operator` of the build that is already deployed now deploys it again and waits for the operator to finish. Before, it returned at once. In both cases the operator runs a failed Job marked `kix.run/rerun` again, as the direct commands do. Each `--operator` command writes a request to the deployment record (`spec.request`), and the operator records when it starts and finishes it (`status.startedRequest`, `status.finishedRequest`). Records without a request, including those written by direct deploys and earlier versions of Kix, behave as before. `kix rollback` now plans and runs like `kix deploy`: it shows drift from the deployed build and uses the same confirmation prompt and closing summary.
