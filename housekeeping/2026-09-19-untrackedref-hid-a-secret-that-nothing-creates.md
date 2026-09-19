# 2026-09-19 · `kix.untrackedRef` · An untracked reference says "something else creates this", and nothing checks that anything does.

The openebs etcd StatefulSet mounted `kix.untrackedRef
"<name>-etcd-jwt-token-custom"` with a comment saying the operator
creates it at runtime. Nothing creates it: the upstream chart generates
that Secret at install time. Every eval passed, and on kind the pods sat
in Init with "secret not found" until someone read the mount. An
untracked reference is the right tool for a Secret minted at runtime,
but there is no way to say who mints it, so a wrong claim lives forever.
A scorecard rule could at least list every untracked reference in a
build so a reviewer sees the claims in one place.
