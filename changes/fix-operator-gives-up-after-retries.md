+++
kind = "silent"
state = true
+++
The Kix operator now stops retrying a deploy that keeps stopping at a failed resource, such as a SOPS file the operator pod cannot decrypt or a resource that never becomes ready. Before, it retried every 30 seconds forever and left the Activation record `Deploying`. Now it retries 10 times by default, then marks the record `Failed` with the number of attempts and the last failure, and `kix deploy --operator` exits with that reason. Set `KIX_DEPLOY_RETRIES` on the operator to change the number of retries, or to `0` to fail at the first failure, as `kix deploy` does. If you fix the cause after the record is `Failed`, run `kix deploy --operator` again. The operator counts attempts in the record's new `status.failedAttempts` field, so a restart does not reset the count, and `kix deploy --operator` prints a line for each failed attempt.
