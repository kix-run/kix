+++
kind = "changed"
library = ["kix.fail", "scope.fail"]
cli = ["kix check -o json"]
+++
An error from the Kix library now names what to change in one of three fields, each in one form. `option` is a path in the instance's `config`, such as `tls.secretName`, the form that `kix pin set --option` takes. `dependency` is the name of one of the instance's `deps`. `clusterOption` is a path in the cluster definition, such as `cluster.domain`. `kix check -o json` carries the three fields, and its text shows each on a line of its own. `kix.fail` and `scope.fail` refuse an `option` that starts with `config.`, `deps.`, or `meta.`. Errors from the library now set `instance` in place of naming the instance at the start of the message.
