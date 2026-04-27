# 109: Service CIDR capacity check

**Status:** RFC / Draft
**Related:** `80_structured_diagnostics.md`, `95_netpol_build_time_validation.md`, `106_ops_lifecycle_verbs_and_capacity_check.md`, `archive/60_scorecard_rules_design.md`
**Supersedes:** —

## Problem

The `cluster.network.serviceCidr` option already exists in `kix/lib/modules.nix:407` (added with the cluster hardware profile work) but is currently inert — nothing reads it. Meanwhile every kix cluster compiles an arbitrary number of `Service` resources, each consuming one address from the kube-apiserver's `--service-cluster-ip-range`.

When a real cluster outgrows its service CIDR the failure mode is awful: the apiserver starts rejecting Service creations with `failed to allocate a serviceIP: range is full`. This is detectable at **eval time** — we know the CIDR, we know every Service in the activation closure — but kix doesn't currently check it. This is the network-side sibling of the build-time hardware capacity check sketched in doc 106 §1.2.

## Proposal

Promote `cluster.network.serviceCidr` from a passive label into an enforced budget, plus a `cluster.network.podCidr` capacity check on the same shape.

Concretely:

1. A scorecard rule (architecture severity) that runs over the assembled cluster manifest set:
   - Counts Service resources where `spec.clusterIP != "None"` and the type consumes a ClusterIP (`ClusterIP`, `NodePort`, `LoadBalancer`; **not** `ExternalName`, **not** headless).
   - Reserves a small fixed allotment for the apiserver's own `kubernetes.default` Service (1) plus any explicitly pre-pinned IPs declared on the cluster (e.g. CoreDNS).
   - Compares against the host count derivable from the CIDR prefix (`/24` → 254 usable, etc.).
2. **Severity gradient**, emitted via the doc 80 diagnostics pipeline:
   - `>= 100%` → **error** (fatal, blocks activation).
   - `>= warningThreshold` (default 80%) → **warning**.
   - Below threshold → silent (or `info` under `--verbose`).
3. Threshold is a cluster option: `cluster.network.serviceCidrWarnThreshold` (float 0..1, default 0.8). Same option for podCidr if/when we wire pod-IP counting.
4. **Skipped when `serviceCidr == null`** — preserves the GKE/EKS case where the operator doesn't know or care.

### Diagnostic shape (rides doc 80)

```
{ severity = "error";
  rule = "cluster.serviceCidrCapacity";
  message = "service CIDR 10.96.0.0/24 is full: 256 services declared, 254 addresses available";
  src = <activation root>;
  hints = [
    "increase cluster.network.serviceCidr prefix (e.g. /23 → 510 addresses)"
    "remove unused Service resources"
  ];
}
```

Warning variant identical with `severity = "warning"` and a `usage = 0.84` attribute for machine consumption (so `kix scorecard --json` and the operator UI can plot it).

## Why this shape

- **Reuses existing primitives.** No new module surface; the option already exists. No new diagnostic transport; doc 80 covers it. No new severity machinery; doc 60 / scorecard rules cover it.
- **Eval-time, not deploy-time.** Catches the failure before any apply. The apiserver-side error is post-hoc and per-Service; we want the holistic view.
- **Cluster-scoped, not package-scoped.** A package can't know whether its 12 Services will fit; only the cluster can. This is the right home.
- **Optional.** Most clusters won't set `serviceCidr`. The check no-ops for them; no new burden.

## Open questions

1. **Where does the rule live?** Default home is `kix/lib/rules/architecture.nix` to match existing patterns. But `interesting_thoughts/83b` argues for package-owned rules — the `cluster` "package" doesn't really exist yet, so architecture.nix wins for now.
2. **Counting semantics for headless Services.** `clusterIP: None` clearly excluded. But what about `clusterIPs: []` left to the apiserver? Treat as 1.
3. **Pre-allocated IPs (kube-dns, kubernetes.default).** Hardcode reservation of 2, or make it a list option `cluster.network.reservedServiceIPs`? Probably the latter — kubeadm's default is 2, k3s differs, kind differs.
4. **Dual-stack.** `serviceCidr` is a single string today. Promote to `listOf str` and check each family independently? Probably yes — defer to a follow-up; the v4 case alone catches 90% of real failures.
5. **Pod CIDR check.** Same shape, but counting pods is harder (replicas × deployments + DaemonSet × node count). Defer to follow-up doc; the math depends on `cluster.nodes` which is also partially-populated.
6. **Should the warning threshold be a scorecard severity config rather than a cluster option?** Doc 60's scorecard supports per-rule severity overrides. Reusing that machinery means no new option, but the semantics of "warn at 80%" don't fit the existing severity-override model (it's a numeric knob, not a severity). Cluster option is cleaner.
7. **Interaction with `kix history` / capacity drift (doc 106).** When a cluster grows over time, the warning is the early signal. Worth a one-line link from the diagnostic to the relevant `kix history` view? Probably yes once 106 lands.

## Alternatives considered

- **Runtime check via the operator** (poll apiserver for allocation stats). Rejected: too late, requires API access kix doesn't otherwise need, doesn't help in CI.
- **Static `maxServices` integer instead of CIDR.** Rejected: the CIDR is the source of truth on the cluster side; an integer is a footgun (forget to update it when you re-IP).
- **Lint-only (no fatal error).** Rejected: a full service CIDR is a hard outage. Fatal at 100% is correct.

## Migration

None required. The option already exists with `default = null`; existing clusters opt in by setting it. Flavor presets (kind, k3s) can ship sensible defaults (`10.96.0.0/12` for kubeadm, `10.43.0.0/16` for k3s).

## Implementation sketch

- New rule in `kix/lib/rules/architecture.nix` keyed `cluster.serviceCidrCapacity`.
- Helper in `kix/lib/k8s.nix` (or a new `kix/lib/cidr.nix`) that parses `a.b.c.d/N` and returns usable host count. Pure Nix; no IFD.
- Add `serviceCidrWarnThreshold` (and `reservedServiceIPs`) to `cluster.network` in `modules.nix`.
- Wire the rule into the existing scorecard run so `kix scorecard` and `kix build` both see it.
- Test fixture: a cluster flavor with `/29` (6 hosts) and 7 Services to trigger the error path; a `/29` with 5 Services for the warning path.
