# 126: Compiler core rewrite — making the ring model physical

**Status:** Draft (Design Doc / Plan)
**Related:** `119_core_surface_audit.md` (what core *is* — ring model, cut list), `120_compiler_theory_mapping.md` (what to borrow — priorities 3.1/3.4), `121_netpol_as_plugin.md` (hook mechanics, migration steps 1–5), `80_structured_diagnostics.md` (the diagnostics channel this rides), `29_compiler-design.md` (anchor, settled)

Docs 119/120/121 each answer one question: what the core is, what the field
teaches, how the first extraction works. None of them sequences the work. This
doc is the program: what gets rewritten, in what order, under what invariant,
and what explicitly stays untouched. Settled points are cited, not re-argued.

## 1. What "cleanup" means — and what it does not

This is **not** a v2-from-scratch. The essence (store-path-as-edge, `out`,
sealing, Activation closure) is proven, CLI-contracted, and used by all 60
packages (119 finding 1). The problem is physical structure:

- **The rings exist only in prose.** Ring 0 sealant, Ring 1 validators, and
  Ring 2 netpol/secrets glue all live in one 1,862-line `eval/scope.nix`.
  `netpol.nix` logic threads through five files (`eval.nix` import,
  three splice sites in `scope.nix`, drain in `instance.nix:363`, enforcer
  plumbing in `cluster.nix:133–234`, options in `modules.nix:555`).
- **Cross-file invariants are held by convention.** The sideband drain
  (`_generatedNetpol`), the two self-dep guards (`cluster.nix → isSelfEnforcer`,
  `instance.nix → _skipWorkloadNetpol`), the fixpoint-safety rules of 121 §1b,
  and the reason the *three* fixpoints exist (config-injection cycle breaking)
  are documented in `architecture.md` — nowhere enforced, nowhere local.
- **Three call sites duplicate the pre-seal splice** (`mkWorkload` ~987,
  `mkJob` ~1115, helm path ~1185 in `scope.nix`), already flagged in 121 §9.
- **The sharp edges with *silent* failure modes** (119: >3-deep resources
  vanish, non-string leaves drop edges) are core bugs by 120 §3.7's
  crash-triage bar, not documentation gaps.

The rewrite: make Ring 0/1 vs Ring 2/3 a **file-and-contract boundary**, with
121's hooks as the only way layers attach, and fix the silent-failure edges in
the same trench because they live in the same functions.

## 2. Ground rules

1. **Empty-diff invariant.** Content addressing makes behavior preservation
   machine-checkable: every refactor step must produce a byte-identical
   manifest set (and identical `kix.dev/depends-on` stamps) on ludo-kind and
   nw1-migrated. Steps that intentionally change output (cut list, always-on
   rules) ship as separate, flagged commits — never mixed with restructuring.
2. **The CLI contract is frozen.** Activation closure shape, PI CR fields,
   tagged depends-on format, package-index JSON. If a step would touch these,
   it is out of scope (own doc, CLI coordination).
3. **Non-goals stand** (120 §3.9): no optimization passes, no smart runtime,
   hygiene only on demand.
4. **Reify to verify** (120 §3.5) is the design law for every new surface
   introduced here: hook inputs are data; functions only in the escape ring.
5. **No new features ride along.** Doc 100's wishlist and 97's contracts wait;
   the rewrite only creates the slots they later fill.

## 3. Target shape

Prescribe boundaries, not filenames — but the split of `scope.nix` is the
heart of the operation:

```
kix/lib/
  core/        Ring 0 — sealant + context machinery (k8s.nix), closure walk,
               collectTypedAttrs, diagnostics channel, refusal throws
  eval/        Ring 1 — cluster/instance/resolve/auto (unchanged files,
               netpol references erased), hooks runner
  scope/       Ring 1 — split of today's scope.nix:
                 builders.nix    mk<Workload>/mkJob/mkSecret/mkCRD/... (one
                                 shared pre-seal pipeline, one splice site)
                 validators.nix  the validator catalog (pure: spec → findings)
                 labels.nix      label stack, selectorLabels
                 scope.nix       thin assembly of the above into scopeObj
  plugins/
    netpol/    today's netpol.nix + netpol-interface.nix + the module that
               registers hooks + declares networkPolicy.* options (121 §3)
  vocab/       compose.nix, rbac.nix, crd.nix, fragments.nix — libraries
               beside the core, importable without it
```

Edge analysis (service registries, `extractServiceEdgesFromJson`, DNS-root
injection) stays in Ring 1 per 121 §2 — DNS needs it regardless of netpol.

## 4. Phases

Ordering follows 121 §8 where it overlaps; each phase is independently
landable and ends green on the empty-diff check (except 4 and 5, flagged).

