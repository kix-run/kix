# 08: Questions for Luca

## Decision 1: Attrsets vs Derivations in config.manifests

The capability interface makes `config.manifests` a terminal output — nothing
reads from it anymore. This reopens the original question: should manifests
be attrsets or derivations?

**If derivations**: We get `exportReferencesGraph` for free — native Nix
dependency tracking. `validateManifestSet` becomes unnecessary (Nix's DAG
structurally guarantees referential integrity). The phase boundary becomes
explicit (clear conversion point from attrsets to derivations).

**If attrsets**: We keep the current design. `_`-prefixed metadata survives
the module system and can carry dependency annotations stripped at
serialization. `validateManifestSet` remains as a safety net.

**If hybrid**: Capability interfaces work with attrsets during module
evaluation. After the fixpoint settles, a boundary function converts to
derivations for output. This gives structured access during evaluation AND
native dependency tracking at output. The boundary must be after the fixpoint
but before `mkManifests`.

**Question**: Given that capabilities handle all cross-module communication,
is there still a reason to keep attrsets in `config.manifests`? Or can we
go back to derivations and get dependency tracking for free?

## Decision 2: Bidirectional capability flow — same option or separate?

The capability interface has both input fields (chart writes `port`, `path`)
and output fields (implementation writes `labels`, `annotations`). Two options:

**Merged option** (NixOS style): Both sides write to the same submodule.
The module system merges them. Ergonomic, follows NixOS convention.

```nix
capabilities.monitoring.coredns = {
  # Chart writes:
  port = 9153;
  # Implementation writes (merged by module system):
  labels."kix.monitoring/scrape" = "true";
};
```

**Separate options**: Explicit `declare` and `provide` namespaces.

```nix
capabilities.monitoring.coredns.declare = { port = 9153; };
capabilities.monitoring.coredns.provide = { labels = ...; };
```

**Question**: Does the merged approach match your mental model? Or does
explicit separation of "what the chart says" vs "what the system tells the
chart" matter for clarity?

## Decision 3: Resource group combinators — in kixlib or in charts?

Resource group combinators like `withAutoscaler` could live in:

**kixlib** (generic, reusable):
```nix
kixlib.combinators.withAutoscaler = { ... }: group: ...;
```

**Chart-specific** (each chart defines its own pipeline):
```nix
# In coredns/resources.nix
withCorednsAutoscaler = group: group // { hpa = ...; };
```

**Question**: Should combinators be generic kixlib utilities (works for any
chart) or chart-specific functions? Generic is more reusable but might not
handle chart-specific nuances (like CoreDNS's cluster-proportional autoscaler
vs standard HPA).

## Decision 4: How much isolation between charts?

Three levels of chart isolation:

**Convention only** (current): Charts share one evalModules. `mkChartModule`
prefixes manifest names. Charts COULD read each other's config but shouldn't
by convention.

**Submodules**: Charts wrapped in `types.submoduleWith`. Each gets its own
option namespace. Can't accidentally read each other's internals. Cross-cutting
modules read exports at the outer level.

**Nested evalModules**: Each chart gets its own `evalModules`. Full hermetic
isolation. One-directional data flow (outer sets values, reads outputs).

**Question**: How much isolation do you actually want? Convention-based is
simplest. Submodules add type-system enforcement. Nested evalModules gives
true hermetic isolation but makes bidirectional capability flow harder.

## Decision 5: What do you want the dependency graph FOR?

V3 asked this and it's still the key question. Possible uses:

1. **Apply ordering**: `kubectl apply` in the right order. Static kind-based
   ordering covers 95%. Structural inference covers the rest.

2. **Selective apply**: "Deploy only coredns and its dependencies." Requires
   knowing the DAG.

3. **Impact analysis**: "What breaks if I change valkey?" Requires dependency
   edges between charts.

4. **Garbage collection**: "Delete resources no longer in the manifest set."
   Content hashes suffice (no DAG needed).

5. **Drift detection**: "What changed since last deploy?" Content hashes
   suffice.

6. **Cluster-level dependency management**: What does this mean concretely?
   The answer shapes the entire dependency tracking strategy.

**Question**: What's the concrete use case? "Apply ordering" has a simple
solution. "Cluster-level dependency management" could mean many things.

## Decision 6: Migration strategy

Two approaches:

**Big bang**: Redesign the architecture, rewrite monitoring + charts, update
all tests. Clean but high risk and lots of work.

**Incremental**: Start with capability monitoring (Phase A in
07-proposed-architecture.md). Prove the pattern works. Then add autoscaling,
network policy, etc. Each phase is independently testable and reviewable.

**Question**: Incremental is safer. But does the current architecture have
fundamental problems that make incremental migration harder (e.g., would we
need to support both monitoring.targets AND capabilities.monitoring during
the transition)?

## Decision 7: Does the registry become a capability?

The current `config.registry` is close to a capability interface — charts
declare endpoints, consumers read them. But it's not bidirectional (the
registry doesn't write back to charts).

Should the registry become a capability with output fields? For example:

```nix
capabilities.registry.valkey.primary = {
  # Input (chart declares):
  port = 6379;
  protocol = "redis";
  # Output (infrastructure module provides):
  host = "valkey-primary.prod.svc.cluster.local";
  # ^ computed from chart namespace + cluster domain
};
```

This would mean charts don't compute their own FQDNs — a registry
implementation module does it based on namespace + clusterDomain.

**Question**: Is this a useful simplification, or is it over-abstracting?
Charts currently compute FQDNs via `kixlib.mkFqdn`, which is simple and
works.

## Summary of Decisions Needed

| # | Decision | Impact | Default if undecided |
|---|---|---|---|
| 1 | Attrsets vs derivations | Architecture | Keep attrsets (current) |
| 2 | Merged vs separate capability options | API design | Merged (NixOS style) |
| 3 | Generic vs chart-specific combinators | kixlib scope | Generic in kixlib |
| 4 | Chart isolation level | Module structure | Convention (current) |
| 5 | Dependency graph use case | Tracking strategy | Apply ordering only |
| 6 | Migration strategy | Execution plan | Incremental |
| 7 | Registry as capability | Registry design | Keep current |
