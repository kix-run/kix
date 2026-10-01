# 2026-10-01 · `kix/packages/cilium`, `kix/packages/cilium-external` · Both packages carry their own copy of `out.netpol.materializePlatformIntent`.

The function is about 40 lines and the two copies differ only in how they pick the CRD ref (`cilium` chooses between `cnpCrdRef` and `ccnpCrdRef`; `cilium-external` has only a CNP ref, so a clusterwide intent becomes a namespaced CNP). A fix to one copy will not reach the other. `cilium/netpol-rules.nix` already re-exports `cilium-external/netpol-rules.nix` for the same reason; the `out.netpol` binding belongs there too.
