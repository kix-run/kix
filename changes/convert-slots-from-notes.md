+++
kind = "fixed"
+++
When Kix first deploys a cluster whose deployment record has no package index, which Kix before 0.6 wrote, it now records each of that record's objects under the package instance that built it, read from the `kix.run/package` and `kix.run/package-namespace` annotations on the live object. Before, it recorded all of them at the cluster level, so what Kix read from that record had no package instances and no lifecycle. Programs that read it through the Kix library, such as `cluster::recorded`, saw every object at the cluster level. An object with no package annotation still goes to the cluster level.
