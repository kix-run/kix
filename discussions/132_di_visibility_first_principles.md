# 132: DI visibility, from first principles

**Status:** RFC/Draft
**Related:** `129_scaling_axes_fleet_and_linking.md` (contract artifact, activation slicing), `131_fact_kinds_and_operand_attribution.md` (facts channel), `45_multi_team_and_operator_models.md`, `55_shared_resource_ownership.md`, `117_self_service_platform_interface.md`, `archive/01_evaluateCluster_merging.md` (origin of the cluster-wide reach)

The question: which instances should be able to *find* each other through auto-resolution, and how should that boundary relate to the boundaries K8s already has (DNS scope, netpol wall, secret readability)? Grounded in `kix/lib/eval/resolve.nix`, `eval/roles.nix`, `eval/hooks.nix`, `eval/instance.nix` (`_crossNsCheck`), `core/facts.nix`, and `kix/lib/flowcharts.md` §9.

## 1. Current behavior, precisely

The ladder in `resolve.nix` (`resolveArg`):

1. explicit wiring given: use it, no further checks
2. among name/alias matches, managed instances shadow imports
3. exactly one match in the requester's namespace: bind
4. more than one in-namespace: error (ambiguous)
5. none in-namespace, exactly one **anywhere in the cluster**: bind, silently
6. more than one elsewhere: error (ambiguous, "specify explicitly")
7. none and optional: unbound; none and required: error

Three facts about the surrounding machinery matter:

- **Roles ride rung 5.** `meta.effectiveAliases` (`kix/lib/meta.nix:95`) prepends `meta.roles` to an instance's aliases, so a `dns` hole resolves through the *same* byKey ladder as a `db` hole. CoreDNS in `kube-system` is found by an app in `immich` only because of the cluster-wide fallback. The separate `findRoleProvider` machinery (strong/weak symbols, exclusive env bindings, eager duplicate refusal) exists beside this, but day-to-day role *resolution* is just rung 5.
- **`meta.scope = "namespace"` is a package-level opt-out**, checked in `instance.nix` `_crossNsCheck`: a cross-namespace binding of a namespace-scoped package throws. Four packages use it (secret, secret-ref, persistent-volume-claim, stackgres-database), all for intrinsic K8s reasons (the thing produced is only consumable from its own namespace).
- **`_crossNsCheck` does not see explicit wiring.** `resolvedDepMeta` filters out `direct` resolutions (`instance.nix:199`), so an explicitly wired cross-namespace secret compiles and fails at runtime instead of at eval.

And one fact about what resolution *means*: a resolved dep whose address flows into a workload opens real holes. The typed-facts channel (`core/facts.nix`) makes `db.out.fqdn` carry an endpoint fact; termination at the workload seal turns it into an egress CNP, a provider-side ingress CNP, and a DNS readiness dep (`flowcharts.md` §5-§6). Resolution is not lookup metadata; it is connectivity.

The canonical cluster depends on rung 5. In `ludo/services.nix`, `immich.immich-db` (a `stackgres-database` facade in the `immich` namespace) binds `data.postgres` through its `postgres` alias, cross-namespace, via the fallback. The facade itself is then bound same-namespace by `immich.immich` through the `database` alias. So the pattern is already two-tier: shared backend found cluster-wide, per-app facade found locally.

## 2. Principles

**P1: Resolution scope mirrors runtime addressability.** A symbol should be findable at the scope where the thing it names is addressable. K8s DNS is the reference model, and it is stricter than kix: a pod's search path resolves the bare name `postgres` only in its own namespace; reaching another namespace requires the qualified form `postgres.data`. There is no "bare name, unique anywhere" rung in DNS, ever, and for good reason: it would make name resolution a function of the global census. The ladder's rung 5 is the rung DNS deliberately does not have. The linker world learned the same lesson in reverse: ELF defaulted every symbol to exported, and twenty years of `-fvisibility=hidden` retrofits followed. Meanwhile cluster-singular capabilities (one CNI, one resolv.conf, one default StorageClass) are genuinely global at runtime, so cluster-global role symbols are *correct*, not an exception to the principle.

