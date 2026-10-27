# 2026-10-27 · `kix/lib/rules/security.nix` · The container security rules never check a CronJob's pods.

`isWorkload` lists Deployment, StatefulSet, DaemonSet, and Job, and `getContainers` reads only `spec.template.spec`. So `security.nonRoot`, `noPrivileged`, `readOnlyRootfs`, and the other container rules pass a CronJob whose pods run as root or privileged. `kix/lib/helm-dag.nix` (`podSpecOf`) and `kix/lib/eval/pod-security.nix` (`podSpecOf`) each find a CronJob's pod spec; the rules could use one of them.
