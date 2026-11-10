+++
kind = "changed"
+++
Kix warns when it adds a package that runs once per cluster, such as `stackgres-operator`, beside the one package that needs it. Removing that package would remove the operator for the whole cluster. Declare the operator under `instances` in a namespace of its own, or set `autoNamespace`. Kix 0.10 will refuse this placement.
