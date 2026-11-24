# 2026-11-23 · `kix/lib/helm.nix` · A Job from a Helm chart has no rerun rule, so a chart upgrade that changes it stops the deploy.

`scope.mkJob` puts `kix.run/rerun: on-change` on every Job a package builds, but `importChart` sends chart Jobs through `scope.mkHelmWorkload` (`kix/lib/helm.nix:599`, `kix/lib/scope/builders.nix`), which does not. A chart Job that keeps its name and changes its pod template, such as a new image on a chart upgrade, fails the apply because Kubernetes does not let a Job's pod template change. The deploy stops until someone deletes the Job by hand.

One fix: `mkResource` writes the marker on every object of kind Job, so `scope.mkJob` and chart Jobs share one owner and check 16 only has to keep it on Jobs. Chart Jobs then run again when their content changes, and the person who imports the chart cannot make them safe to repeat. It is a `silent` change for anyone who imports a chart with a Job. Another fix drops the annotation and lets the deploy decide from the kind alone. That changes the state Kix writes into a cluster, so the deploy must read the old form for six months.

Decision required from Adam: keep chart Jobs outside the rule, mark every Job in `mkResource`, or drop the annotation and decide from the kind.
