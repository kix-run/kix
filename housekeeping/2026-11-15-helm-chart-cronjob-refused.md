# 2026-11-15 · `kix/lib/helm.nix` · `importChart` refuses any chart that renders a CronJob.

`importChart` sends a chart's Deployments, StatefulSets, DaemonSets, and Jobs through `scope.mkHelmWorkload` and every other object through `scope.mkResource`. A CronJob takes the second route, and `scope.mkResource` refuses it:

```
infra/chart: CronJob 'cj' is built with scope.mkResource, which skips workload-specific processing ...
Fix: Build it with scope.mkCronJob instead (drop apiVersion and kind; keep the other attributes).
```

The person importing the chart cannot follow that advice, because the chart builds the CronJob. Reproduce it with a `readRender` stub that returns one CronJob, as `kix/lib/tests/units/helm-render.nix` does for other kinds.

The fix is for `mkHelmWorkload` (`kix/lib/scope/builders.nix`) to read the pod template through `core/pod-spec.nix` (`podTemplateOf`), so a CronJob's labels and pod spec under `spec.jobTemplate.spec.template` work, and for `helm.nix` to route every kind in `core/workload-kinds.nix` `builtKinds` there. A chart CronJob would then get the pod validators and network policies that a package's CronJob gets.
