+++
kind = "fixed"
state = true
+++
`kix deploy --operator` now exits with the operator's reason when it redeploys the build that is already `Active` or `Degraded` and that run fails. Previously, the command waited 600 seconds and timed out. The Kix operator writes the request and the reason to the new `status.failedRequest` field on the Activation record and leaves `status.finishedRequest` unchanged, so an older Kix keeps waiting instead of reporting success. With an older operator, the command still times out.
