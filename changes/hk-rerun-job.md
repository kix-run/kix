+++
kind = "silent"
library = ["scope.mkJob"]
+++
`scope.mkJob` now adds the `kix.run/rerun: on-change` annotation to every Job it builds, so a package no longer writes it. Before, a Job without the annotation stopped the deploy when its content changed, because Kubernetes does not let a Job's pod template change. If your own packages build a Job without the annotation, that Job runs once more on the first deploy after you upgrade, and again each time its content changes. Make sure each such Job gives the same result when it runs again. The Jobs in Kix's own packages already carried the annotation and do not change.
