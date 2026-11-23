+++
kind = "fixed"
+++
The Kix operator now records a `RestartPending` Warning Event on the Activation
record when a resource is ready but still needs a restart, such as an `OnDelete`
DaemonSet with pods on the previous template. Previously, it recorded a normal
`ResourceReady` Event. When cleaning up a deleted Activation record's resources,
the operator also logs a warning naming any resource whose kind Kubernetes does
not recognize, instead of skipping it with no log message. `kix gc` rewords
its lines for a kind Kix never deletes and for a kind Kubernetes does not
recognize, and prints each at the object's place in the deletion order
instead of before the other lines.
