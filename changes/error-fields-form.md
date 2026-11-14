+++
kind = "changed"
library = ["kix.fail", "scope.fail"]
cli = ["kix check -o json"]
+++
An error from the Kix library now names what to change in `option`, `dependency`, or `clusterOption`. `option` is a path in the instance's `config`, such as `tls.secretName`, which is the form that `kix pin set --option` takes. `dependency` is a name in the instance's `deps`. `clusterOption` is a path in the cluster definition, such as `cluster.domain`. `kix check -o json` includes these three fields, and text output shows each on its own line. Kix leaves out an `option` that starts with `config.`, `deps.`, or `meta.`, and a `clusterOption` that starts with `instances.`, and says why in the message. Errors from the Kix library also set `instance` instead of putting the instance name at the start of `message`.
