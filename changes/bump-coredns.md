+++
kind = "silent"
packages = ["experimental/coredns"]
+++
`coredns` runs CoreDNS 1.15.0 instead of 1.13.1. The default Corefile works unchanged. Since CoreDNS 1.14.7, the `forward` plugin stops trying after twice as many connection attempts as it has upstreams. Before, it kept trying until the query timed out. To keep the old behaviour, set `servers.default.plugins.forward.block = [ "max_concurrent 1000" "max_connect_attempts 0" ];`. If you added plugins to `servers`, check them before you upgrade: CoreDNS refuses to start on an unknown property inside a `ready` block (since 1.14.4), or on a regular expression longer than 10000 characters in `auto`, `errors`, `rewrite`, or `template` (since 1.14.0). CoreDNS keeps no data. To go back, set `image.tag` and `image.digest` to the 1.13.1 image, or deploy the previous Kix version.
