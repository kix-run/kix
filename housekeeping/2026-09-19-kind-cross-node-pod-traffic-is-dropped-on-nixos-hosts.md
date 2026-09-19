# 2026-09-19 · `scripts/kind-*.sh` · On a NixOS host with the firewall's reverse-path check on, pods on different kind nodes cannot reach each other, and nothing in the cluster says why.

Node-to-node traffic works and same-node pod traffic works, so the
failure looks like the application's fault: NATS logged "Waiting for
routing to be established" and every DNS lookup from a pod on another
node than CoreDNS timed out. The cause is the host: `bridge-nf-call-
iptables` sends bridged packets through the host's nftables, and the
`rpfilter` chain in `inet nixos-fw` drops a packet from 10.244.x.x
because the host has no route to a pod CIDR. `nft add rule inet nixos-fw
rpfilter-allow iifname "<kind bridge>" accept` fixed it for the session.
The multi-node scripts should say so in their header, or check for it.
