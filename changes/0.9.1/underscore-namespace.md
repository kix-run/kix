+++
kind = "fixed"
+++
An instance under a `_`-prefixed key, such as `instances._platform`, no longer makes Kix emit a Namespace with that name. Kubernetes refuses names that contain `_`, so the deploy failed.
