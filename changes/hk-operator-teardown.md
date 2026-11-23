+++
kind = "fixed"
+++
The Kix operator now records a `RestartPending` Warning Event on the
`Activation` record when a resource is ready but still needs a restart, such as
an `OnDelete` DaemonSet with pods still running the previous template.
Previously, it recorded a normal `ResourceReady` Event. When cleaning up a
deleted `Activation` record, the operator now logs a warning for any resource
whose kind Kubernetes does not recognize and logs each kept `Namespace` or
`CustomResourceDefinition`, instead of skipping them without a log message.
When `kix gc` tries to delete an object whose kind Kubernetes does not
recognize, its error message now notes that removing a
`CustomResourceDefinition` already deletes its objects and directs you to
`kix gc --full-scan`.