**P2: Locality. A namespace's compile output is a function of its own declarations plus explicitly exported or imported symbols.** Rung 5 violates this with a worse case than the postgres one: an *optional* dep. Team A's app declares an optional `cache`; none exists, it runs cacheless. Team B adds `teamB.cache` for themselves. Team A's next build silently binds it, opens an egress hole into team B's namespace, adds a DNS dep, and injects team A's dep-config into team B's instance (`buildConfigInjections` follows resolution too). Nothing in team A's files changed. Refusing with an error when a boundary is reached is acceptable; silently rewiring is not. Note this is not only a multi-tenancy problem: single-team clusters get the same spooky action when a second postgres appears.

**P3: Visibility is granted by the definer, in two layers with two owners.** *Intrinsic* visibility is a property of K8s mechanics and belongs to the package author: a Secret cannot be read cross-namespace, so `meta.scope = "namespace"` on the secret package is right and should be unpierceable. *Offered* visibility is a tenancy decision and belongs to whoever instantiates: only the cluster def author knows whether `data.postgres` is the cluster's shared database or team data's private one. Today one package-level knob serves both, so the tenancy half has no owner and defaults to "offered to everyone".

**P4: One declaration drives both boundaries. Resolution should imply connectivity, and therefore resolution must be gated where connectivity is.** The facts channel just eliminated the drift between "what the manifest references" and "what netpol allows" by deriving both from value flow. Splitting discoverability from reachability into two declarations would reintroduce exactly that drift class. The right reading: the netpol default-deny wall is per-namespace (cluster phase, `flowcharts.md` §6), so the DI visibility default should sit on the same wall, and the single declaration that lifts it for a provider is simultaneously (a) permission to be found and (b) consent to be dialed from outside, from which the provider-side ingress derivation follows. Provider-owned, instance-level.

**P5: Explicit wiring is an operator act.** In the monorepo model (doc 45 §2a) the person writing `deps.postgres = ...` in the cluster def sees the whole cluster; qualified wiring is the analog of the DNS qualified name and may pierce *offered* visibility. It must not pierce *intrinsic* scope: that is not a permission question but a does-it-work question. Caveat: this principle assumes the wiring author is the operator, which the self-service model (doc 117, team-authored instance files) breaks. §5 restores it with an operator-owned policy layer that wiring cannot pierce.

Where the prior docs already drew this line: doc 129 settled that no ambient DI crosses an evaluation boundary; cross-activation references go through an explicit export/import contract (`exports.auth = { from; contract; }`), same primitive at any distance. Doc archive/01 is where the intra-eval "fixpoint sees everything, DI is cluster-wide" reach was designed. This doc applies 129's line one level down: inside an activation, the namespace wall is the boundary, and crossing it takes the same shape of explicit act (an export by the provider or a qualified wiring by the operator), just cheaper because both sides live in one eval.

## 3. Where current behavior violates the principles

| # | Violation | Principle | Code |
|---|-----------|-----------|------|
| V1 | Rung 5 binds a unique instance from any namespace, silently, no diagnostic | P1, P2 | `resolve.nix:95` |
| V2 | Roles reach cluster-wide only *via* rung 5, so the correct global reach of infrastructure symbols is load-bearing on the incorrect ambient reach of app symbols; you cannot remove one without re-plumbing the other | P1 | `meta.nix:95`, `resolve.nix:95` |
| V3 | `meta.scope` conflates intrinsic and offered visibility; there is no way for a cluster def to mark an instance team-private, nor to mark one deliberately shared | P3 | `instance.nix:211` |
| V4 | Explicit wiring bypasses `_crossNsCheck`, so intrinsic scope is pierceable and fails at deploy instead of eval | P5 | `instance.nix:199` |
| V5 | Optional deps flip from unbound to cross-namespace-bound with no signal, and dep-config injection follows | P2 | `resolve.nix:109`, `resolve.nix:309` |

