# 121: Netpol as a plugin — extraction mechanics and the core hook contract

**Status:** Draft (Design Doc)
**Related:** `119_core_surface_audit.md` (poses the question), `archive/92_declarative_network_policy_intents.md` (the enforcer interface this finishes neutralizing), `115_pod_spec_hardening_pass.md` (second consumer of the same hooks), `96_netpol_autogeneration_blindspots.md` (unchanged by extraction), `archive/83_netpol*.md` (design record of what moves)

Doc 119 rates netpol derivation **layer, not essence** and asks: does it ship in the
OSS core at all, or as a module? This doc answers the *how*: which Nix-level
mechanisms carry the extraction, what core must keep exposing, and — critically —
why the hook point cannot move from where it is today.

## 1. The three constraints that shape everything

Any design that ignores one of these is dead on arrival.

### 1a. Sealing: a post-pass cannot work

A resource's identity is fixed the moment `mkResource` runs. `k8s.nix` folds
`requires`/`extraDeps` context into the manifest JSON and then seals it:

```nix
# k8s.nix (~272–318, abridged)
depEntries = implicitEntries
  ++ map (dep: "requires:${extractStoreHash dep}") requiresResources
  ++ map (dep: "extra:${extractStoreHash dep}") extraResources;
# ... stamped into kix.dev/depends-on ...
manifestJsonWithDeps = builtins.appendContext manifestJsonStamped depContexts;
_identityPath = builtins.toFile "k8s-${kind}-${sanitizedNsKey}-${sanitizedName}" manifestJsonWithDeps;
```

After `builtins.toFile`, the workload's store path — the thing every consumer's
`out.name` reference carries as context, the thing the Activation closure walks —
is content-addressed over its dep list. You cannot add a CNP edge to a sealed
workload without producing a *different* resource, invalidating every reference
already handed out inside the `self` fixpoint. That is why doc 83 moved CNP
emission *into* `scope.mkDeployment`, before the seal:

```nix
# eval/scope.nix (~987–1014, abridged)
workloadDeps = netpol.buildWorkloadCnps {
  scope = scopeObj;
  workloadInput = baseArgs;          # pre-mkResource, context intact
  wSelector = selector;
  serviceRegistry = _netpolServiceRegistry;
  networkPolicyEnforcer = if _shouldGenerateCnps then networkPolicyEnforcer else null;
  # ...
};
netpolRequires = workloadDeps.cnps ++ workloadDeps.dnsDeps;
workload = scopeMkResource (baseArgs // {
  requires = (attrs.requires or [ ]) ++ netpolRequires;   # ← splice BEFORE toFile
});
```

The payoff of splicing pre-seal: the workload's store-path context transitively
includes its CNPs, so `kix deploy` places the CNPs in an **earlier wave** — no
window where the workload is ready but unpoliced. A "walk all resources after the
fixpoint and emit policies" plugin API loses exactly this property (the old
`processInstance`-only world), and a "rewrite the workload afterwards" API is
impossible under content addressing. **Conclusion: the plugin hook must fire at
the same pre-seal point inside `scope.mkWorkload` — extraction moves the code,
not the call site.**

### 1b. Fixpoints: what hook code may and may not force

The hook runs inside the instance's `parts = lib.fix (self: ...)` fixpoint, while
the workload it decorates *does not exist yet*. The data it receives is chosen to
be recursion-safe:

- `workloadInput` / `baseArgs` — a plain attrset; `builtins.toJSON` of it yields
  the string context that edge detection walks. Safe.
- `wSelector` — plain labels, deliberately *not* `workload.out.selector` (which
  would force the not-yet-existing resource). Same trick as `rawSelector`.
- `serviceRegistry` — built from `_depResourcesForNetpol`, i.e. resources of
  *other instances* resolved through the outer `clusterInstances` fixpoint
  (`instance.nix:165`). Lazy but settled by the time the first `mkDeployment`
  forces it.
