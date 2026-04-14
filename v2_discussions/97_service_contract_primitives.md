# 97: Sibling Context Markers (a.k.a. "Service Contracts")

**Status:** Design
**Related:** `96_netpol_autogeneration_blindspots.md`, `94_dns_dependency_chain_step2.md`, `65_passthrough_instances.md`, `29_compiler-design.md`, `archive/03_package_fixpoint_resources.md`

## TL;DR

The pattern that landed in `stackgres-cluster` and `stackgres-database` is subtler than "declare a service contract." It is a **sibling context marker**: a zero-manifest node in the Nix store DAG whose only job is to carry transitive store-path context into every `out.*` value consumers interpolate. When a consumer writes `database.out.host`, it doesn't know there's a bootstrap Job — but its Deployment's hash depends on the Job's hash, so wave ordering, netpol, and DNS edges all fall out of the Merkle graph automatically.

This doc is **not** about adding a typed contract surface. Doc 29 is explicit: the compiler's goal is *composition and proof*, not *introspection*. Adding `kind = "sql-database"`, `meta.provides = [...]`, and consumer-side `deps.database.contract = "..."` re-declares what the DAG already proves, creates a parallel vocabulary to maintain, and pulls us back toward the "track your own registers" model we rejected.

What the pattern actually needs is **DX cleanup**: hide `builtins.unsafeDiscardStringContext`, hide `scope.forNamespace`, and make the sibling-marker pattern the obvious way to wire an operator-managed or externally-created Service. The observable contract stays exactly what it is today — an `out` shape shape-compatible with `mkService.out`, indistinguishable to the consumer from a kix-managed Service. No tags, no registries, no typed lookups.

---

## 1. The mechanism, precisely

### 1.1 `attachCtx` — the novel primitive

The interesting primitive is not `mkServiceRef`. It's `attachCtx`, defined anywhere kix produces a resource output (`kix/lib/eval/scope.nix:1454`, `kix/lib/k8s.nix:322`):

```nix
resourceCtx = builtins.getContext "${marker}";
attachCtx   = value: builtins.appendContext (toString value) resourceCtx;
```

Nix's string context ordinarily piggybacks on interpolation: if you write `"${drv}/bin/foo"`, Nix records a dependency on `drv` because `drv`'s store path literally appears in the output string. `attachCtx` does something else — it **adds a store-path dependency to a value whose content has no natural relationship to that path**. The literal string `"5432"` has no business depending on anything. After `attachCtx "5432"`, it is a graph edge pointing at the marker.

This is what doc 29 §8.1 calls "automatic dependency tracking through string context," used in a non-obvious direction. Content-free literals — port numbers, FQDN strings the author knows by construction, hostnames the DNS system will resolve — become carriers of arbitrary graph closure. The consumer interpolates `out.port`, reads the string `"5432"`, and their manifest's hash now transitively includes whatever the marker's closure contained. The value is identical; the graph is not.

This is the primitive. Everything else in this doc is "how do we use it correctly and how do we stop package authors from losing it."

### 1.2 What a ServiceRef marker actually is

`scope.mkServiceRef` (`kix/lib/eval/scope.nix:1431`) wraps `attachCtx` with a specific **closure construction**:

- A `PackageInstance` import marker manifest (annotated `kix.dev/service-selector`, `kix.dev/service-ports`) — a real store path, gives `attachCtx` its `resourceCtx`.
- `extraRequires` on the marker — how the author enriches what's *in* that closure (e.g. a bootstrap Job).
- `out.{name, fqdn, port, selector, ports}` — plain values run through `attachCtx` so consumers reading them inherit the closure.

The deploy engine polls the referred-to real K8s Service for readiness; the netpol registry reads the annotations; the DNS injector reads the carried context. All three are downstream uses of the `attachCtx`-stamped values.

### 1.3 Chain extension vs. edge augmentation

These are different operations on the graph.

