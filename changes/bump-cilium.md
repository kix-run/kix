+++
kind = "silent"
packages = ["experimental/cilium"]
+++
`cilium` installs Cilium 1.20.5 instead of 1.19.10. The policies Kix writes work unchanged. Before you upgrade, check your own Cilium objects against Cilium's 1.20 upgrade notes. Cilium 1.20 removes Kafka-aware and proxylib rules, so remove `rules` sections with `kafka`, `l7`, or `l7proto` from your policies. An egress rule that combines `toServices` with `toPorts` now denies traffic until the Service exists and has backends. `CiliumNodeConfig` must use `cilium.io/v2`. To go back, deploy the previous Kix version: Cilium 1.19 reads the state 1.20 wrote.