- `networkPolicyEnforcer` — the enforcer instance's `out`, again from the outer
  fixpoint, nulled by two self-dep guards (`cluster.nix → isSelfEnforcer`,
  `instance.nix → _skipWorkloadNetpol`) so the enforcer's own workloads don't
  depend on their own CRD marker.

A hook contract must state these rules explicitly: **a hook may read the raw
workload input and anything reachable through DI deps or cluster config; it must
not reference the resource under construction, and resources it returns must not
close a cycle back into the current parts fixpoint.** These are the same
constraints package authors already navigate (`.name` vs `.out.name`,
`rawSelector`), now surfaced at the plugin layer.

### 1c. Wiring: who parents a CNP, and how it reaches the manifest set

Three separate edges hang off every emitted policy, and each uses a different
mechanism:

```nix
# 1. CNP → enforcer CRD → enforcer root: via the CRD ref marker.
#    cilium-external/netpol-rules.nix
mkPolicy = { crdRef, mkResource, extraArgs }:
  mkResource (crdRef.out.cr extraArgs);
#    crdRef.out.cr adds the marker to `requires` (k8s.nix:671), so
#    CNP → CRD marker → enforcer root falls out of DI transitively.

# 2. CNP → referenced Services: extraDeps, so the CNP waits for them.
#    netpol.nix:285
serviceDeps = map (e: e.service) edges;
egressCnp = enforcerApi.mkPolicy { ... extraArgs = { ... extraDeps = serviceDeps; }; };

# 3. Caller-side ingress CNPs live in the CALLEE's namespace but are
#    owned by the caller instance: parented via scope.forNamespace.
#    netpol.nix:333
targetScope = scope.forNamespace edge.targetNamespace;
... enforcerApi.mkPolicy { mkResource = targetScope.mkResource; ... };
```

And because `extraDeps`/`requires` fold into the *workload's identity* but not
into any parts attrset, the CNPs would never be serialized as YAML on their own.
The sideband exists for that:

```nix
# eval/scope.nix (~1037): attach on the workload
workload // { _generatedNetpol = workloadDeps.cnps; rawSelector = selector; }

# eval/instance.nix:363: drain after the parts fixpoint settles
_scopeEmittedNetpolCnps = builtins.concatMap (r: r._generatedNetpol or [ ]) _partResourcesFromParts;
allPartResources = _partResourcesFromParts ++ _scopeEmittedNetpolCnps;
```

A plugin API must preserve all four channels: requires-splice into the workload,
extraDeps on the emitted resource, cross-namespace parenting via `forNamespace`,
and the sideband drain into `allPartResources`.

## 2. Coupling inventory — what actually moves

| Site | Today | After extraction |
|---|---|---|
| `eval.nix:32` | imports `netpol.nix` + `netpol-interface.nix` unconditionally | imports a generic `hooks.nix`; netpol lib gone from core |
| `eval/scope.nix` ×3 (`mkWorkload` ~987, `mkJob` ~1115, helm path ~1185) | hardcoded `netpol.buildWorkloadCnps` | generic `runWorkloadInterceptors` (edge detection stays, see §3) |
| `eval/instance.nix:522` | `netpol.processInstance` | generic instance-processor hook |
| `eval/instance.nix:363` | `_generatedNetpol` drain | renamed `_injectedResources`, drained identically |
| `eval/cluster.nix:133–234` | enforcer lookup + `validateEnforcerInterface` | generic `findCapabilityProvider` + `validateProviderInterface` |
| `eval/cluster.nix:437–475` | `materializePlatformIntent`, `generateDefaultDeny` | generic cluster-processor hook |
| `modules.nix:555` | `networkPolicy` option submodule | declared by the plugin's module |
| `netpol.nix`, `netpol-interface.nix` | in `kix/lib` | move to the plugin (e.g. `kix-netpol` flake / `kix/lib/plugins/netpol/`) |

