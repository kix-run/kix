# 2026-11-24 · `kix/packages/experimental/tempo/default.nix` · Tempo owns a misspelled backend scheduler flag.

`ownedFlags` lists `-backend-schedulerbackend-scheduler.local-work-path`, with the flag name written twice. Tempo's flag is `-backend-scheduler.local-work-path`, so `extraArgs` can set it and override `backend_scheduler.local_work_path`, which the package locks in `settings`.
