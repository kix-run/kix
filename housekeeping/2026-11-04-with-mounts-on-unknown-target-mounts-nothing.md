# 2026-11-04 · `kix/lib/vocab/mounts.nix` · `kix.withMountsOn` with a container name that matches nothing mounts nothing and says nothing.

`_injectMounts` maps over `containers` and injects only where `c.name == targetName`. A typo in the target name, or a name that belongs to an init container, leaves every container untouched. The pod still gets the volume, so the build passes and the mistake shows up only when the workload runs without its files. There are no unit tests for `withMounts` or `withMountsOn` in `kix/lib/tests/units/`.