- **`requires`** *extends the chain.* A requires B, B requires C, so A transitively reaches C through B. Every hop is authored; every link has named endpoints. If A wants C in its closure, someone has to write a chain that reaches C.
- **`attachCtx`** *augments an existing edge.* The edge A → B was going to exist anyway (A uses B's value). `attachCtx` packs additional identities — C, D — into the *payload* of that edge. When A traverses it, A picks C and D up as passengers. A's chain never names C; A's graph still contains C.

Requires builds paths you walk. `attachCtx` loads cargo onto paths being walked anyway.

### 1.4 The immich / postgres / Job triangle

The motivating case is exactly where this distinction matters.

- **Immich wants a postgres service.** Edge: `immich → postgres`. Immich reads `postgres.out.fqdn`; its Deployment's hash depends on postgres's marker; when postgres is ready, immich can run.
- **A bootstrap Job must prep that postgres before immich can use it.** Creates the role, creates the logical database, grants privileges.
- **The Job is not immich's dependency.** Immich has no interest in the Job's existence as such. Immich's interest is "the postgres I'm about to talk to is usable." The Job is a prerequisite *of the edge*, not *of immich*.

What `requires` can't express: "immich depends on postgres, and that dependency transitively carries a Job." The chain it would build — `immich → Job → postgres` — is semantically wrong. Immich doesn't pass through the Job to get to postgres. The Job isn't between them; it's *on* their edge.

What `attachCtx` expresses exactly: take the existing `immich → postgres` edge, stamp the Job into its payload, and immich's closure picks up the Job when it traverses the edge. The graph says the right thing: immich consumes postgres, postgres's consumption-edge happens to carry a Job as a precondition. The `stackgres-database` package owns the edge decoration — it sits logically between consumer and producer, contributes a Job, and hands back a postgres-shaped value that knows it.

Today this is spelled, in `stackgres-database/default.nix:424`:

```nix
dbService = backendScope.mkServiceRef {
  name     = builtins.unsafeDiscardStringContext clusterName;
  selector = { app = "StackGresCluster"; ... };
  ports    = [{ port = "5432"; ... }];
  requires = [ bootstrapJob ];
};
```

Two things are happening:

**a) `requires = [ bootstrapJob ]` puts the Job into the new marker's closure.** That's how the marker's `resourceCtx` comes to contain the Job's store hash. (Note: this `requires` is *local* to the marker's closure, not a chain hop the consumer walks.)

**b) `attachCtx` on the marker's `out.{fqdn, port, ...}` projects that closure onto the values immich will read.** The edge-augmentation actually fires when immich interpolates `database.out.host`.

But notice what this call is *re-declaring*: the same selector and ports that `stackgres-cluster`'s own `postgresService` already declared. A new namespace facade, a new marker manifest, duplicate shape data — all of it scaffolding to get an `attachCtx` handle that can be stamped with the Job. The edge-augmentation is what the package actually wants; `mkServiceRef` is the only tool available, so the package pays full service-declaration cost for what should be a one-liner.

### 1.5 Why the previous framing is wrong

The earlier draft of this doc proposed wrapping `mkServiceRef` as `scope.provideService` with fields like `readyAfter`, `providedBy`, `kind = "sql-database"`, `protocol = "postgres"`, and a matching consumer-side `deps.database.contract = "sql-database"` check. That framing is wrong in three ways:

1. **"readyAfter" vs. "requires" is a renaming that hides the mechanism.** The whole point of `requires` in this call is that it is a **context-carrying edge**, not a readiness gate. Calling it `readyAfter` implies "deploy this after," which the kix deploy engine doesn't do for import markers — the marker lands in wave 0 and the consumer orders on the real Service's existence. The user doesn't need a new word; they need `unsafeDiscardStringContext` to disappear.

2. **`kind`/`protocol`/`meta.provides` are a parallel vocabulary.** The DAG already knows "immich connects to postgres" — the edge is `database.out.host`'s store-path context. Stamping `kix.dev/provides-kind = sql-database` on a marker so a scorecard rule can look up "all sql-database providers" is exactly the introspection-registry pattern doc 29 warns against. It adds a source of truth that must be kept in sync with reality. Reality is the graph.

3. **Consumer-side `deps.database.contract = "sql-database"` is type-checking a fact the graph already proves.** If immich writes `database.out.host` and the producer doesn't expose `host`, Nix's lazy eval fails at the point of reference with a direct error. Adding a build-time check that `dep.meta.provides` contains `"sql-database"` protects against a non-problem: swapping `postgres` for `redis` in DI without noticing. The swap fails immediately at `out.host` or `out.port` use. The "typed contract" catches nothing the structural use doesn't.

