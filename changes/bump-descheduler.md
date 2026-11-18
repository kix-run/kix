+++
kind = "note"
packages = ["experimental/descheduler"]
+++
`descheduler` now runs upstream 0.37.0, up from 0.36.0. The policy format and the flags the package sets have not changed. The new release is built against Kubernetes 1.37 and fixes security issues in its Go dependencies. The first deploy after the upgrade restarts the descheduler pods once. You do not need to change anything.
