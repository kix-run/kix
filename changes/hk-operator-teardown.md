+++
kind = "fixed"
+++
The operator now records a Warning Event with reason `RestartPending` when a
deploy leaves a resource ready but its running workload still waits for a
restart, such as an `OnDelete` DaemonSet with pods on the previous template.
It used to record a plain `ResourceReady` Event. When the operator deletes
the objects of a deleted Activation and the cluster does not serve one of
their kinds, it now logs a warning that names the object instead of skipping
it with no log.