The correct framing: edge augmentation is the operation package authors are trying to perform, `attachCtx` is the primitive that does it, and `mkServiceRef` is currently the only public handle — so authors use it even for cases where they don't want to declare a new service.

---

## 2. What's actually bad (ergonomics, not architecture)

The sharpness comes from two places: `attachCtx` has no direct public handle, and the workaround (`mkServiceRef`) drags in footguns it doesn't need to.

**No direct way to augment an edge.** A package that wants to say "here, take postgres's value but with a Job stamped in" has to mint a fresh marker manifest, re-declare the same selector and ports the upstream already declared, live in a different namespace via `forNamespace`, and use the marker only as a place to hang the Job off. The edge-augmentation intent — the one thing the author cares about — is buried under service-declaration paperwork.

**`builtins.unsafeDiscardStringContext clusterName`** — 3 call sites in `stackgres-database`. Triggered by `builtins.toFile` inside `scopeMkResource`, which forbids store-path refs in its name argument. The author strips context to satisfy `toFile`, then must remember to re-attach the edge via `requires`. Forgetting silently drops the edge. Footgun.

**`scope.forNamespace postgresNamespace`** — required any time you emit a resource in a different namespace than your scope's. "Scope" is kix internal vocabulary. For a package whose only real business is "decorate the edge to postgres with a Job," this is plumbing that has nothing to do with intent.

**`requires = [ self.cluster ]` re-establishment** — the context stripped on line 288 has to be put back on line 293. Two correlated lines; silently wrong if only one is right.

**`postgres._meta.namespaceName`** — private-looking attribute, used wherever a backend-namespace resource is needed.

**`mkConnectionEnv` hand-rolled** — every sql-consuming package rebuilds this. Separate DX problem (split-secrets ergonomics), not about edges.

Observable symptom: the 100-line `build` block in `stackgres-database` is mostly scaffolding. The intent — "I contribute a Job to the edge between any consumer and this postgres" — is ~3 lines of it.

---

## 3. Proposal: an edge-augmentation primitive

Give `attachCtx`'s user-facing use case — "add passengers to an edge" — a direct handle. Keep `mkServiceRef` as the "I am the origin of a service edge" primitive. Stop overloading one for the other.

### 3.1 `scope.augmentEdge` (or `scope.stampOnto`, bikeshed)

The operation we want:

> Given a value produced by somebody else, hand my consumer back the same value with additional resources stamped into its graph context. My consumer reads the value, gets those resources in its closure.

A two-line library function:

```nix
# kix/lib/eval/scope.nix
augmentEdge = passengers: value:
  let extraCtx = lib.foldl' (acc: r: acc // builtins.getContext "${r}") {} passengers;
  in builtins.appendContext (toString value) extraCtx;
```

The consumer shape is unchanged — the value looks and serializes identically. The graph is different: reading it now pulls `passengers` into the reader's closure.

Helper to lift the whole `out` attrset in one call (the common case):

```nix
# Re-stamp every string field of an upstream's `out` with additional passengers.
augmentAllEdges = passengers: outAttrs:
  lib.mapAttrs (_: v:
    if builtins.isString v then scope.augmentEdge passengers v else v
  ) outAttrs;
```

### 3.2 What `stackgres-database` becomes

Drop the ServiceRef facade entirely. The upstream `postgres.out` is already `attachCtx`-stamped by `stackgres-cluster`'s own `postgresService` marker — it already carries the right selector/ports/fqdn/port to the netpol registry. All `stackgres-database` needs is to stamp `bootstrapJob` into the payload.

```nix
build = { self, config, postgres, scope, kix, ... }:
  let
    credentials  = scope.mkSecret { ... };                           # unchanged, consumer namespace
    backend      = scope.forService postgres;                         # see §3.3
    bootstrapPw  = backend.mkSecret { ... };                          # unchanged shape
    superuserRef = backend.mkSecretRef {
      name = postgres.out.name;                                       # see §3.4
      keys = [ "superuser-username" "superuser-password" ];
    };
    bootstrapJob = backend.mkJob { ... };                             # unchanged shape

    # The one line that expresses the intent: immich→postgres edge,
    # decorated with this package's Job.
    edge = scope.augmentAllEdges [ bootstrapJob ] postgres.out;
  in
  {
    inherit credentials bootstrapPw bootstrapJob superuserRef;
    root = {
      resource  = credentials;
      postHooks = [ bootstrapJob ];
      out = {
        host        = edge.fqdn;
        port        = edge.port;
        database    = config.database;
        username    = config.user;
        credentials = credentials;
      };
    };
  };
```