**Phase 0 — safety net (before touching anything).**
Golden-snapshot harness: build ludo-kind + nw1-migrated, store manifest
hashes; a `kixChecks` entry fails on drift. State the crash-triage bar
(120 §3.7): any eval error that is not a kix-authored diagnostic is a kix bug —
this converts the sharp-edge list into a bug backlog with a definition of done.

**Phase 1 — envelope repair + capability generalization** (121 §5, steps 1–2).
Spec assembly moves behind `enforcerApi.mkPolicy` (neutral `subject`, rename
`portsToCilium → portsToNative`); enforcer lookup generalizes to
`findCapabilityProvider` / `validateProviderInterface`. Worth shipping even if
nothing else lands — it makes doc 92's claim true and unblocks docs 108/101.

**Phase 2 — hooks + first plugin** (121 §3, steps 3–4).
Three module options (`workloadInterceptors` / `instanceProcessors` /
`clusterProcessors`), one `runWorkloadInterceptors` replacing the three
duplicated splice sites, sideband renamed `_injectedResources`, netpol
registered from `kix/lib/plugins/netpol/`, `networkPolicy.*` options move into
the plugin module. Decide 121 §9's transform-vs-append split here — doc 115
lands on the same slot and must not wait.

**Phase 3 — physical decomposition.**
Split `scope.nix` per §3; erase netpol names from `eval/`; replace `eval.nix`'s
hand-threading with the new boundaries. Move the cross-file invariants *into
the code*: the fixpoint-safety rules (121 §1b) become the documented hook
contract next to the runner; the reason for the three-fixpoint split becomes a
comment block at the split point, not architecture.md lore.

**Phase 4 — diagnostics in the same trench** *(output-changing, flagged).*
While the validator catalog is being extracted anyway: recovery points
(per-instance `tryEval` islands so one broken package doesn't mask its
siblings' diagnostics — 120 §3.4), `KIX0xxx` error codes on the extracted
validators, and the 119 open question resolved: promote `selectorCoherence` +
`fqdnWithoutContext` from opt-in scorecard to always-on core diagnostics.
Rides doc 80's transport; extends its scope per 120 §3.4.

**Phase 5 — cut list execution** *(output-changing, flagged)* (119 cut list).
Remove `kix.monitor`, `out.url`/`out.ports` (park in doc 31), demote
`kix.mkEnv`; mark unvalidated flavor backends experimental; adopt-or-demote
deadline for `mkOptional`/`mkWebhookService`. Guide + architecture.md updated
to describe the practiced surface.

**Deliberately after the rewrite, not in it:** link-time typing of DI `out`
contracts (120 §3.1 — highest-value follow-up; Phase 3 must leave the
resolution ladder with an obvious place to check a contract, nothing more),
doc 115 hardening plugin (second hook consumer, validates the contract),
netpol lifted to a separate flake (121 step 5, waits for OSS packaging).

## 5. What this rewrite explicitly does not touch

- **The three-fixpoint architecture.** It works and its shape is forced by
  config injection. Candidate simplification (drop the config-only fixpoint by
  restricting injections to literals) would break the immich→stackgres
  pattern — parked as an open question, not a phase.
- **Helm internals** (`helm.nix`/`helm-dag.nix`) — own track (docs 116/117);
  only its workload path is rewired through the hook runner in Phase 2.
- **The module-option schema** users see (`modules.nix` surface), except
  options that move into the netpol plugin.
- **CLI, operator, deploy engine** — frozen contract (§2.2).

## 6. Exit criteria

- Netpol is importable as a module and deletable from a cluster without
  touching `eval/` (grep test: no `netpol` reference outside `plugins/`).
- No file in `eval/`/`scope/` exceeds ~700 lines; one pre-seal splice site.
- Doc 115 can register its interceptor without core changes.
- The silent-failure sharp edges (nesting depth, non-string edges) throw or
  warn with attribution; migration corpus (nw1) produces zero
  non-kix-authored eval errors.
- `architecture.md` + guide updated; 119/121 archived per ship rule.

## 7. Open questions

- **Hook registry shape:** named attrset (`hooks.workloadInterceptors.netpol`)
  vs list — named merges better and enables `skipHooks` targeting (121 §9
  leans named; confirm before Phase 2).
- **Transform-vs-append interceptor ordering** (121 §9) — decide in Phase 2;
  proposal on the table: transforms run first, in a separate hook.
- **Always-on severity** for the promoted essence rules: warning or error?
  Warning first release, error after the migration corpus is clean?
- **Does the config-only fixpoint survive?** (§5) Measure whether any real
  cluster still needs function-shaped injections before considering removal.
- **Where do interface declarations live** (120's open question: role / consumer /
  provider) — must be answered before the post-rewrite typing work, not before
  the rewrite; Phase 3 should not accidentally foreclose any of the three.
- **Snapshot harness scope:** ludo-kind + nw1-migrated only, or every cluster
  in `clusters/`? (Cost vs coverage; satchel cluster may need env the CI
  lacks.)
