# 2026-10-01 · `kix/lib/meta.nix` · Package assertions and warnings are prefixed `[<instance>]` without the namespace.

`meta.nix:316,320` prefix each message from a package's `assertions` or
`warnings` with the instance name only, for example
`[descheduler] deschedulingInterval is "0s"; ...`. Two instances with the same
name in different namespaces give the same prefix, so the reader cannot tell
which one failed. Throws raised in a package's build, such as
`kix.guardArgs` errors, start `<package> <ns>/<instance>:`, so the two forms
also disagree.