**What does *not* move — service-edge detection.** `buildWorkloadCnps` has two
consumers of the same analysis: DNS dep injection (unconditional, a platform
concern — doc 94) and CNP emission (conditional). The split runs *through* the
function. Core keeps `mkServiceRegistry`, `mkServiceRefRegistry`,
`extractServiceEdgesFromJson`, the `scope.mkServiceRef` annotation convention
(`kix.dev/service-selector` / `service-ports`), and the DNS-root injection.
Plugins receive `edges` precomputed — they never walk string context themselves.

## 3. The mechanism: hooks as module options

The module system is the delivery vehicle we already use (`kix.modules.monitoring`
proves the shape), and NixOS's own answer to "plugins inject behavior" is
list-typed options of functions (`nixpkgs.overlays`, `system.activationScripts`).
Core declares three hook options in `modules.nix`:

```nix
# modules.nix (new)
hooks = {
  workloadInterceptors = lib.mkOption {
    type = lib.types.listOf (lib.types.functionTo lib.types.attrs);
    default = [ ];
    description = ''
      Called inside scope.mkDeployment/StatefulSet/DaemonSet/Job (and the
      helm workload path) BEFORE builtins.toFile seals the workload.
      ctx → { requires ? [ ]; resources ? [ ]; warnings ? [ ]; }
      `requires` is spliced into the workload pre-seal (earlier-wave
      guarantee); `resources` ride the sideband into allPartResources.
    '';
  };
  instanceProcessors = lib.mkOption { … };   # the processInstance slot
  clusterProcessors  = lib.mkOption { … };   # the default-deny / platform-intent slot
};
```

The interceptor context — everything `buildWorkloadCnps` takes today, minus
netpol-specific naming, plus the precomputed edges:

```nix
ctx = {
  # workload (pre-seal — see §1b for what's safe to force)
  workloadInput, workloadKind, selector, hostNetwork,
  # analysis core already did
  edges,                    # [{ service, targetSelector, targetNamespace, ports }]
  # identity & environment
  instanceName, namespaceName, packageMeta,   # peeked meta → plugin does its own skip logic
  scope,                    # mkResource, forNamespace, labels, …
  cluster,                  # { config, findCapabilityProvider, … }
};
```

The netpol plugin then becomes an ordinary module — options and hook
registrations in one file:

```nix
# kix-netpol/module.nix
{ config, lib, kix, ... }:
let
  cfg = config.networkPolicy;
  netpol = import ./derive.nix { inherit lib; inherit (kix) k8s; };  # today's netpol.nix
in {
  options.networkPolicy = { enable = …; defaultDeny = …; directions = …; platformIntents = …; };

  config = lib.mkIf cfg.enable {
    hooks.workloadInterceptors = [
      (ctx:
        let
          enforcer = ctx.cluster.findCapabilityProvider "network-policy-enforcer";
          # self-dep guard moves INTO the plugin: skip the enforcer's own workloads
          isSelf = builtins.elem "network-policy-enforcer" (ctx.packageMeta.provides or [ ]);
        in
        if isSelf || ctx.hostNetwork then { }
        else {
          requires = netpol.buildCnps { inherit ctx enforcer; networkConfig = cfg; };
          resources = …;   # same list — sideband for serialization
        })
    ];
    hooks.instanceProcessors = [ (ctx: netpol.processInstance { … }) ];
    hooks.clusterProcessors  = [ (ctx: netpol.defaultDenyAndPlatformIntents { … }) ];
  };
}
```

And the import path back in is one line in the cluster definition:

```nix
# clusters/prod.nix
{ kix, packages }:
kix.buildCluster {
  modules = [
    kix.flavors.k3s
    inputs.kix-netpol.module            # ← the whole netpol feature
    {
      networkPolicy.enable = true;
      instances.kube-system.cilium = { package = inputs.kix-netpol.packages.cilium; };
    }
  ];
}
```

