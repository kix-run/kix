+++
kind = "error"
packages = ["experimental/descheduler"]
id = "K9425"
+++
`descheduler` now refuses a flag in `extraArgs` that spells a flag the package sets with `_` in place of `-`, such as `--leader_elect=false` or `--policy_config_file=/x`. The descheduler reads `_` and `-` in a flag name as the same character, so these spellings changed settings the package manages. Before, the check compared names as written and let them through. Setting one now stops the build with `[K9425]`. Remove these flags from `extraArgs`. For `--policy_config_file`, `--descheduling_interval`, and `--disable_metrics`, set the `policy`, `deschedulingInterval`, and `metrics.enabled` options instead. The package does not accept the underscore forms of `--leader-elect`, `--leader-elect-resource-name`, `--leader-elect-resource-namespace`, `--leader-elect-resource-lock`, `--secure-port`, or `--bind-address`.
