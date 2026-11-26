+++
kind = "fixed"
+++
No changes are required. When `cluster.capabilities.privilegedContainers = false` (the default on the `gke-autopilot` and `openshift` flavors), the build error now explains that the cluster blocks both host access and privileged containers. It names the offending setting (`hostNetwork = true`, `hostPID = true`, the `hostPath` volume and path, or the container with `securityContext.privileged = true`) and gives a specific fix for it. Previously, the error did not name the privileged container or explain why `privilegedContainers` rejected host access, and every case gave the same generic fix.
