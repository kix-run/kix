+++
kind = "error"
id = "K2377"
+++
Kix refuses to add a package that runs once per cluster, such as
`stackgres-operator`, beside the one package that needs it. Before, it added
the package there and warned. Removing that one package would have removed the
operator for the whole cluster. Declare the operator under `instances` in a
namespace of its own, or set `autoNamespace` to place every package Kix adds
there.
