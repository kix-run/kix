+++
kind = "changed"
+++
When the Kix operator gets SIGTERM, such as when Kubernetes stops its pod, it now cancels the deploy it is running at the next step and starts no new one, and then exits. The Activation record stays `Deploying`, and the operator resumes it when it starts again.
