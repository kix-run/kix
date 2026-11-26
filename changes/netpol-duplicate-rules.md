+++
kind = "changed"
+++
Generated workload network policies now deduplicate identical rules, such as when both a package intent and a cloud identity allow outbound traffic to `world` on TCP port 443. Allowed traffic does not change; the first deploy after upgrading re-applies any policy whose duplicate rules were removed.