Core's side of `runWorkloadInterceptors` is small — it is today's call site with
the netpol name erased:

```nix
# eval/scope.nix (sketch)
hookResults = map (i: i {
  inherit workloadInput workloadKind selector hostNetwork edges
          instanceName namespaceName packageMeta;
  scope = scopeObj; cluster = clusterCtx;
}) workloadInterceptors;
injectedRequires = builtins.concatMap (r: r.requires or [ ]) hookResults;
workload = scopeMkResource (baseArgs // {
  requires = (attrs.requires or [ ]) ++ dnsDeps ++ injectedRequires;
}) // { _injectedResources = builtins.concatMap (r: r.resources or [ ]) hookResults; };
```

**Why hooks clear doc 119's grammar bar:** a hook option is grammar-adjacent (a
new way to create edges), which demands the highest justification. The
justification exists: doc 115's pod-hardening pass independently derived the same
two interception points (pre-seal workload merge, helm pre-wrap). Two confirmed
consumers on day one; monitoring auto-wiring (doc 101) is a plausible third.

## 4. Relationship to the existing override ladder

kix already has override mechanisms at three altitudes. The hooks slot in as a
fourth *kind* of mechanism, not a replacement — the distinction is **when in the
sealing lifecycle each one runs**:

| Level | Mechanism | Runs | Can it host netpol? |
|---|---|---|---|
| Package | build-list behaviors (`kix.expose`-style entries with own DI args); `meta.network.intents` | inside the author's build, opt-in per package | No — netpol must be cross-cutting and non-optional per workload. `meta.network.intents` **stays** as the package-level intent channel the plugin reads (`ctx.packageMeta.network.intents`). |
| Instance | `instCfg.partsOverlays` (signature `scope → self → base → attrset`, `instance.nix:265`); `config`, `deps.<x>.config` | after build entries merge, on the parts attrset — resources are **already sealed** | No — overlays add/remove/replace whole parts; they cannot splice a dep into an existing resource without re-minting it. Different altitude: overlays are attrset surgery, interceptors are pre-seal dep surgery. |
| Cluster | `globalPartsOverlays`, module options, flavors | module eval / post-fixpoint | Options yes (that's where `networkPolicy.*` lives); overlays no, same sealing reason. |
| **New** | `hooks.workloadInterceptors` | **inside `mkWorkload`, pre-`toFile`** | The only slot that satisfies §1a. |

Per-instance opt-out (the `_skipWorkloadNetpol` analog for user code) should ride
the existing instance schema rather than a new mechanism — e.g.
`instances.<ns>.<name>.skipHooks = [ "netpol" ]` threaded into `ctx`, mirroring
how `labelStyle`/`selectorLabels` already flow from `instCfg` into the scope.

## 5. Prerequisite repair: stop assembling Cilium specs in the orchestrator

Doc 119's finding 3, concretely: today the "neutral" orchestrator builds the
Cilium envelope itself and the interface leaks the backend name:

```nix
# netpol.nix:298 — this shape IS CiliumNetworkPolicy.spec
spec = { endpointSelector.matchLabels = wSelector; egress = egressRules; };

# netpol-interface.nix:67 — the "neutral" contract, verbatim
portsToCilium = "[svc-port] -> [enforcer-port-spec] — convert K8s Service ports";
```

Before (or during) extraction, spec assembly moves behind the enforcer API so the
orchestrator passes only neutral inputs:

```nix
# after: orchestrator side
enforcerApi.mkPolicy {
  mkResource = scope.mkResource;
  name = "${instanceName}-…-egress";
  subject = wSelector;                       # enforcer wraps: endpointSelector vs podSelector
  egress = egressRules; ingress = [ ];       # rules already enforcer-native (unchanged)
  extraDeps = serviceDeps;
};
# and: portsToCilium → portsToNative
```

This repair is worth doing even if extraction never lands — it is what makes
doc 92's "enforcer-agnostic" claim true, and it lets a native-NetworkPolicy or
Calico enforcer exist without forking the orchestrator.

## 6. What core keeps exposing (the contract, summarized)

1. **Edge analysis**: registries + per-workload `edges`, computed once, shared
   with DNS injection. Plugins never touch string context.
2. **The pre-seal splice**: `requires` injection before `toFile` — the
   earlier-wave guarantee. Only the sealant owner can offer this.
3. **Sideband drain** (`_injectedResources`) + cluster-level manifest
   contribution + the warnings channel (rides doc 80 diagnostics).
4. **Capability lookup + validation**: `findCapabilityProvider` (generalizes the
   `meta.provides` scan at `cluster.nix:148`, keeps the uniqueness throw) and
   `validateProviderInterface { capability, requiredAttrs, provider }`
   (generalizes `netpol-interface.nix:93` — reusable for backup engines, doc 108,
   and monitoring providers, doc 101).
5. **Cross-namespace parenting**: `scope.forNamespace` stays core (it already is).
6. **Fixpoint-safety rules** for hook authors, documented (§1b).

## 7. Alternatives considered

- **Enforcer-carried orchestrator** (the cilium package's `out` ships the hooks;
  zero-import UX). Rejected: derivation logic would live inside a package
  evaluated *within* the cluster it rewrites — the existing self-dep guards are
  the mild version of that problem and they'd multiply. Keep the split: package
  owns rule shapes, module owns orchestration.
- **Lib overlay (`kix.extend (final: prev: …)`)** replacing `mkScope`. Rejected:
  ordering-fragile and hands plugins the power to break the sealant invariants
  core exists to protect.
- **Post-fixpoint rewrite pass.** Impossible under content addressing (§1a).
- **Status quo (in-core behind `enable`).** Viable short-term, but it keeps
  Cilium-shaped code in the OSS core, contradicts the Ring 2 verdict, and blocks
  the doc 115 hardening pass from having a principled slot.

## 8. Migration order

1. Envelope repair (§5) — pure refactor, ships alone, no behavior change
   (ludo-kind diff must be empty).
2. Generalize lookup/validation into `findCapabilityProvider` /
   `validateProviderInterface`; netpol becomes their first caller.
3. Introduce the three hook options; rewire the three scope call sites +
   `processInstance` + cluster emission through them, with netpol registered
   from a core-internal module (`kix/lib/plugins/netpol/`). Sideband renamed.
   Ludo-kind diff still empty.
4. Move `networkPolicy.*` options into that module; `modules.nix` sheds them.
5. (When OSS packaging is real) lift `kix/lib/plugins/netpol/` + cilium packages
   into a separate flake. Steps 1–4 don't depend on this.

## 9. Open questions

- **Hook ordering and conflicts.** With netpol + hardening both registered, does
  interceptor order matter (hardening mutates the pod spec that netpol's edge
  detection JSON-serializes)? Proposal: interceptors that *transform*
  `workloadInput` are a different hook from interceptors that *append* deps;
  transforms run first. Needs a decision before doc 115 lands on the same slot.
- **Does `edges` computation stay unconditional?** DNS needs it, but if a cluster
  has neither netpol nor DNS injection, it's wasted work. Probably fine (lazy),
  but worth measuring on nw1.
- **Where do the two essence-policing scorecard rules go** (`selectorCoherence`,
  `fqdnWithoutContext`)? They guard core's edge mechanism, not netpol — they stay
  core even if promoted to always-on (doc 119 open question).
- **`skipHooks` naming/shape** at instance level — string keys imply hooks are
  named, which the option type above doesn't capture. Named-attrset instead of
  list (`hooks.workloadInterceptors.netpol = fn`) merges better and enables
  targeted disable; leaning that way.
- **Job/helm parity.** Three call sites today duplicate the splice logic; the
  hook refactor should collapse them into one `runWorkloadInterceptors` helper —
  verify the helm path's `_helmNetworkDeps` stripping survives the collapse.
