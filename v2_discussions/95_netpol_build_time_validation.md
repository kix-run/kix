# 95: Network Policy Build-Time Validation

**Status:** Draft
**Related:** `92_declarative_network_policy_intents.md` (intent vocabulary), `94_dns_dependency_chain_step2.md` (DNS deps), `archive/83_netpol_via_crdref_and_scope_interception.md` (scope-level CNP emission)

## Problem

Network policies fail at runtime. A workload gets deployed, Cilium's default-deny blocks traffic it needs, and we debug from pod logs. The compiler already knows enough to catch most of these at eval time — it just doesn't check.

Three categories of silent failure today:

### 1. Intent vocabulary has no validation

Platform intents use string tokens like `to = "apiserver"`, `from = "all-pods"`. A typo (`to = "apiserve"`, `from = "all_pods"`) silently produces no rule — `translateIntentRules` in the Cilium enforcer just doesn't match it. The intent attrset structure itself is also unchecked: misspelled keys (`egres` instead of `egress`) are silently ignored.

### 2. Known connectivity needs with no policy

ingress-nginx is the poster child. The compiler knows:
- It has RBAC bindings (heuristic catches this → apiserver egress supplement)
- It has a LoadBalancer Service when `serviceType = "LoadBalancer"` (heuristic catches this → external ingress supplement)
- Its webhook jobs need apiserver access (heuristic catches this via SA binding walk)

