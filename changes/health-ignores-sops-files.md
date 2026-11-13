+++
kind = "fixed"
+++
`kix health` no longer reports the SOPS file of a Secret as a missing object.
The `kix.run/depends-on` annotation of a Secret made from a SOPS file lists the
file, and health counted it as a missing resource named
`Unknown/(hash: ...)`. Every cluster that used SOPS then looked unhealthy, and
the command exited with 1.
