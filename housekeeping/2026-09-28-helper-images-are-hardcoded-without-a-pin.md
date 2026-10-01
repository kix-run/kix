# 2026-09-28 · `kix/packages` · Init and helper containers in several hand-written packages hardcode an image string, so no pin or digest can reach them.

`grafana`, `immich`, `immich-machine-learning` and `vaultwarden` run
`docker.io/library/busybox:1.38.0` and `firezone` runs `busybox:1.36` in
init containers with no option behind them. `reflector` runs
`bitnamilegacy/kubectl:1.33` in a Job it renders beside its chart. `cdi`
and `kubevirt` build their operand image names from the operator's
`image.tag`. `grep -rn 'image = "' kix/packages` lists them.
