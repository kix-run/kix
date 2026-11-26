# 2026-11-25 · `cluster.capabilities.podSecurityEnforcement` · The option describes Pod Security Admission, and Autopilot enforces its own policy.

`gke-autopilot` sets `podSecurityEnforcement = "baseline"`. Google's documentation says Autopilot's admission policy includes every `baseline` rule and adds more, such as no writable `hostPath`. A workload that passes `baseline` can still be refused. The option has no way to say "baseline plus platform rules", so Kix's checks are looser than the platform.
