+++
kind = "silent"
library = ["scope.mkJob"]
+++
If your own packages use `scope.mkJob` without `kix.run/rerun: on-change`, make sure each Job is safe to run more than once before you deploy. Jobs in Kix's built-in packages already had this annotation and do not rerun on upgrade. `scope.mkJob` now adds `kix.run/rerun: on-change` to every Job it builds, so you can remove `annotations.${kix.keys.rerun}` from your own packages. Previously, changing a Job without this annotation failed during deploy because Kubernetes does not allow updating a Job's pod template. Any custom Job that lacked the annotation runs once on the first deploy after you upgrade. After that, Kix reruns it whenever its manifest changes, a Kix-built Secret or ConfigMap its pod reads changes, or its previous run failed.
