+++
kind = "fixed"
state = true
+++
`kix deploy --operator` now exits with the failure reason when redeploying the current (`Active` or `Degraded`) build fails. Previously, it waited the full 600 seconds and timed out. Upgrade the Kix operator in your cluster to get this fix; against an older operator, the command still times out. On a failed redeploy, the operator writes the request token and failure reason to the new `status.failedRequest` field on the Activation record and leaves `status.finishedRequest` unchanged, so older versions of Kix keep waiting rather than reporting success.