What is *not* a violation: the same-namespace preference (rung 3) matches the DNS search path exactly; the ambiguity errors (rungs 4 and 6) are correct link errors; managed-over-import mirrors strong-over-weak; roles as cluster-global symbols are P1-correct; the facade pattern (namespace-scoped `stackgres-database` in the consumer's namespace) is the model working as intended.

## 4. The smallest mechanism change: an export bit, and rung 5 consults only exports

One instance-level attribute plus one ladder edit. No new primitive, no second declaration for connectivity.

1. **`instances.<ns>.<name>.export = true`** declares "offered beyond my namespace". Exported instances (their name and aliases) are the only candidates rung 5 may bind. Semantics deliberately match doc 129's `exports.<name>` so that when activation slicing lands, the intra-cluster export bit is the degenerate form of the contract artifact (whole `out` offered, zero distance) and exported instances are exactly the ones whose edges may legally cross a slice cut. This closes part of 129's open question Q3 (what may cross a slice boundary): edges into non-exported instances may not.
2. **Role claimants are auto-exported.** `meta.roles = [ "dns" ]` already is the declaration of cluster-global intent; no cluster def changes needed for infrastructure. This decouples V2: role reach stops depending on ambient fallback.
3. **A non-exported unique other-namespace match becomes a teaching error**, not a silent bind: `no 'postgres' in namespace 'immich'; found data/postgres, which is not exported. Wire it explicitly (deps.postgres = "data/postgres") or mark it 'export = true' if it is meant to be shared.` The two escape hatches in the message are P5 and P3 respectively.
4. **`meta.scope = "namespace"` stays, as the intrinsic cap.** Exporting an instance of a namespace-scoped package is an eval error, and the `_crossNsCheck` moves to cover explicit wiring too (fixes V4: check `resolvedDepTargets` for direct bindings whose value is a cluster instance, or run the check on the explicit path before `direct` short-circuits).
5. **Migration cost is one line per genuinely shared instance.** ludo-kind needs exactly `data.postgres.export = true` (or `= { ... export = true; }`); every role provider (coredns, cilium, storage) is covered by item 2. A `cluster.di.defaultExport = true` compat knob would preserve "small clusters just work" verbatim, but the recommendation is to not add it: the error message already teaches the one-line fix, and a modal cluster flag reintroduces ambient reach for *every* instance, which is the thing being removed.

On tension "should the netpol boundary and the resolution boundary be one boundary": yes, and this mechanism makes the alignment structural rather than coincidental. Default-deny wall and default DI visibility sit on the same namespace line; `export` lifts both for one instance; the per-consumer holes stay derived from actual value flow (facts), so export grants findability and consent, while facts continue to open only the edges that exist.

On tension "what does namespace mean to kix": namespace stays the scoping primitive, on purpose. K8s already bundles DNS search scope, the netpol wall, secret readability, and quota at the namespace line; inventing a divergent kix-side grouping would put the DI boundary somewhere no runtime boundary exists. Teams that span namespaces are real (doc archive/01 §7, doc 129's team files), but the prior docs consistently place team *authority* at the git layer (CODEOWNERS on directories, doc 117 §3.3, doc 129 §5) and team *ownership* at the activation (doc 55 §6, doc 129 §6 rule 1). A team is a set of namespaces plus a set of files; it does not need to be a resolution scope.

### Mechanism sketch

Five touch points, in dependency order. All samples are against the current file layout.

**(1) Cluster def surface.** One instance attribute, plus the qualified string form for explicit wiring:

```nix
# ludo/services.nix
data.postgres = {
  package = packages.stackgres-cluster;
  aliases = [ "postgres" ];
  export = true;                     # offered beyond the data namespace
  config = { ... };
};

# operator-act alternative: no export, consumer names the provider with
# a qualified name (the DNS `postgres.data` analog; same syntax doc 129
# uses for cross-cluster imports, "prod-eu/auth")
immich.immich-db = {
  package = packages.stackgres-database;
  deps.postgres = "data/postgres";
};
```

**(2) The export bit enters `staticMeta`** (`cluster.nix:104`), so `buildResolutionIndex` carries it on every entry for free (entries already embed `_meta`):

```nix
_meta = {
  instanceName = instName;
  namespace = nsName;
  aliases = meta.effectiveAliases { instanceAliases = instCfg.aliases or [ ]; inherit packageMeta; };
  isImport = (instCfg.package._type or "") == "kix-import";
  # visible to rung 5 when: the cluster def offers it, or the package
  # claims a role (cluster-global by P1), or it is an environment import
  # (an import already IS an explicit declaration that this thing exists
  # to be consumed; it stays a weak symbol via managed-over-import)
  exported =
    (instCfg.export or false)
    || (packageMeta.roles or [ ]) != [ ]
    || (instCfg.package._type or "") == "kix-import";
};
```

The intrinsic cap is checked where the bit is derived, eagerly (same spirit as `checkRoleBindings`):

```nix
_exportCap =
  if (instCfg.export or false) && (packageMeta.scope or "cluster") == "namespace" then
    throw ("kix: instance ${nsName}/${instName} sets export = true, but its package declares "
      + "meta.scope = \"namespace\": its output is only consumable from its own namespace. "
      + "Intrinsic scope is not a policy knob; it cannot be exported.")
  else null;
```

**(3) The ladder edit** (`resolve.nix` `resolveArg`). The `otherNs` bucket splits into exported and hidden, rung 5 consults only the former, and the hidden bucket produces the teaching error:

```nix
sameNs   = builtins.filter (c: c.namespace == requesterNamespace) effectiveCandidates;
foreign  = builtins.filter (c: c.namespace != requesterNamespace) effectiveCandidates;
exported = builtins.filter (c: c.meta.exported or false) foreign;
hidden   = builtins.filter (c: !(c.meta.exported or false)) foreign;
fmt      = cs: builtins.concatStringsSep ", " (map (c: "${c.namespace}/${c.instName}") cs);
```

```nix
# rung 5 and below become:
else if sameNs == [ ] && builtins.length exported == 1 then
  bind (builtins.head exported)
else if builtins.length exported > 1 then
  throw "ambiguous auto-resolution for '${argName}': exported from multiple namespaces (${fmt exported}) — specify explicitly"
else if sameNs == [ ] && exported == [ ] && hidden != [ ] && !hasDefault then
  throw ''
    no '${argName}' in namespace '${requesterNamespace}'. Found ${fmt hidden}, not exported.
    Either wire it explicitly (deps.${argName} = "<namespace>/<name>") or set
    `export = true` on the provider instance if it is meant to be shared.
  ''
else if hasDefault then
  { found = false; }   # optional + hidden-only: unbound, see below
else
  throw "no '${argName}' found in cluster for namespace '${requesterNamespace}'"
```

Optional deps deserve the asymmetry: a required dep with only hidden candidates is a hard error (the consumer cannot proceed and the message teaches the fix), but an optional dep with only hidden candidates stays **unbound**, exactly as if the foreign instance did not exist. That is P2 behaving correctly (invisible means invisible; team B adding a cache must not force team A to acknowledge it), with a structured near-miss note on the doc-80 diagnostics channel for discoverability: `optional dep 'cache' of immich/immich left unbound; a non-exported candidate exists (teamb/cache)`.

**(4) Qualified wiring resolves through the index**, which is what fixes V4. Today an explicit override is a raw fixpoint value (`deps.postgres = config.instances...`), returns `direct = true`, and skips `resolvedDepMeta`, so `_crossNsCheck` never sees it. The string form goes through the index instead and comes back as a normal non-direct resolution:

```nix
# resolve.nix, resolveArg, before the ladder:
if builtins.isString explicitOverride && lib.hasInfix "/" explicitOverride then
  let
    parts = lib.splitString "/" explicitOverride;
    ns = builtins.head parts;
    name = builtins.elemAt parts 1;
    hit = builtins.any (c: c.namespace == ns && c.instName == name)
      (resolutionIndex.byKey.${argName} or [ ]);  # membership check; the
      # authoritative lookup is staticMeta ? ${ns}.${name}
  in
  { found = true; namespace = ns; instanceName = name; direct = false; }
else if explicitOverride != null then
  { found = true; value = explicitOverride; direct = true; }   # raw-value escape hatch, unchecked
```

Because the result is non-direct, it lands in `resolvedDepMeta` and `_crossNsCheck` (`instance.nix:211`) applies unchanged: qualified wiring pierces *offered* visibility (no export needed) but still cannot bind a `meta.scope = "namespace"` package cross-namespace. The raw-value form survives as the unchecked escape hatch for synthetic instances and tests; the docs point at the string form.

**(5) Consent flows to netpol.** No new derivation is needed for the per-edge holes (facts keep opening exactly the observed edges), but the export bit is where a provider-side envelope would hang: an exported instance is the only kind that may later have consumers the eval cannot see (doc 129 import markers, sliced activations), so doc 131's `fromEntities` ingress-envelope remainder should take `exported` as its precondition rather than inventing its own flag.

**Migration sweep.** One release with a `warn` mode: rung 5 still binds, but every fallback binding emits `cross-namespace auto-resolution: immich/immich-db bound data/postgres via fallback; this becomes an error — add export = true or wire explicitly`. Building each cluster then prints exactly the list of export lines to add; on ludo-kind that list is one entry. Roles and platform imports never appear in the list because items (2)'s auto-export covers them.

## 5. Operator containment: the third layer, and who consents to a netpol hole

Cluster security today, precisely: the cluster phase puts a default-deny wall around every namespace, and every hole in it is autogenerated from observed value flow (facts → termination → consumer egress CNP + provider ingress CNP + DNS egress; RoleBound SAs get apiserver egress). The compiled graph is *closed*: a hand-typed `postgres.data.svc.cluster.local` string carries no context, mints no fact, opens no hole, and is dead traffic against the wall. So eval-time edges and runtime allowances coincide exactly. What is missing is an owner for "may this edge exist at all": today, **wiring is the permission**. Whoever can cause a value to flow (add an instance, add a dep, write `deps.postgres = ...`) has thereby authorized the netpol hole that ships next to it. In a single-author cluster def that is fine, because the wiring author is the operator. Under multi-team fragments (doc 45 §2a) or self-service instance files (doc 117 §3.3), it is not: team A referencing team B's exported postgres compiles into connectivity with no operator-visible consent besides PR review.

The export bit (§4) gives the *provider* a consent surface. It does not give the *operator* one: an operator who wants team B to stay entirely inside its namespace has no lever short of auditing generated CNPs. That is the missing third layer, and it is namespace-keyed, because the namespace is where the wall already stands:

```nix
# operator-owned file (CODEOWNERS-gated, per doc 129 §5: authority is
# enforced at the git layer and made visible at the compile layer)
cluster.di.policy = {
  default = "open";                  # unlisted namespaces behave as today

  namespaces.teamb = "contained";    # no cross-namespace edges in or out,
                                     # exported or not, wired or not

  namespaces.payments = {            # allowlist form
    egress  = [ "data" "kube-system" ];  # may bind exports from these only
    ingress = [ ];                       # nobody outside binds payments
  };
};
```

The layering rule that keeps this coherent: **intrinsic scope caps export, export grants, policy only restricts.** The policy can never widen visibility (that stays the provider's export), so it is not the rejected consumer-side `imports` list in another coat; it is an intersection applied on top. Precedence questions cannot arise because the three layers answer different questions (can it work / is it offered / is it permitted).

Enforcement is eval-time, in two existing places: the per-instance pass where `_crossNsCheck` already walks `resolvedDepMeta` (catches DI bindings, including qualified wiring, which per the P5 caveat must *not* pierce policy), and the cluster phase where fact-derived edges are already collected for netpol (catches `connect`-stamped values and conducted indirections). A violation is a link error naming the edge and the policy line, not a silently-missing CNP: a policy that let the binding succeed but withheld the hole would ship a cluster that compiles and then times out at runtime, which is the failure mode kix exists to refuse. Because holes derive from edges and forbidden edges now refuse at compile, the netpol layer itself needs no changes; P4 survives intact with the declaration stack being export (provider) ∩ policy (operator), and connectivity still following resolution automatically.

## 6. DNS corollaries: what the export bit means for the Corefile

The Corefile (`kix/packages/coredns/helpers.nix`, rendered from `config.servers` into the coredns ConfigMap) contains **no per-service entries and never will**: the `kubernetes` plugin serves every Service's records dynamically from the API. Three consequences follow.

**Runtime DNS stays ungated, deliberately.** After this change, any pod can still resolve `postgres.data.svc.cluster.local`; the export bit narrows what the *compiler* binds, not what the resolver answers. That asymmetry is correct: in K8s, DNS is discovery and netpol is enforcement, and the visibility model puts its wall where the enforcement wall already is (P4). Deriving visibility *into* DNS (per-namespace views via the `firewall` plugin, refusing to resolve non-exported services) is rejected: the `kubernetes` plugin has no per-client views, it would make DNS lie during debugging, and it would duplicate a boundary netpol already enforces. The existing coarse gate stays as is: a workload with no service edges gets no DNS egress hole at all; one that talks to anyone can resolve everything but dial only its edges.

**No DNS aliases for exported symbols.** The tempting move, giving exports a stable cluster-level name (`postgres.kix.svc` CNAME to `postgres.data.svc.cluster.local`) so consumers survive the provider moving namespaces, is the runtime-linker solution to a problem kix solves by recompilation: `out.fqdn` re-links every consumer on move, and the deploy DAG carries the change. A CNAME layer would add a second name for every service (violating "don't invent new fields") and decouple what manifests say from what pods dial, which is exactly the drift class the facts channel exists to prevent.

**Where deriving Corefile entries from the definition IS right.** The rule: derive an entry when the cluster definition already contains *both sides of a mapping* that operators otherwise maintain by hand in split-horizon DNS, and never mint a name that doesn't exist outside kix. Two classes qualify today:

1. *Split-horizon for exposed hosts.* `immich.immich` declares `ingress.host = "photos.ludo.lan"`; the gateway provider's Service is a DI-resolvable fact. In-cluster clients dialing the public URL (OIDC issuers, webhook callbacks, apps configured with their own external address) currently hairpin through the LAN edge or fail on split DNS. kix knows host → gateway Service for every `kix.expose` in the cluster; a derived `rewrite`/hosts block answering `photos.ludo.lan` with the gateway's in-cluster address is pure legalization of declarations that already exist.
2. *Forward/stub zones owned by an edge package.* The tailscale package knows `ts.net` resolves via MagicDNS at `100.100.100.100`; today that knowledge lands in the Corefile by hand. A package-declared zone forward (`meta.dnsZones = [ { zone = "ts.net"; forward = "100.100.100.100"; } ]` or an out-contract on the role) is the DNS twin of `meta.annotationDomains`: open vocabulary, declarer-owned, two declarers of one zone is a duplicate-symbol error.

What does *not* qualify: entries for doc 129 contract imports (they carry real public FQDNs; nothing to invent) and doc 65 passthrough instances (same).

**Mechanism and timing, two tiers matching the two classes.** Zone forwards are plain phase-1 config: they flow into the dns provider by dep-config injection (the stackgres extension-forwarding pattern, `deps.dns.config.extraServers`, since the role name already doubles as a dep alias) or a cluster-phase sweep of `meta.dnsZones`, and can safely live in the main Corefile. The exposed-hosts map is an aggregate over every exposing instance, and folding an aggregate into the dns provider's own sealed ConfigMap is a trap independent of fixpoint concerns: coredns's root is the readiness dep of every talking workload, so any app renaming a host would churn the dns provider's identity and, transitively, half the cluster's `depends-on`. Derived aggregates therefore land in a **separate imported resource**, a `coredns-custom` ConfigMap (the k3s pattern: `import custom/*.server` plus the already-present `reload` plugin), emitted by a `clusterProcessors` hook exactly like the default-deny walls. Same shape as netpol: static provider config in the package, cluster-wide aggregates as separate cluster-phase resources, so the aggregation point stays off the hot dependency spine.

## 7. Rejected alternatives

- **Separate "may connect" declaration beside resolution** (a grants/ACL table): violates P4, recreates the declared-vs-observed drift the facts channel removed, and doc 92's intent layer already covers the cases where policy legitimately exceeds the DI graph (external CIDRs, operator-to-operand).
- **Consumer-side imports list** (`imports = [ "data" ]` to widen the search path, like resolv.conf `search`): puts the tenancy grant on the wrong side; the consumer is the party the boundary exists against (P3, P4).
- **Remove rung 5 outright, explicit wiring only**: breaks role resolution (V2) and taxes the legitimate shared-service case with per-consumer wiring; the export bit keeps the one-declaration ergonomics.
- **Keep rung 5, add a warning**: warnings on load-bearing behavior become permanent noise; the binding still silently changes when instances are added (P2 still violated).

## 8. Open questions

1. **Contract slice now or later?** `export = true` offers all of `out`. Doc 129's cross-cluster form carries `contract = [ "url" "issuer" ... ]`, the public-ABI slice. Adding the list form (`export = [ "fqdn" "port" ]`) is cheap and gives link-time `out` typing (doc 120's biggest-gap item) a natural anchor, but is not needed to fix V1-V5.
2. **Transition mode.** The sketch commits to one `warn` release before the hard cut (the warn pass doubles as the audit that produces the export lines). Remaining question is only whether that is worth it pre-1.0, or whether the teaching error alone is cheap enough to hard-cut immediately.
3. **Does export feed a provider-side ingress envelope?** Today ingress holes are per-observed-consumer. An exported instance in a sliced or multi-activation future may have consumers outside the eval; doc 131's `fromEntities` ingress-envelope remainder and doc 129's import markers should consume the same export declaration.
4. **Namespace-set visibility domains** (`cluster.di.domains.teamA = [ "immich" "nas" ]`): deliberately not proposed. If a real cluster produces a case where two namespaces of one team need ambient mutual resolution and per-instance exports are demonstrably worse, revisit; otherwise activation slicing is the coarser boundary and arrives with its own mechanism. Note §5's policy allowlists already express the *restrictive* half of a team grouping without introducing a resolution scope.
5. **Cross-namespace resource placement.** `scope.forService` lets a package materialize resources in another instance's namespace (stackgres-database's bootstrap secret and job). That is a write into foreign territory, not a traffic edge, so §5's containment does not see it. Should policy also gate placement, or is that doc 55's ownership problem and out of scope here?
6. **Containment vs doc 92 intents.** Doc 92's declarative netpol intents can legitimately exceed the DI graph (external CIDRs, operator-to-operand). Does `cluster.di.policy` constrain what intents may declare for a contained namespace, or are intents operator-vocabulary and therefore already above the policy line?
