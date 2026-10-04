# 2026-10-04 · `kix/packages/spegel` · No node has been seen to pull a layer from a peer.

`clusters/test-spegel.nix` deployed on a two-node kind cluster on 2026-10-04 with the containerd patch from its header, so the init container, the registry's security context, and the hostPort under Cilium all work. Nobody checked that the nodes find each other through `<name>-bootstrap` and serve layers. Deploy with `--keep`, pull one image on one node, then on the other, and read spegel's log for a peer hit.
