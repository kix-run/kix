+++
kind = "silent"
library = ["scope.mkJob"]
+++
If your own packages build Jobs with `scope.mkJob` without `kix.run/rerun: on-change`, make sure each Job is safe to run more than once before you deploy. `scope.mkJob` now adds `kix.run/rerun: on-change` to every Job automatically, so any Job that lacked this annotation runs once on the first deploy after you upgrade. Kix's built-in packages already set this annotation, so their Jobs do not rerun on upgrade. On later deploys, Kix deletes and recreates a Job when its manifest changes, when a Kix-built Secret or ConfigMap read by its pod changes, or when its last run failed. Previously, changing a Job without this annotation failed during deploy because Kubernetes rejects edits to a Job's pod template. If your own packages set `annotations.${kix.keys.rerun}`, you can remove that line.
