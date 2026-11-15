+++
kind = "changed"
+++
When the Kix operator receives `SIGTERM` (such as when Kubernetes stops its pod) or `Ctrl-C`, it now cancels any running deploy, starts no new ones, and exits. An interrupted deploy leaves its Activation record `Deploying`, and the operator resumes it when it starts again.
