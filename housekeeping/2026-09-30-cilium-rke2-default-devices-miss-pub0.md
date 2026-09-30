# 2026-09-30 · `cilium-rke2` `devices` · The default device list omits `pub0`, the name our NixOS nodes give the public NIC, so Cilium masquerades on `lo` only and pods get no internet egress.

The defaults are `lo eth0 eth1 vswitch failoverip cilium_bgp`. stage1 uses them and `cilium-dbg status` there shows `Masquerading: BPF [lo]`. lab1, configured outside this package, lists `pub0` and works.
