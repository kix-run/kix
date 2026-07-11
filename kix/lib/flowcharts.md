# kix/lib data flow, explained

This is the *why*, not the file index (that's `architecture.md`). Almost
everything in the compiler is one trick reused: **Nix string context as a hidden
dependency channel.** Get that one idea and sealing, dependency discovery,
service edges, and network policies all fall out of it.

We follow a single example the whole way down: an **app Deployment that talks to
a Postgres Service**.

---

## 0. The one idea: string context

A string in Nix can secretly carry a set of store paths it was "built from."
You never see it. It survives concatenation, interpolation, and `toJSON`.

```
   what you see:      "postgres.db.svc.cluster.local"
   what tags along:   ⟨ needs /nix/store/ABC-k8s-Service-db-postgres ⟩
                      └──────────────── string context ──────────────┘

   getContext s              → reveals the hidden paths
   unsafeDiscardStringContext → strips them off
```

kix weaponises this: **every value a resource exposes through `out.*` is tagged
with that resource's own store path.** So the moment you *use* another resource's
name/address/selector, you are invisibly carrying a pointer to it. Hold onto
that — it is the entire game.

Since the typed-facts rework the channel carries TWO kinds of path:

```
   identity path   /nix/store/…-k8s-Service-db-postgres     the derivation record
                   "this value was computed from postgres"   → ordering, depends-on
   fact token      /nix/store/…-kix-fact-endpoint            a typed claim
                   content: {selector, ports, ns, name}      → netpol edges, DNS
```

A fact token is a tiny self-describing file (`readFile` it, no registry).
Address-shaped fields (`out.fqdn`, `out.url`, user outputs) carry both;
structural fields (`out.name`) carry identity only — *naming* a resource and
*dialing* it are different claims. Non-workload seals conduct absorbed facts
onward (a ConfigMap carrying postgres's fqdn hands the claim to whoever mounts
it); workloads terminate them (their pods dial). Facts are stripped before
sealing — they exist only at eval time, never in the store DAG.

---

## 1. Sealing: a manifest becomes an identity

"Sealing" = freezing a manifest (a mutable attrset) into an immutable file in
the Nix store. The file's path is a hash of its bytes, so the path *is* the
resource's permanent identity.

```
   mutable attrset                     frozen, content-addressed file
   ┌───────────────────┐    toFile     ┌────────────────────────────────────┐
   │ apiVersion: v1    │  ─────────▶   │ /nix/store/ABC-k8s-Service-db-...   │
   │ kind: Service     │   (SEAL 🔒)   │   {"apiVersion":"v1","kind":...}     │
   │ metadata,spec ... │               └────────────────────────────────────┘
   └───────────────────┘                              │
                                                      └─▶ this path = identity
```

Consequence that drives the whole design: **you cannot edit a sealed resource.**
One different byte → different hash → a *different* file, and every consumer that
already pointed at the old identity now dangles. So the rule becomes: *anything
that must be a dependency has to be decided before the seal.* (Sections 4–5.)

---

## 2. How a dependency is *discovered* (never declared)

Here's the handshake. Nobody writes "app depends on postgres." kix observes it,
because the app *used* postgres's address.

```
  STEP 1 ── postgres package seals its Service
     Service ──toFile──▶ /nix/store/P_svc-k8s-Service-db-postgres
                                   │
     out.fqdn = "postgres.db.svc.cluster.local"   ⟨ctx: P_svc⟩   ◀ tagged at birth

  STEP 2 ── app package uses that address (ordinary Nix, looks innocent)
     env = [ { name = "DB_HOST"; value = pg.out.fqdn; } ]
                                          │
                       "postgres.db.svc..."  still ⟨ctx: P_svc⟩

  STEP 3 ── app Deployment is sealed
     manifestJson = toJSON(deploy)                 ⟨ctx: P_svc⟩   ◀ rode along
     getContext(manifestJson)  ─▶  finds P_svc
     stamp:  metadata.annotations["kix.dev/depends-on"] = "hash(P_svc)"
                                          │
     Deployment now DAG-depends-on the Service. Nobody wired it.
```

The deploy-time CLI later walks this store-path DAG (rooted at the Activation CR)
to order rollouts. The graph was *derived from usage*, which is why mismatched
selectors and forgotten `dependsOn` simply can't happen — you either used the
thing (edge exists) or you didn't (no edge).

**Two doors into the seal.** Sometimes you need an ordering edge to something
whose address you never embed — "apply the CRD before the CR." That goes in
`requires`. But since its path isn't in your manifest text, the STEP-3 scan
wouldn't catch it. So `mkResource` *manually* folds those deps' context onto the
JSON right before `toFile`:

```
   (a) implicit edge  — you used dep.out.* → its path is already in context.   [free]
   (b) requires edge  — you didn't, but you need ordering → mkResource does
                        appendContext(json, dep-paths) before sealing.         [explicit]

   Both land as entries in kix.dev/depends-on. At deploy time an edge is an edge.
```

---

## 3. Where sealing lives in the manifest builder

`mkResource` (core/resource.nix) is just the two-doors logic wrapped around one
`toFile`:

```
   args ─▶ resolve namespace ─▶ build rawManifest (spec/data/labels + `extra`)
             │                          │
             │                          ├─ scan its context for /nix/store paths   ┐
             │                          │      → implicit dep hashes                │ door (a)
             │                          ├─ requires/extraDeps → "requires:HASH"     ┘ door (b)
             │                          │
             │                          ▼
             │                stamp kix.dev/depends-on = join(all hashes)
             │                          │
             │            appendContext(json, deps' own context)   ← so door (b) survives
             │                          ▼
             └──────────────────▶  🔒 toFile  =  outPath (identity)
                                        │
                          out.{name,fqdn,selector,ports,url}   each tagged ⟨ctx: outPath⟩
                                        (this is what makes STEP 1 above work)
```

`extra` has a guard: it may *not* set `spec`, `data`, `metadata.name/namespace`,
etc. — those go through dedicated args so kix can attach tracking. `extra` is
only for sibling fields kix doesn't manage.

---

## 4. Why workload dependencies get *spliced* (pre-seal assembly)

A plain resource is sealed once and done. A **workload** (Deployment/StatefulSet/
Job/DaemonSet) is special: cross-cutting layers (DNS ordering, network policies)
need to add dependencies to it. But per §1 you can't add a dep after the seal. So
every workload goes through one assembly line — `sealWorkload` — that layers
everything on, *then* seals exactly once.

```
   workloadInput (the raw Deployment the package wrote)
        │
        ▼
   ┌──────────────────── sealWorkload (the only pre-seal splice point) ─────────────────┐
   │                                                                                     │
   │  1. edges   = who does this workload talk to?      (scan its context — §6)          │
   │  2. dnsDeps = if edges ≠ [] → depend on the DNS provider's root   [CORE, always]    │
   │  3. interceptors (plugins, e.g. netpol) run → each returns extra `requires`         │
   │                                                                                     │
   │        requires  =  author's own  ++  interceptors'  ++  dnsDeps                     │
   │                     └──────────── spliced in THIS fixed order ───────────┘           │
   │                        (order is hashed into the output — it's a contract)          │
   └───────────────────────────────────────┬─────────────────────────────────────────────┘
                                            ▼
                                       🔒 SEAL once
                                            │
     Plugins may also want to EMIT sibling resources (the netpol CRs themselves),
     which are NOT dependencies of the workload. Those ride a sideband:
        workload._injectedResources = [...]
     drained later (§8), because they must not re-enter the fixpoint that is
     still busy building this very workload.
```

Two distinct return channels, and the distinction matters:
`requires` → *ordering* (lands in `depends-on`, earlier deploy wave);
`resources` → *emission* (extra manifests to ship, via the sideband).

---

## 5. Service edges: who-dials-whom, read back from facts

An "edge" is no longer inferred from identity presence — it is *stated* by the
endpoint fact riding the address the workload embedded:

```
   postgres Service seals →  out.fqdn ⟨ P_svc(identity), F_ep(fact) ⟩
                                          F_ep content: {selector, ports, ns, name}

   workload embeds the fqdn (directly, or via a ConfigMap that conducted it)
                                   │
       getContext(workload JSON) → filter kix-fact-* → readFile each
                                   ▼
   edges = [ { name, targetSelector, targetNamespace, ports, service? } ]

   Meaning captured: "app DIALS postgres" (not merely "app mentions postgres").
   Two independent consumers:
       • core   → order the pod after DNS (it needs name resolution to connect)
       • netpol → open a firewall path  app → postgres   (§7)
```

Identity hits keep three demoted roles: DNS ordering stays conservative
(naming is weak dial-evidence, an extra wait is harmless), helm workloads keep
identity-derived edges (the chart pipeline loses address values), and identity-
without-fact triggers the observed-vs-declared lint (`facts.refOnly` to
acknowledge a structural use). Same detection, computed once in `sealWorkload`,
shared. Core uses it even with netpol *off* (DNS ordering is unconditional).

---

## 6. Network policies: edges → firewall rules

Mental model: **default-deny everything, then punch exactly one hole per observed
edge — from both ends.** A CNI like Cilium needs *both* sides: the caller allowed
to egress AND the callee allowed to ingress. kix knows both ends of every edge,
so it writes both.

```
   Baseline per namespace:   DENY ALL  (ingress + egress)

   For the edge   app ──▶ postgres   kix writes a policy on EACH side:

     on the caller (app)                    on the callee (postgres)
     ┌──────────────────────┐               ┌──────────────────────────┐
     │ egress:              │               │ ingress:                 │
     │   allow → postgres   │               │   allow ← app            │
     │   allow → DNS (always)│               │   on postgres's ports    │
     └──────────────────────┘               └──────────────────────────┘
      "egress" policy, own ns                "caller-ingress" policy, written
                                              INTO postgres's namespace via
                                              emit.inNamespace(target)
```

**Why netpol needs three phases.** Different facts become knowable at different
times, and each policy is authored at the *earliest* phase where its inputs
exist:

```
   phase            earliest point that...            netpol writes there
   ───────────────  ────────────────────────────────  ──────────────────────────
   workload         one workload + its edges known     per-edge egress / ingress /
   (interceptor)    (inside sealWorkload, pre-seal)     caller-ingress policies

   instance         ALL of an instance's resources     supplements edges can't see:
   (processor)      exist together                      • SA is RoleBound → allow
                                                          egress to kube-apiserver
                                                        • LoadBalancer Svc present →
                                                          allow ingress from "world"

   cluster          ALL instances + namespaces exist    the default-deny walls
   (processor)                                          themselves; platform intents
                                                        (holes for non-kix pods like
                                                        CoreDNS, local-path)
```

The workload-phase policies must be *pre-seal* (they become `requires` on the
workload, so the pod won't roll out before its firewall exists). That's why
that phase is an interceptor inside `sealWorkload`, not an after-the-fact pass.

**Escape hatches baked in:** a `hostNetwork` pod gets *no* CNP (the CNI can't act
on host-network pods) and a warning instead. The enforcer itself is skipped for
its own policies (a firewall can't depend on itself booting).

---

## 7. Plugins attach through phases — netpol owns nothing in the core

netpol is a plugin. It never appears in `eval/` or `scope/`; it registers one
hook in each of the three phases above and reads a shared `ctx`. Any future
cross-cutting layer plugs in the same way.

```
        core pipeline                         netpol plugin (mkIf enable)
   ───────────────────────         ─────────────────────────────────────────────
   sealWorkload  ─── ctx ───▶  workloadInterceptor  → per-edge policies (requires+emit)
   instance eval ─── ctx ───▶  instanceProcessor    → apiserver / LB supplements (emit)
   cluster aggr. ─── ctx ───▶  clusterProcessor     → default-deny walls + a CHECK:
                                                        "enable=true but no enforcer
                                                         declared?" → hard error
```

The enforcer (Cilium) is found by asking for whoever claims the
`network-policy-enforcer` role (§9) — no explicit wiring. If none is declared
while policies are on, kix refuses at eval time, because a policy CR with no
store-path edge to the CNI would race the operator at apply time.

---

## 8. The three fixpoints (why not one)

Packages can mutually reference each other's config. Nix needs `lib.fix` to
resolve mutual references — but *one* big fixpoint would be too eager: building
instance A forces B forces A, and real graphs deadlock. kix splits into three
rings, each only reaching *down* to the settled layer beneath it.

```
   The problem:
       app.config wants  db.config.port
       db.config  wants  app.config.replicas      ← mutual → needs a fixpoint
   ...but resolve-everything-at-once forces whole resources too early.

   Split, cheapest layer first:

   ① config-only fixpoint   resolve just config VALUES. No resources built.
        │                   Breaks config ↔ config cycles cheaply.
        │  (configs are now plain data)
        ▼
   ② instance fixpoint      build each instance's resources. An instance may
        │                   reference another's out.* — safe, because configs
        │                   are already settled, so forcing a dep can't fall
        │                   back into ①.
        │  (within a single instance:)
        ▼
   ③ parts fixpoint         one instance's parts referencing each other
                            (service ↔ deployment). Local and small.

   Invariant: each ring reaches DOWN a layer, never sideways into its own
   half-built self. Then the workload sideband (§4) is drained AFTER ③, once
   the instance's parts are fully sealed.
```

---

## 9. Resolution = a linker

Dependency injection and roles are one concept: a **linker resolving symbols.**
A package has unfilled function args (holes); the resolver binds each to the one
instance that satisfies it. Ambiguity is a link error, never a silent pick.

```
   A package is like an object file with unresolved symbols:
       build = { db, dns, ... }: ...          ← "db", "dns" are holes

   Resolver ladder (DNS-like):
       explicit wiring given?              → use it
       else instances matching name/alias:
           managed beats imported             (a real deploy beats a mere reference)
           exactly one in my namespace?    → bind it
           else exactly one anywhere?      → bind it
           more than one?                  → LINK ERROR (ambiguous — declare it)
           none & arg optional?            → leave unbound
           none & required?                → LINK ERROR (undefined symbol)

   Roles are the same ladder for infrastructure symbols:
       meta.roles = [ "dns" ]     means  "I provide the dns role"
       a role name doubles as a DI alias, so the `dns` hole resolves to whoever
       claims the dns role. Two claimants (both managed, or a managed one against
       an environment-owned "exclusive" role) = LINK ERROR.
```

This is why §4's `dnsDeps` can find "the DNS root" with no wiring: `dns` is a
role, the role name is an alias, the alias resolves to CoreDNS's instance, and
its `root` resource is the thing every talking workload waits on.

---

## Putting it together — the example, end to end

```
   postgres pkg seals Service            →  P_svc, out.fqdn ⟨ctx: P_svc⟩          (§1)
        │
   app pkg uses pg.out.fqdn in an env    →  app manifest now carries ⟨P_svc⟩      (§0)
        │
   sealWorkload(app):                                                             (§4)
        edges = {P_svc} ∩ registry = [postgres]                                   (§5)
        dnsDeps = [coredns.root]      (talks to someone → needs DNS)              (§8/§9)
        netpol interceptor → app-egress→postgres CNP, postgres-ingress←app CNP    (§6)
        requires = author ++ [those CNPs] ++ [coredns.root]
        🔒 seal → app Deployment, depends-on = {P_svc, CNPs, coredns.root}        (§2)
        │
   instance phase → app's SA is RoleBound? add apiserver-egress CNP               (§6)
   cluster phase  → db & app namespaces each get a default-deny wall              (§6)
        │
   Activation CR roots the whole store DAG; CLI walks it to order the deploy.
```

Everything above is the same string-context observation applied at different
scopes: to a single resource (a dep edge), to a workload (a service edge), and
to the whole cluster (the deploy DAG).