No new marker. No duplicated selector/ports. No `mkServiceRef` used for edge-augmentation purposes. The `augmentAllEdges` call *is* the package's contribution to the graph: "I sit in the edge from my consumer to postgres, and I contribute a Job." Immich, by reading `database.out.host`, picks up both postgres's marker (netpol, wave on the real Service) and the Job (wave, no readiness poll needed — the closure just says "deploy this alongside").

### 3.3 `scope.forService` — a namespace-bound subscope derived from a dep

Orthogonal footgun, same doc. `backendScope = scope.forNamespace postgres._meta.namespaceName` is plumbing. Replace with:

```nix
backend = scope.forService postgres;
# backend.mkSecret, backend.mkJob, backend.mkSecretRef, ... are all
# rooted at postgres's namespace.
```

Reads the dep's `_meta.namespaceName`, hands back a scope bound to it. Removes `forNamespace` and `_meta.namespaceName` from package-author surface. Both stay available for DI-plumbing.

### 3.4 `mkServiceRef` / `mkSecretRef` absorb the context dance

Today the `name` argument must be context-free because `builtins.toFile` (inside `scopeMkResource`) forbids store-path refs. Authors strip context and must remember to re-attach via `requires`. Change the primitives to accept context-carrying `name`, do the strip internally, preserve the edge in `requires` automatically.

```nix
# Before:
superuserRef = backend.mkSecretRef {
  name     = builtins.unsafeDiscardStringContext clusterName;
  keys     = [ "superuser-username" "superuser-password" ];
  requires = [ (if postgres ? raw then postgres.raw.cluster else postgres.root) ];
};

# After:
superuserRef = backend.mkSecretRef {
  name = clusterName;                                     # context picked up internally
  keys = [ "superuser-username" "superuser-password" ];
};
```

Deletes `unsafeDiscardStringContext` from every package call site. Same mechanism, the footgun is gone.

### 3.5 That's the whole API surface

Three additions:

- `scope.augmentEdge passengers value` / `scope.augmentAllEdges passengers out` — the missing public handle to `attachCtx` for the edge-augmentation case.
- `scope.forService dep` — namespace-bound subscope derived from a dep.
- `mkServiceRef` / `mkSecretRef` accept context-carrying `name`.

No `provideService`. No `kind`. No `protocol`. No `meta.provides`. No consumer-side `.contract = "..."`. Consumers still read `database.out.host` and get every downstream effect.

`mkServiceRef` retains its original purpose: "my package is the place in the graph that declares this service edge exists and points at that selector." `stackgres-cluster` uses it for the operator-managed postgres Service. Packages that wrap external services (e.g. a managed SaaS pretending to be in-cluster) use it. Packages that only want to *decorate* an edge that already exists — like `stackgres-database` — don't.

---

## 4. Shape unification between `mkService` and `mkServiceRef`

Today `mkService`'s `autoOut` exposes `selector` when present but not `ports`. `mkServiceRef` exposes both. Consumers of an operator-managed Service (via ServiceRef) get `out.ports`; consumers of a kix-managed Service don't — and there's no reason for the asymmetry.

Change: add `ports` to `mkService`'s `autoOut` (`kix/lib/k8s.nix:334`). Then producers can opaquely swap between "kix-managed Service" and "ServiceRef over operator-managed Service" without consumers noticing. This is the composition-is-the-contract property from doc 29 §7.1 stated concretely: the observable shape is the contract, the graph is the proof, there is nothing else to declare.

---

## 5. Validation falls out of the graph, not a registry

Doc 29 §7.4: *Make the error structurally impossible > detect at eval time > warn about unchecked territory.*

The typed-contract framing sits at tier 2. The sibling-marker mechanism, used correctly, sits at tier 1 — the error is impossible:

- **"Consumer forgot to add netpol edge."** Can't happen. If the consumer used `database.out.host`, the store context carries the marker; the netpol registry finds the selector; the edge is generated. If the consumer hand-rolled `"${name}.${ns}.svc"`, the context isn't there — and that's a different class of error (see §6), not something a `kind = "sql-database"` tag would prevent.

