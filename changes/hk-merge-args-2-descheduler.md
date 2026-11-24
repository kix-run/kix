+++
kind = "error"
packages = ["experimental/descheduler"]
id = "K9425"
+++
Remove underscore spellings of reserved flags (using `_` in place of `-`, such as `--leader_elect=false` or `--policy_config_file=/x`) from `extraArgs` on `descheduler` instances. For `--policy_config_file`, `--descheduling_interval`, and `--disable_metrics`, set the `policy`, `deschedulingInterval`, and `metrics.enabled` options instead. The underscore spellings of `--leader-elect`, `--leader-elect-resource-name`, `--leader-elect-resource-namespace`, `--leader-elect-resource-lock`, `--secure-port`, and `--bind-address` have no option equivalent because the package configures leader election and the metrics listener itself. The descheduler treats `_` and `-` as the same character in flag names, so underscore spellings previously bypassed the package's check and overrode those settings. Passing an underscore spelling in `extraArgs` now stops the build with `[K9425]`.
