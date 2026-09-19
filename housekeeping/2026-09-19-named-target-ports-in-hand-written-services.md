# 2026-09-19 · `kix/packages/` · 36 hand-written Service ports in 20 packages use a named `targetPort`, and cilium drops egress to a named port.

Verified on the harbor smoke cluster (cilium 1.19.6): a consumer's egress
rule with `port: "http"` drops every SYN, and the same rule with `"8080"`
passes. `kix.service.fromWorkload` now writes numbers, and the cilium
port translator warns on a name, but the warning only fires for a
Service that some pod dials. `grep -rn 'targetPort = "' kix/packages`
lists the rest; each needs the container port number instead.
