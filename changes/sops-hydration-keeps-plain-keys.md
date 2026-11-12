+++
kind = "fixed"
+++
When `kix deploy` filled a Secret from a SOPS file, it dropped the keys that
the build had written in plain text in the same Secret. For example, a
database package's credentials Secret lost `username`, `database`, `host`,
and `port` and kept only `password`, so an application that read them failed.
Kix now keeps those keys and adds the SOPS keys to them.
