+++
kind = "fixed"
packages = ["experimental/cilium", "experimental/descheduler", "experimental/mayastor", "experimental/plausible", "experimental/rabbitmq-cluster", "experimental/spegel"]
library = ["scope.requireMetricsApi"]
+++
Kix now shows library and package warnings that it used to print only as Nix trace lines, which no command showed when the build succeeded. These include the warning for a custom resource that reads a Service address without saying how its controller uses it, the warning for a value in `secrets` or `crds` that is not a resource, and the warnings of `cilium`, `descheduler`, `mayastor`, `plausible`, `rabbitmq-cluster`, and `spegel`. `kix graph`, `kix list images`, and `kix list resources` show the library's warnings, as `kix build` does. A bundle carries its build's warnings, so `kix plan --bundle`, `kix deploy --bundle`, `kix diff --bundle`, and `kix graph --bundle` show them. `scope.requireMetricsApi` returns a list of warnings for a package to return from its `warnings`, and a package's `warnings` and `assertions` receive `clusterConfig`.
