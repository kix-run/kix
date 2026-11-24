+++
kind = "error"
packages = ["experimental/infisical-operator", "experimental/tempo"]
id = "K4740"
+++
Remove `-leader-elect`, `-health-probe-bind-address`, `-metrics-bind-address`, and `-metrics-secure` from `extraArgs` on `infisical-operator` instances, and remove `-backend-scheduler.local-work-path` and `--backend-scheduler.local-work-path` from `extraArgs` on `tempo` instances. `infisical-operator` sets those four flags itself and previously rejected only their `--` forms; it now rejects their single-dash forms too. `tempo` sets `backend_scheduler.local_work_path` in its config file and now rejects `-backend-scheduler.local-work-path` and `--backend-scheduler.local-work-path` in `extraArgs` so they cannot override that path. Setting any of these flags in `extraArgs` now stops the build and names the flag.
