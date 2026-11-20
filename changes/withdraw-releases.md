+++
kind = "added"
+++
A Kix release can now be withdrawn, for example when it has a bug that can damage a cluster. Kix, `kix upgrade`, and the install script never pick a withdrawn release. A project that names one exactly can still install it, with a warning, so that `kix upgrade --to <newer>` can move it off. When the Kix that runs was withdrawn, `kix deploy` and `kix rollback` refuse to change the cluster and name the release to use instead, and other commands print a warning. To deploy with a withdrawn release anyway, set `KIX_ALLOW_WITHDRAWN` to its version. The Activation record then gets the annotation `kix.run/withdrawn-kix`. Kix checks for a withdrawal at most once a day, and uses the index it fetched last when it cannot reach kix.run.
