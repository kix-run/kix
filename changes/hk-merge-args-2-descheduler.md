+++
kind = "error"
packages = ["experimental/descheduler"]
id = "K9425"
+++
Remove underscore spellings of reserved flags (using `_` instead of `-`, such as `--leader_elect=false` or `--policy_config_file=/x`) from `extraArgs` on `descheduler` instances. The descheduler treats `_` and `-` as the same character in flag names, so underscore spellings previously bypassed the package's check and overrode settings the package manages. Passing an underscore spelling of a reserved flag in `extraArgs` now stops the build with `[K9425]`. For `--policy-config-file`, `--descheduling-interval`, and `--disable-metrics`, set the `policy`, `deschedulingInterval`, and `metrics.enabled` options instead. `--leader-elect`, `--leader-elect-resource-name`, `--leader-elect-resource-namespace`, `--leader-elect-resource-lock`, `--secure-port`, and `--bind-address` have no corresponding option because the package configures leader election and the metrics server itself.
