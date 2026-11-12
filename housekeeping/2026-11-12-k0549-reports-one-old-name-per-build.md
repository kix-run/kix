# 2026-11-12 · `kix/packages/was-stable.nix` · `[K0549]` names one old package name per build, so a migration takes one build per name.

Moving the Lithus monorepo to 0.10.0-rc.1 took 14 runs of `kix check`, each failing on the next name (`cert-manager`, `cluster-issuer`, `clickhouse-operator`, ...). Each name throws when it is read, so evaluation stops at the first. A user with a slower build or more clusters pays this many times over.