- **"Consumer's wave lands before the bootstrap Job."** Can't happen once the Job rides the edge via `augmentEdge`. The consumer's Deployment hash includes the Job's hash; the DAG orders after everything in the closure. No chain extension from consumer to Job — the Job is cargo on an edge the consumer already traverses.

- **"Producer exposes no port / wrong port."** Fails at `database.out.port` with Nix's direct missing-attribute error. No typed contract catches this earlier.

- **"Producer and operator labels drift."** Runtime-visible, operator-version-dependent, not solvable by a tag in Nix. Belongs in doc 96 (transitive detection / operator labels).

The one error class the mechanism *cannot* make impossible is §6.

---

## 6. The one class of warning worth emitting

**Plain-FQDN interpolation without context.** If a workload's rendered JSON contains a substring `<something>.<ns>.svc` whose origin has no store-path context (i.e. an author wrote `host = "${name}.${ns}.svc"` by hand instead of using `svc.out.fqdn`), the netpol system misses every edge. The build succeeds, the deploy succeeds, the runtime fails obscurely.

This is detectable structurally: walk every workload manifest, regex for `\.svc\b`, check whether the surrounding string carries context pointing at a known Service/ServiceRef marker. No context = warning. This pairs with doc 95 (netpol build-time validation) and is the only contract-layer lint actually worth adding — because it catches authors who bypassed the composition mechanism.

Emitted via doc 80's structured diagnostics with source attribution. One rule. No vocabulary.

---

## 7. `kix/lib/` changes, scoped narrowly

### 7.1 `kix/lib/eval/scope.nix`

- Add `scope.augmentEdge passengers value` and `scope.augmentAllEdges passengers outAttrs`. Two-line wrappers over `builtins.appendContext` + `builtins.getContext`. Public handle to the edge-augmentation use case of `attachCtx`.
- Add `scope.forService dep` — namespace-bound subscope derived from `dep._meta.namespaceName`. Thin wrapper over `scope.forNamespace`.
- `mkServiceRef` and `mkSecretRef`: accept context-carrying `name`; do the strip internally; preserve the edge in `requires` automatically. Delete `unsafeDiscardStringContext` from every package call site.

### 7.2 `kix/lib/k8s.nix`

- `mkService` `autoOut` (line 334): expose `ports` alongside `selector`. Unifies the producer shape with `mkServiceRef`.

### 7.3 `kix/lib/netpol.nix`, `kix/lib/meta.nix`

No change. The netpol registry already reads the ServiceRef annotations; the mechanism doesn't need enrichment. No `kind` tags, no typed `provides`.

### 7.4 `kix/lib/rules/`

- New rule: `fqdn-without-context`. Per-workload manifest walk; warn on `<name>.<ns>.svc` substrings lacking store-path context tying them to a known ServiceRef/Service. Implements §6.

### 7.5 Docs