But the compiler does NOT know / does not check:
- The controller needs to reach backend pods in other namespaces (discovered via store-path context for DI deps, but ingress-nginx's backends are dynamic — runtime Ingress resources, not compile-time refs)
- The admission webhook service needs ingress from the apiserver on port 443 (apiserver calls the webhook — this is the reverse direction from what the heuristic checks)

The second case is a real failure mode: with default-deny + ingress enforcement, the apiserver can't reach the webhook service, and all Ingress CREATE/UPDATE operations fail with timeout errors. The compiler could detect "this instance has a ValidatingWebhookConfiguration → the webhook service needs apiserver ingress" but currently doesn't.

### 3. Uncovered container ports

A workload declares `containerPort: 8443` but no ingress rule covers port 8443. The compiler sees every workload's ports and every ingress rule's port list. A diff between "exposed ports" and "ingress-covered ports" would surface missing rules at eval time.

## Design: Layered validation

### Layer 1: Intent schema validation (cheap, do first)

Validate the structure and vocabulary of every intent at eval time. This is pure type checking — no semantic analysis needed.

**A. Enum validation for rule targets:**

```nix
validEgressTargets = [ "apiserver" "world" "dns" ];
validIngressSources = [ "all-pods" "world" ];

# In translateIntentRules or a dedicated validator:
# if `to` is a string and not in validEgressTargets → eval error
# if `from` is a string and not in validIngressSources → eval error
```

Where to put this: in `netpol-interface.nix` as a `validateIntent` function that enforcer `translateIntentRules` calls (or that `materializePlatformIntent` calls before materialization). Centralizes the vocabulary so enforcers don't silently swallow unknown tokens.

**B. Structural validation for intent attrsets:**

```nix
validIntentKeys = [ "namespace" "targetNamespace" "scope" "podSelector" "egress" "ingress" ];
validRuleKeys = [ "to" "from" "ports" "raw" ];

# Unknown keys → eval error with suggestion
```

This catches `egres`, `pod_selector`, `ingresss` — all of which currently silently do nothing.

**C. Port spec validation:**

```nix
# Each port in `ports` must have `port` (int) and optionally `protocol` (enum: TCP/UDP/SCTP)
# port = "http" → error: "port must be an integer, got string"
```

### Layer 2: Heuristic gap detection (medium effort, high value)

Extend the existing heuristic detection in `processInstance` to cover more patterns and emit warnings (not errors) for suspected gaps.

**A. Webhook ingress detection:**

```
If instance has ValidatingWebhookConfiguration or MutatingWebhookConfiguration:
  → the webhook service needs ingress from kube-apiserver
  → check if any ingress rule covers the webhook service's port
  → if not: warning "webhook service '{name}' needs apiserver ingress on port {port} 
    — add a meta.network.intents entry or the apiserver will timeout calling the webhook"
```

This is the ingress-nginx fix. The compiler already walks all resources in `processInstance`; adding a webhook-service check is ~20 lines.

**B. Uncovered port detection:**

```
For each workload:
  exposed_ports = union of all container ports
  covered_ports = union of all ingress rules targeting this workload's selector
  uncovered = exposed_ports - covered_ports
  if uncovered != {}: 
    warning "workload '{name}' exposes port(s) {uncovered} with no ingress rule"
```

Caveat: many ports are internal (health checks, metrics) and don't need external ingress. Options:
- Only warn for ports that match a Service's targetPort (if a Service selects this workload and exposes the port, someone expects to reach it)
- Let packages suppress with `meta.network.suppressPortWarnings = [ 10254 ]`

Service-matched ports is the better default — it's already derivable from the instance's resource set.

**C. CRD controller detection:**

```
If instance has CRD resources AND a workload with RBAC:
  → likely a controller/operator
  → needs apiserver egress (already handled)
  → might need to create resources in other namespaces (not handled — but also not expressible as a static check)
```

This one is already partially covered by the SA binding walk. No additional work needed unless we want to warn about missing watch permissions.

### Layer 3: Cross-instance completeness (harder, maybe future)

**A. Missing caller-ingress for non-DI edges:**

When workload A calls service B but B is not a DI dep of A (e.g., ingress-nginx calling dynamic backends), the store-path context doesn't capture the edge, so no caller-ingress CNP is emitted. The compiler can't detect this statically — the connection is runtime-determined.

This is fundamentally the "ingress controller talks to backends" problem. Solutions:
- Package-level intent: `meta.network.intents.backend-ingress = { ingress = [{ from = "all-pods"; ports = [...]; }]; }` — the package author declares it
- Scorecard rule: "packages with `meta.provides = ["ingress"]` should declare backend ingress intents" — organizational enforcement
- Neither is build-time *detection*; both are build-time *declaration* that we can then validate is present

**B. Platform intent label verification:**

Platform intents target pods by label (`podSelector = { "k8s-app" = "kube-dns"; }`). Since these pods aren't kix-managed, we can't verify the labels exist. But we could:
- Maintain a registry of well-known platform pod labels per flavor (kind knows its CoreDNS labels, GKE knows its kube-dns labels)
- Cross-check flavor intents against the registry
- This is over-engineering for now. The intent structure validation (Layer 1) catches the structural bugs; label correctness is a flavor-authoring concern.

## Implementation plan

### Phase 1: Intent schema validation (Layer 1A + 1B + 1C)

Add to `netpol-interface.nix`:

```nix
validateIntentRule = { rule, direction, intentName }:
  # direction is "egress" or "ingress"
  # validates `to`/`from` tokens, `ports` structure, unknown keys
  ...;

validateIntent = { intent, intentName }:
  # validates top-level keys, calls validateIntentRule for each rule
  ...;
```

Call from:
- `materializePlatformIntent` (platform intents from flavors)
- `translateIntentRules` (package intents from `meta.network.intents`)

Estimated: ~60 lines in `netpol-interface.nix`, ~5 lines of call-site wiring.

### Phase 2: Webhook ingress detection (Layer 2A)

Add to `netpol.processInstance`:

```nix
webhookConfigs = builtins.filter (r:
  builtins.elem (r.kind or "") [
    "ValidatingWebhookConfiguration"
    "MutatingWebhookConfiguration"
  ]
) allPartResources;

# For each webhook, find the referenced service, check if apiserver ingress exists
```

Emit warning when no ingress covers the webhook service port. Package authors fix by adding `meta.network.intents`.

Estimated: ~30 lines in `netpol.nix`.

### Phase 3: Service-matched uncovered ports (Layer 2B)

Add to `netpol.processInstance`:

```nix
# For each workload, find Services selecting it, collect their ports,
# diff against ingress-rule-covered ports, warn on gaps.
```

This is the most broadly useful check but also the noisiest. Gate behind `networkPolicy.warnUncoveredPorts = true` initially.

Estimated: ~40 lines in `netpol.nix`.

### Deferred: Layer 3

Cross-instance completeness and platform label verification are deferred. The ROI is low compared to Layers 1-2, and Layer 3A (non-DI edges) is fundamentally a declaration problem, not a detection problem.

## Open questions

1. **Warnings vs errors for Layer 1?** Typos in intent vocabulary (`to = "apiserve"`) are almost certainly bugs — should these be eval errors (hard fail) or warnings? Leaning errors: if you declared an intent, you want it to work.

2. **Should Layer 2 warnings be scorecard rules instead?** Scorecard rules have severity levels, can be suppressed per-instance, and have structured output. The webhook/port checks fit the pattern. Counter-argument: these are netpol-specific and tightly coupled to `processInstance` — splitting them into scorecard rules adds indirection for no user benefit.

3. **How does this interact with `directions` config?** If `directions = "egress"`, ingress checks (webhook, uncovered ports) should be skipped. Already respected by `processInstance` — new checks should follow the same pattern.

4. **Package-level intent suppression.** Some packages legitimately have uncovered ports (metrics endpoints consumed by Prometheus, which has its own scrape-level netpol). Need a clean suppression mechanism — `meta.network.suppressPortWarnings` or per-port annotations on the intent.
