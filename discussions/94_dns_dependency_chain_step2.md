# 94: DNS Dependency Chain — Step 2

**Status:** Partial (step 1 rework landed, step 2 pending)
**Related:** `93_flavor_barrier_resource.md`, `archive/92_declarative_network_policy_intents.md`, `archive/83_netpol*`

## Context

Original step 1 injected DNS deps on **every** workload via a blanket `_implicitWorkloadDeps` mechanism. This was architecturally wrong — DNS is not a requirement of every resource. The netpol code already understood which Services a workload actually references via store-path context analysis. DNS deps should use the same detection.

## Step 1 rework (landed)

Moved DNS dep injection from blanket per-instance to per-workload detection, sharing the service-edge analysis with the netpol CNP generator.

**How it works:** `netpol.buildWorkloadCnps` always runs service-edge detection (via `extractServiceEdgesFromJson`), regardless of whether `networkPolicy.enable` is true. If a workload's store-path context references cross-instance Services, the DNS instance root is injected as an `extraDep`. CNPs are only generated when netpol is enabled — but DNS deps are unconditional.

**Key changes:**

| File | Change |
|------|--------|
| `kix/lib/netpol.nix` | `buildWorkloadCnps` always runs edge detection; returns `{ cnps; dnsDeps; }`. CNP generation gated on `networkPolicyEnforcer != null`. |
| `kix/lib/eval/scope.nix` | Replaced `dnsDeps` param / `_implicitWorkloadDeps` with `dnsRoot` param. `mkWorkload` and `mkHelmWorkload` always call `buildWorkloadCnps`, use both `cnps` and `dnsDeps` in `finalExtraDeps`. |
| `kix/lib/eval/instance.nix` | `_dnsDeps` (list) → `_dnsRoot` (single resource or null). Passed to scope as `dnsRoot`. |

**Why this is better:**

1. **Precise.** Only workloads that actually reference cross-instance Services get DNS deps. Infrastructure workloads (cilium, kind-system-netpol) that don't reference kix-managed Services are naturally excluded — no exemption guards needed.
2. **Consistent.** DNS detection reuses the same `extractServiceEdgesFromJson` mechanism as netpol CNP derivation. One analysis, two consumers.
3. **Simpler cycle story.** The cycle from the original design (cilium → `_dnsDeps` → platform-dns → kind-system-netpol → cilium) is naturally avoided: cilium's Helm workloads don't have kix store-path references to Services, so they never trigger DNS dep injection, so they never read `platform-dns.root`.

## Step 2 (pending): platform-dns → kind-system-netpol

The chain we want: `workload → platform-dns → kind-system-netpol → cilium CRDs`.

Step 1 gives us: workload → platform-dns (when the workload has service edges). Step 2 needs: platform-dns marker → kind-system-netpol root.

**The cycle risk is now much smaller.** With per-workload detection, the cycle path `platform-dns → kind-system-netpol → cilium → _dnsRoot → platform-dns` is only triggered if cilium's workloads have store-path refs to kix Services. They don't (Helm charts render with literal strings, not kix store-path references). But we should verify this holds and add a guard if it doesn't.

**Proposed mechanism: instance-level `extraDeps`.**

New option on the instance submodule. `evaluateImportInstance` reads it and splices into the marker resource's `extraDeps`. The flavor declares the dependency via `ref` (the lazy fixpoint handle):

```nix
# kind.nix
{ config, lib, kix, ref, ... }:
{
  instances.kube-system.platform-dns = {
    package = kix.mkImport {
      out = {
        name = "coredns";
        fqdn = "kube-dns.kube-system.svc.cluster.local";
      };
    };
    aliases = [ "dns" ];
    extraDeps = lib.optional config.networkPolicy.enable
      ref.kube-system.kind-system-netpol.root;
  };
}
```

Changes needed:

| File | Change |
|------|--------|
| `kix/lib/modules.nix` | Add `extraDeps` option (type: `listOf unspecified`, default `[]`) |
| `kix/lib/eval/import.nix` | `evaluateImportInstance` reads `instCfg.extraDeps` and passes to marker's `extraDeps` |
| `kix/lib/flavors/kind.nix` | Set `extraDeps` on platform-dns |

## Open questions

1. **Should `extraDeps` also work for regular (non-import) instances?** Could be useful for cluster authors to inject ad-hoc ordering edges. Low priority — solve the import case first.

2. **Interaction with PlatformBarrier (doc 93).** The barrier is a coarser complementary mechanism for ensuring all infrastructure deploys before user workloads. DNS chain gives fine-grained per-resource semantics. Both are valid and non-conflicting.