- `cli/README.md`: one section, "Edges and edge augmentation." Covers:
  - What `attachCtx` does (content-free values become graph handles).
  - When to use `mkServiceRef` (you are the origin of a service edge).
  - When to use `augmentEdge` (you sit in the middle of someone else's edge and contribute passengers).
  - The immich/postgres/Job worked example.

  No new concepts introduced by the library changes themselves — just document the primitive and its two use cases clearly.

---

## 8. Adoption

Only two packages need touching to validate the cleanup:

| Package | Work |
|---|---|
| **stackgres-cluster** | Drop `unsafeDiscardStringContext` call sites (after §3.4 lands). Ensure `postgresService.out` exposes the full shape (`fqdn`, `port`, `name`, `selector`, `ports`) consumers should inherit. |
| **stackgres-database** | Delete the `mkServiceRef` facade entirely. Replace with `edge = scope.augmentAllEdges [ bootstrapJob ] postgres.out`; expose `edge.fqdn`, `edge.port` in `root.out`. Swap `scope.forNamespace postgres._meta.namespaceName` for `scope.forService postgres`. Drop `unsafeDiscardStringContext` call sites. Goes from ~100 lines to ~40. |

Everything else (`valkey`, `grafana`, `prometheus`, `alertmanager`, `harbor`, …) stays as it is. Their current `out.fqdn`/`out.serviceUrl` patterns already work because context flows through the Service. If they grow a bootstrap-Job-like readiness requirement, they adopt the same sibling-marker pattern; until then, there's nothing to migrate.

Explicitly **not** adopted: `meta.provides = [...]`, `deps.*.contract = "..."`, typed consumer checks, per-kind credential schemas. These are anti-goals per §1.4 and doc 29.

---

## 9. Relationship to other docs

- **96 (netpol blindspots):** The sibling-marker pattern is the tool for blindspot 2 (operator-managed workloads). `selector + ports` on a ServiceRef replaces hand-rolled CNPs. This doc is the ergonomic cleanup of the tool; 96 is the strategy for where to apply it.
- **65 (passthrough instances):** A passthrough is `mkServiceRef` with no local workload — the same primitive, same mechanism. No new surface needed; update 65 to reference `mkServiceRef` + `scope.forService` as the passthrough idiom.
- **94 (DNS dependency chain):** Runs off the same store-path context the marker carries. No change.
- **92 (declarative netpol intents):** Orthogonal; describes consumer-side reach. Meets the marker at the netpol builder.
- **95 (netpol build-time validation):** §6's `fqdn-without-context` rule is a slice of 95.
- **80 (structured diagnostics):** Destination for §6's warning.
- **29 (compiler design):** This doc is an application of §7.1–7.4: composition over declaration, proof from the graph, no parallel vocabularies, errors structurally impossible where possible.

---

## 10. What "just works" means here

A consumer writes:

```nix
env = kix.mkEnv {
  DB_HOST = database.out.host;
  DB_PORT = database.out.port;
} (database.out.credentials.out.mkEnv {
  DB_USER = "username";
  DB_PASS = "password";
});
```

And gets, without writing any further line:

1. **Env wiring** — the values themselves.
2. **Wave ordering** — the Deployment lands after the SGCluster *and* after the bootstrap Job, because both are in the forward closure of `database.out.host`'s context.
3. **Netpol egress** — a CNP permitting egress from the Deployment to the SGCluster pods on 5432, because the marker's selector/ports annotation is picked up by `mkServiceRefRegistry`.
4. **Netpol caller-ingress** — a CNP in the backend namespace permitting ingress from this Deployment to the SGCluster pods, same mechanism.
5. **DNS egress** — `extraDeps` populated with `dnsRoot`, via the same context walk.
6. **Readiness gate** — the deploy engine polls for the real K8s Service before the marker is Ready; the forward closure holds until the Job is Complete.

None of these six effects are declared by the consumer. All six are proved by the DAG. This is the property; everything else in this doc exists to stop package authors from accidentally breaking it.

---

## 11. Open questions

- **Does `mkServiceRef` absorbing context require `builtins.toFile` changes?** It shouldn't — we extract context, pass a stripped string to `toFile`, and re-attach via `requires`. But the exact code path through `scopeMkResource → mkImportMarker` needs verification; there may be a nested `toFile` that also complains.
- **Does `scope.forService` break when the dep is passthrough / external?** A dep with no `_meta.namespaceName` falls back to the current scope's namespace, or errors with a direct message. Preferred: error with "use `scope.forNamespace` explicitly for external services."
- **Should `fqdn-without-context` be an error or a warning?** Probably warning for the first release (existing packages may trip it), error once the tree is clean. Standard doc 95 progression.

---

## 12. Next steps

1. Land `scope.augmentEdge` / `scope.augmentAllEdges` (§3.1). Two-line primitive. Validate by rewriting `stackgres-database` to drop the ServiceRef facade and confirming the ludo cluster's build and netpol graph are byte-identical to today's.
2. Land `scope.forService` (§3.3). Port `stackgres-database`.
3. Land the `mkServiceRef` / `mkSecretRef` context-absorption (§3.4). Delete `unsafeDiscardStringContext` across `kix/packages/`.
4. Land §4 (`mkService.autoOut` exposes `ports`). Additive.
5. Spike §6 (`fqdn-without-context`) as a warning. Count hits across `kix/packages/`. Triage.
6. Archive this doc once the five items above ship.

No new vocabulary. No new tags. No new consumer-side declarations. `attachCtx` is the primitive; the fix is to give its real use case a real handle.
