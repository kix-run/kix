# 2026-09-20 · stage1, stage2 · Cilium runs in policy audit mode, so a network policy deployed there is never enforced.

`kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.policy-audit-mode}'`
returns `true` on both test clusters. Every endpoint lists as
`Disabled (Audit)`, so a CiliumNetworkPolicy is evaluated and logged but
never blocks a packet. Anyone verifying policy work against these
clusters will see it pass whether the policy is right or wrong. The way
round it is per-endpoint and temporary:
`cilium-dbg endpoint config <id> PolicyAuditMode=Disabled`, which is how
the ingress-controller edge was checked on 2026-09-20. A cluster meant
to prove policy should turn audit mode off.
