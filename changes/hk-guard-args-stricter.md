+++
kind = "error"
packages = ["experimental/infisical-operator", "experimental/tempo"]
id = "K4740"
+++
`infisical-operator` now refuses its owned flags in `extraArgs` when they are written with one dash, such as `-leader-elect=false`, which it used to pass to the operator. `tempo` now refuses `-backend-scheduler.local-work-path` and `--backend-scheduler.local-work-path` in `extraArgs`, because they override `backend_scheduler.local_work_path`, which the package sets. The build stops with `[K4740]` and names the flag. Remove that flag from `extraArgs`.
