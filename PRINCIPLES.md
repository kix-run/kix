# Kix Principles

Durable tenets that guide design and decision-making. Not features, not a roadmap: the beliefs we fall back on when a call is ambiguous.

## The dependency graph is the model

1. **The dependency graph is the source of truth.** Wiring, ordering, RBAC, network policy, monitoring, and backup: everything is derived from the DAG or hooks into it. New features model themselves on the graph first; nothing lives beside it.
2. **The Nix store is the IR.** Closure-completeness, content-addressing, and reproducibility fall out of treating the store as a real intermediate representation, not a cache.
3. **Determinism is a feature, not a footnote.** Same inputs → same closure → same cluster. This is what makes blast radius provable instead of guessed.

## Compile-time correctness

4. **Forbid at compile-time what runtime would otherwise have to detect.** If the type system can rule it out, no admission webhook, no reconciler, and no runbook should need to. (Merges prevention-by-construction and build-time-over-reconciliation.)
5. **Make the invalid unrepresentable.** Eliminate the failure mode at the type level rather than guarding against it procedurally. Kix should make whole classes of K8s mistakes (mismatched selectors, dangling refs, and missing deps) literally unspellable.
6. **Every failure that *can* fail at compile-time *must* fail at compile-time, with an actionable reason.** Errors point at the source, name the constraint, and tell the user what to change. Silent failure and runtime-only discovery are bugs.

## Kubernetes compatibility

7. **Be a strict superset of Kubernetes, with escape hatches always available.** Our abstractions sit on top of K8s; they never prevent users from dropping down to raw resources. If someone needs a field, annotation, or kind we haven't modeled, they reach for it directly without leaving Kix. (Merges "don't invent new fields" and "real K8s resources over proprietary abstractions".)
8. **Standard K8s vocabulary over invented vocabulary.** Reuse K8s concepts (`IngressClass`, `loadBalancerClass`, and `StorageClass`) before introducing Kix-only ones.

## Personas and contracts

9. **Three personas, three contracts.** The **app maintainer** owns workload shape and declares what it needs. The **platform team** wires services and capabilities into clusters. The **cluster operator (SRE)** owns infra choices, hardware, and operational reality. Every API decides which persona it speaks to.
10. **Workloads are explicit; everything else is dependency-injected.** A package author is explicit about *what* they need (Postgres, not "a database"; this exact storage shape): that's the contract. *Which* implementation provides it is a DI concern resolved by the cluster, not the package.

## DSL design

11. **Automation over brevity.** DSL features exist to prevent mistakes, not to save lines. If a shorter form removes a safety net, the longer form wins.
12. **Resources are rich objects.** Consumers query the resource (`self.sa.out.name`, `out.selector`) instead of string-interpolating or calling helpers. The object knows its own derived properties.
13. **Wiring (DI) > module system > meta.** Reach for dependency injection first; fall back to the module system for shared structure; use `meta` last, only for Kix-concerns hints (statefulness, importance, and consistency class) that drive in-Kix auto-wiring of cross-cutting concerns. `meta` is never the channel for plumbing services together.
14. **Don't design for hypothetical futures.** Concrete drivers gate new primitives. Three similar lines beats a premature abstraction; "this might be useful one day" doesn't ship.

## Operational model

15. **Day-2 is where the value lives.** Day-1 deploys are table stakes. Upgrades, drift, restore, capacity, and migration are first-class, not afterthoughts.
16. **Compliance evidence is a build output, not a post-hoc scan.** SBOM, SLSA, SARIF, and attestations emerge from compilation because the graph already knows.
17. **Diff belongs in the planner, not the executor.** Plan, Transition, and Verdict primitives with structured readiness, not wall-clock timeouts and retries.

## AI and tooling

18. **AI is a multiplier on typed surfaces.** Agents compound on validated APIs and structured diagnostics; they hallucinate on YAML. We design APIs assuming an LLM will use them.
