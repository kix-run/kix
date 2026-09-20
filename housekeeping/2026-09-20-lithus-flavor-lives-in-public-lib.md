# 2026-09-20 · `kix/lib/flavors/lithus.nix` · A Lithus-specific target preset ships inside the public kix library.

The flavor hardcodes one environment's stack (RKE2, external Cilium, OpenEBS LocalPV-ZFS and Mayastor) and reads `globals.<cluster>` for disk pools, next to generic flavors such as `kind.nix` and `talos.nix`. A reader of kix/lib meets an internal deployment by name. Moving it next to the clusters that use it is a file move plus flake wiring; whether Lithus is a first-party target kix ships or an internal preset is the decision to make first.
