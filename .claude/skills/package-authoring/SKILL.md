---
name: package-authoring
description: Write a new Kix package from upstream software, or rework one substantially, so that it meets the Kix principles before anyone reviews it. Use this skill when the user says "write a package", "add a package for <software>", "package <upstream>", "port <chart> to a native package", or asks how to start a package. It fixes the order of the design decisions, says what to read in the upstream source and which decision each fact settles, and gives the verification and handover steps. The package-review skill is the checklist that runs afterwards; this skill does not repeat it.
---

# Package authoring

This skill covers the work before and during writing. The `package-review`
skill (`.claude/skills/package-review/SKILL.md`) is the checklist that runs
afterwards; run it before opening a pull request. Item IDs below (W8, D30,
...) are its items. Principles are `P<n>` in `PRINCIPLES.md`. `CLAUDE.md`
makes keeping this file current part of changing the package conventions.

## What to read, and when

| Need | Read |
|---|---|
| The values a package is judged against | `PRINCIPLES.md`; `docs-legacy/BEST-PRACTICES.md` §6.1 (availability, line 215), §7.4 (one alias, one contract, line 491), §9.6 (alerts, line 773) |
| The package file contract and option contract | `docs-legacy/HANDBOOK.md` §5 (line 251); `.claude/skills/kix-migration/SKILL.md` "Package Anatomy" (line 78) and "Package Meta" (line 704) |
| Second implementation of an alias, facades, operator stacks | kix-migration "Two Implementations, One Alias" (line 794) and "Operator-Managed Stacks" (line 742); `.claude/skills/kix-migration/MULTI_COMPONENT.md`, `STORAGE.md`, and `SECRETS.md` |
| CRDs and operator RBAC | `.claude/skills/crd-vendoring/SKILL.md` |
| Any prose, including comments and the header | `CLAUDE.prose.md`, `CLAUDE.md` "Code comments" |
| Logging what you notice and do not fix | `CLAUDE.housekeeping.md` |

The HANDBOOK and BEST-PRACTICES sections on builders, workloads, selectors,
and scorecard rules predate the lib rewrite of August and September 2026
(BEST-PRACTICES.md:1135). Where they disagree with `kix/lib/` or a reference
package in the pattern table below, the code wins.

## Setup

- One git worktree per package, outside the checkout (`../kixpkgs-wt/<name>`).
- `git add` every new file before the first evaluation. The git fetcher skips
  untracked files, so an unadded package or `crds/*.json` does not exist.
- `CLAUDE.md` "Build caches and disk" and "Git hygiene" apply: no `path:`
  flakeref, check free space before a build, no blind stash pop, and no
  `Co-Authored-By` trailer.

## The decision sequence

Settle these before writing the build, in this order. Each decision is
stated in terms of the earlier ones, so a late change to an earlier one
rewrites the later ones.

| # | Decision | What it fixes | A late change costs |
|---|---|---|---|
| 1 | Shape and boundary | tier, one package or several, facade or not, CRD route | a restart (L4, I9, C1) |
| 2 | Upstream research | the facts every later decision is derived from | every decision made on a guess |
| 3 | Availability | the `pick` table per workload, ceilings and their evidence, strategy | every builder and the header (W1, W4, O19) |
| 4 | Contracts consumed, provider fixes | build args, the contract holding each, what providers must add | every consumer wire and the `out` shape (D5, D30) |
| 5 | Contract provided | `out`, alias, `meta.scope`, `meta.lifecycle`, `conflictsWith` | every consumer written against it (D9, D25, M6) |
| 6 | Secrets | purpose-named secret deps, keys, how the program reads them, rollout | options, env, args guard, and fixtures at once (S1, S2) |
| 7 | Escape hatches and locks | which hatches exist and what each may not touch | a re-read of the whole wiring (E3, E6, E8) |
| 8 | Option surface | which upstream knobs are typed, required inputs, refused combinations | descriptions, docs, fixtures, and tests (O6, O7, O9) |
| 9 | Monitoring and alerts | metrics wiring, the failure modes that become alerts | the rules test and the header |

### 1. Shape and boundary

- Tier (HANDBOOK §12, line 1030): a package with consumers is native (tier 3).
  `importChart` (tier 2) is for a chart whose values you only lock and pass
  through; once the package reads or computes a field inside the chart, go
  native. A chart's singleton default, hooks, and release-name prefixing are
  not evidence of anything (L6, E11, W22).
- One package per upstream unit. A multi-component application stays one
  package (BEST-PRACTICES §12.5, line 989). A component other packages would
  reuse becomes a dependency instead.
- An operator and the kinds it serves are separate packages (`cnpg-operator`,
  `cnpg-cluster`). A server that hands consumers their own database or user
  adds a facade (`cnpg-database`, `clickhouse-database`); consumers depend on
  the facade, never the server (D5).
- A second implementation of an existing alias answers the existing contract
  unchanged. A field it cannot honour means a different alias, not a `null`
  (`v2_discussions/148_clickhouse_packages_plan.md:39`).
- CRDs: vendor or `mkCRDRef` markers (crd-vendoring skill §1). An operator
  with admission webhooks gets a gate Job on every handle on either route
  (C21).

### 2. Upstream research

Read at the pinned release, in source, not in the chart. Each fact settles a
named decision; record the fact and its upstream path in the pull request.

| Upstream source | Extract | Settles |
|---|---|---|
| Runtime config loader (`config/runtime.exs`, `settings.py`, `config.go`) | every variable, which are required, which are URL-shaped credentials, which need a restart | option set and types (step 8); what comes from a dep's `out`; `keyRef` per variable or `$(VAR)` expansion into an owned URL, with its escaping limit (step 6) |
| Dockerfile and entrypoint | `USER`, uid, writable paths, `$HOME`, start command, whether the entrypoint migrates | numeric `runAsUser`, emptyDir mounts (W12), `enableServiceLinks` (W16), init container or Job |
| Migrations | `CREATE EXTENSION`, schema and global privileges, advisory locks, whether two pods may migrate at once | injected extensions or privileges (step 4), Recreate or RollingUpdate (W8), a replica ceiling |
| Health endpoints | what each endpoint checks; whether liveness dials a dependency | probes (W13), startup deadline (W14) |
| Metrics | port, whether on the public port, auth, the flag that enables them | `kix.monitor` wiring (Mo11, Mo12) |
| Clustering and HA, in source | in-memory state, sessions, caches, job queues, leader election, peer discovery, cron singletons | the `pick` table and any ceiling (step 3) |
| Monitoring material and failure reports | shipped rules or mixins, outage threads | alerts (step 9) |
| CRDs (chart `crds/`, `config/crd/bases/`, release bundle) | public URL at the tag, conversion webhooks, condition types | `crds/sources.txt`, readiness (C5) |

"Does it run replicated, and what does it need for that?" is a mandatory
question, answered from source, not from the chart's default.

Worked example, Plausible CE: `config/runtime.exs` takes `DATABASE_URL` and
`CLICKHOUSE_DATABASE_URL` as URLs, so the credentials are `$(VAR)` expansions
into owned variables, not `keyRef` values. Its ClickHouse migrations run
`CREATE FUNCTION`, a global privilege, and create plain `MergeTree` tables on
a fresh install; both are questions for the ClickHouse providers (step 4),
not workarounds in the consumer.

### 3. Availability

The package honours the cluster's level. If the cluster asks for `zone`, the
package runs replicated at `zone`, and so do its dependencies. A singleton
is a finding from the upstream source, not a default.

1. Name `availability` in the package function (the lib passes only named
   arguments) and start from replicated:
   `kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 3; }`.
   Quorum systems use odd counts (rabbitmq-cluster); leader-elected
   controllers follow W6.
2. Check in source: shared in-memory state and whether a dependency (Postgres,
   Valkey) replaces it; leader election or an HA flag; migrations that are not
   concurrent-safe (then Recreate, keycloak:83-88); session affinity (a
   Service setting, not a ceiling); cron or queue singletons (a ceiling on that
   workload only, or upstream's "run the scheduler in one pod" flag); one RWO
   volume as the state (immich:144-146); one owner of an OS resource
   (firezone:83-85).
3. If it replicates with configuration, configure it (keycloak's jdbc-ping,
   header 74-81).
4. A ceiling needs evidence from upstream source, in the comment beside it
   and in the header's `Limits:` line (grafana:119-121, tempo:101). A
   program-wide limit is `meta.availability.max`; a limit that depends on
   config, wiring, or one workload is `availability.max` on that builder
   (pattern table, "Ceilings"). W4 and W5 cover the singleton form.
5. Load-serving workloads: O19 (the option form is the pattern table's
   "`pick`" row). Strategy: W8.
6. Operator-placed operands map the level into the CR (`instances`,
   `podDistribution`) and use `kix.availability.spreadConstraints` where the
   CR takes a spread list (cnpg-cluster:512); never raw anti-affinity (W2).
7. Dependencies resolve their own level from the cluster default
   (`kix/lib/eval/instance.nix:74-85`); no consumer channel raises a
   provider's level. So check each dependency's mapping. A provider that caps
   at `none` without evidence, or a new provider with no mapping, is fixed in
   the same change (step 4). A consumer whose availability depends on the
   provider's says so in its header.

Lib: levels and `pick` in `kix/lib/core/availability.nix:24-74`; `resolve`
caps at the package ceiling with a warning (`:188-219`); builder ceilings in
`kix/lib/scope/builders.nix:197-199, 341-346`; the plugin derives spread and
PDB from `replicas > 1`, warns on a one-replica root workload at `node` and
above, and throws on `replicas > 1` under an effective `none`
(`kix/lib/plugins/availability/module.nix:255-282`). `every-package-evaluates`
runs each package's defaults at `none` and `zone`, so a level-dependent bug in
the defaults fails there.

### 4. Contracts consumed, and fixing the provider

- Choose by alias and contract, never by package (P10, P13). Lib contracts:
  `kix.contracts.postgresDatabase`, `oidcProvider`, and `otlpEndpoint`
  (`kix/lib/vocab/`); `gateway` is held by `kix.expose`, not by the package.
  Package-local: `kix/packages/clickhouse/contract.nix`. Consumers hold the
  dependency with `assertions`, providers pass `root.out` through `check`
  (D30; pattern table, "Contracts").
- A consumer that reads an optional field (`username`, `extensions`, `tls`)
  handles its absence on a `kix.mkImport` stand-in
  (`kix/lib/vocab/postgres-database.nix:1-11`, D22).
- When the consumer needs a fact every provider can give, extend the contract
  and every provider, not the consumer. Precedent: `extensions`, injected
  through `deps.database.config.extensions`, forwarded by the facade, merged
  by name in cnpg-database (pattern table, "Config injection"). An injected
  option must be mergeable (a list or attrset), or the injection collides with
  the instance's own value.
- Fix the provider in the same change, with tests: a missing `out` field, a
  non-mergeable option, a privilege the facade cannot grant, a singleton
  default with no evidence. Never re-derive a host, write a NetworkPolicy, or
  widen a privilege in the consumer. Some providers (the ClickHouse packages)
  are new, so a new consumer finding gaps in them is expected.
- Test a contract change three ways: `every-package-evaluates` (every provider
  and consumer re-evaluates); the contract's swap check (`clickhouse-swap`,
  `postgres-swap`, `gateway-swap`; `flake.nix:199, 235, 278`, fixtures under
  `clusters/test-*-swap/`); a lib unit test when a vocab file changed. A new
  consumer that reads fields which differ between implementations gets a swap
  fixture (`clusters/test-clickhouse-swap/consumer.nix`).

### 5. Contract provided

- Decide `out` before any resource exists: names, `fqdn`, ports, URL, operand
  selectors, `crds.<Kind>` handles, and builders only where they gate,
  default, or refuse (D9, D13). Every value that names a resource derives
  from `self.<part>.out.*` so it carries string context (D24).
- `meta.defaultAliases` when others consume it (M8); `meta.scope = "namespace"`
  when it hands consumers a Secret (S9); `meta.lifecycle = "stateful"` when it
  provides state others depend on (M6); `meta.conflictsWith` only for a
  genuine one-per-cluster package (M9).
- Publish every `out` field at every toggle, null when off (D25).

### 6. Secrets

One purpose-named dep per credential, bound once through
`kix.checkSecretKeys` (S3, S4; `SECRETS.md`). Never a string or path option
for a credential: the dependency is what lets the site choose between a
value in the build, a SOPS file, and a Secret an operator writes, and what
`cluster.secrets.accept` checks (S1, S15; HANDBOOK §21.11). Configuration
the program reads from a Secret gets a non-Secret route or a dependency
beside the rendered Secret, which is classified `configuration` (S14;
alertmanager, victoria-metrics-alert). Discrete variables take
`keyRef` values; a URL-shaped credential takes `credentials.out.mkEnv` for the
parts and `$(VAR)` expansion in an owned variable. That leaves the password
unescaped inside the URL, so it is a `Limits:` line (vaultwarden:36-38).
Rollout through `checksum/<name>` or `reloader.out.withReloadOn` (S10). The
pattern table has each form.

### 7. Escape hatches and locks

- The hatch set is E1's.
- Derive the lock lists from the DI wiring, because they are the same list:
  every path, flag (all spellings), and variable the package computes from a
  dependency or option is locked through `kix.mergeGuarded`, `kix.guardArgs`
  (owned flags derived from the owned env groups), and `kix.mergeEnv` owned
  groups (E3, E6, E8; pattern table).
- Bind `who = "<pkg> ${scope.namespaceName}/${name}"` once in the `let` and
  pass it to every helper (P9).

### 8. Option surface

Type only what the package reads or derives from (O6, O7). Refuse at
evaluation every combination evaluation can see, with a negative test and a
positive control (O15, T2). Defaults are public-safe; a site's value goes in
the cluster file (L1, L2). The migration guides' "match the cluster" refers
to that cluster override, never to the package default.

### 9. Monitoring and alerts

Follow package-review "Writing a package's alerts" and BEST-PRACTICES §9.6.
The pattern table gives the `kix.monitor`, `kix.alerts`, and metrics-toggle
references.

## Writing the package

### Header

The header is the package's contract for a reader who will not open the code
(P2). Order, with the labels new packages use (older packages also carry
`DI deps:` and `Exposes:`; do not copy those):

1. `# <directory name>: <what it runs>`, then what it installs.
2. `Dependencies:`, one per line, `(required)` or `(optional)`, what each
   brings.
3. A minimal instance that the test cluster evaluates (T5).
4. One paragraph per operational fact, with network policy last (metabase:48-71
   is the model).
5. `` `out`: `` the fields consumers read.
6. `Escape hatches:` the hatches and their locked paths.
7. `Limits:` ceilings with the upstream reason and where each is declared,
   untested paths, host prerequisites (tempo:101, falco:45). Operators add
   `Replicas:` and `Moving to another release:` (cnpg-operator:46, 76).

### Pattern to reference package

The only place in this skill with package line numbers. `pkg:N` is
`kix/packages/pkg/default.nix:N`.

| Pattern | Reference |
|---|---|
| Release binding, digest, `who`, `startupSeconds` in one `let` | metabase:85-96 |
| Shared release file for a release group | `immich/release.nix`, immich:93 |
| Follower image tag with `tagText` and `mkDefault` | n8n:265-272, 305 |
| `checkSecretKeys`, read through the binding | metabase:154-159, 258 |
| `mergeEnv` defaults and owned groups | metabase:164-215 |
| Discrete database variables through `keyRef`, owned `_FILE` twins | metabase:183-198 |
| URL-shaped credential through `$(VAR)` | vaultwarden:141-145, 210-231 |
| `guardArgs`, owned flags from owned env groups | keycloak:350-368 |
| `mergeGuarded` on `settings` or `extraSpec` | tempo:683; cnpg-cluster:548 |
| Migrations at start: Recreate, deadline from `startupSeconds`, probes | metabase:90-93, 248-252, 280-300 |
| Config injection into a dependency | metabase:105-108; stackgres-database:97-102; cnpg-database:94-115 |
| Contracts: consumer `assertions`, provider `check` | metabase:108; stackgres-database:486; keycloak:528; tempo:957 |
| `pick` as an option default with `defaultText` | cnpg-cluster:300-314 |
| `pick` inline, header names the instance override (O19) | keycloak:219-224, header 74-76 |
| `atLeast` | valkey:108 |
| Ceilings: package-wide, per builder | tempo:416-418; valkey:545, harbor:1543-1545 |
| `kix.expose`, `exposure.urlOrNull` | metabase:168-171, 360 |
| Metrics toggle that does not restart the workload | metabase:148-153; keycloak header 30-36 |
| `kix.monitor` with alerts | openbao:1241-1262; clickhouse:597-623 and `alerts.nix` |
| `kix.alerts` over a PodMonitor | cnpg-cluster:841-850 |
| `kix.healthCheck` with a script file | victoria-metrics-agent:324-343 |
| Checksum annotations, `enableServiceLinks = false` | metabase:253-267 |
| Facade: consumer-namespace Secret, server-namespace Job | clickhouse-database:1-40; stackgres-database |
| One alias, two implementations, a contract file | `clickhouse/contract.nix`; clickhouse, clickhouse-cluster |

A script of more than a few lines is a sibling file read with
`builtins.readFile`, so it can be linted and run alone
(`clickhouse/health-check.py`, shared with clickhouse-cluster).

## The files a complete change touches

Mandatory:

1. `kix/packages/<pkg>/default.nix`.
2. `kix/package-eval.nix`: a `settings` entry when the package needs deps or
   config to evaluate at `none` and `zone` (`:105`; keycloak at `:268-285`).
3. `clusters/test-<pkg>.nix`: every toggle on, each optional dependency
   present at least once, a `cilium` instance and `networkPolicy.enable = true`
   so the kind deploy runs under default deny, and the bring-up, build, and
   deploy commands in the header (`clusters/test-clickhouse.nix:13-21`,
   `clusters/test-keycloak.nix:1-15`). A dependency from an unmerged change
   is a `kix.mkImport` stand-in; note the merge order.
4. `clusters/flake.nix`: register the cluster in `clusters`.
5. `kix/lib/tests/units/<pkg>.nix`: names `<topic>-<what>`, helpers as in
   `kix/lib/tests/units/keycloak.nix:8-18`. Each `evalFails` has a positive
   control (T2). Two instances in two namespaces (Na2, Na10) and each
   optional dependency absent (D15) are evaluated here with `mkCluster`, so
   they are committed, not a scratch run.
6. `housekeeping/YYYY-MM-DD-slug.md` for each problem noticed and not fixed
   (`grep -ril <keyword> housekeeping/` first).
7. `ROADMAP.md`: the package under "Service catalog (prebuilt packages)" with
   release and evaluated or deployed status; gaps found in Kix become items.

Conditional:

8. `clusters/test-<pkg>.rules-test.yaml` when the package ships alerts
   (auto-discovered, `kix/lib/mkFlake.nix:120-138`).
9. `kix/lib/vocab/<contract>.nix`, `vocab/default.nix`, `units/<contract>.nix`,
   and `kix/lib/architecture.md` for a new contract.
10. Provider packages the consumer exposed gaps in, with their tests (step 4).
11. `crds/` with `crds/sources.txt`, and `rbac/` (crd-vendoring skill); sibling
    files such as `health-check.py`, `release.nix`, `contract.nix`, and
    `alerts.nix`.
12. `clusters/test-<contract>-swap/` for a second implementation of an alias,
    registered in `clusters/flake.nix` and the root `flake.nix`.
13. `docs-legacy/HANDBOOK.md`, `FEATURE-CATALOG.md`, and `BEST-PRACTICES.md`,
    and the kix-migration, package-review, and crd-vendoring skills and this
    one, when a lib API, role, `meta` key, or convention changes (T6).
14. `kix/lib/eval/roles.nix` and `kix/lib/flavors/*.nix` only for a new role.

## Verification ladder

Cheap first. Each step assumes the earlier ones pass.

```bash
F=--extra-experimental-features; P=pipe-operators
git add -A kix/packages/<pkg> clusters kix/lib/tests                     # 0. the fetcher sees nothing untracked
nix build ./clusters#cluster-<cluster> $F $P                             # 1. the test cluster, every toggle on; read its traces
nix build .#checks.x86_64-linux.every-package-evaluates $F $P            # 2. defaults at none and zone, option contract, settings entry
nix build .#checks.x86_64-linux.kix-lib-tests $F $P                      # 3. unit tests, negative tests with controls
nix build ./clusters#checks.x86_64-linux.rules-cluster-<cluster> $F $P   # 4. promtool check and the .rules-test.yaml (alerts only)
nix build .#checks.x86_64-linux.{clickhouse,postgres,gateway}-swap $F $P # 5. the contract's swap check (contract changes only)
nix shell nixpkgs#uv -c uv run --frozen scripts/vendor-crds.py --check   # 6. CRDs only
nix build ludo/#cluster-ludo-kind $F $P                                  # 7. smoke over the full package set
```

`<cluster>` is the key in `clusters/flake.nix`. When `every-package-evaluates`
fails, `evaluate level name` (`kix/package-eval.nix:696`) evaluates one
package at one level; `flake.nix:118-124` shows how the file is imported.

## Handover

1. **Self-check.** Run the `package-review` skill as written ("How to run a
   review"). Fix every blocker and should-fix.
2. **Red team.** A fresh agent, given the code and not your conclusions, runs
   package-review and BEST-PRACTICES against the change. Past passes found
   Keeper ACLs, a silently dropped config injection, and a dangerous upstream
   default (`v2_discussions/148_clickhouse_packages_plan.md:150-157, 179-188`).
   Take every finding, or record in housekeeping why not.
3. **Kind deploy.** Create the kind cluster the test cluster's header gives,
   with no default CNI so Cilium from the test cluster enforces policy. A
   package with a `zone` mapping is also deployed on three zoned workers; no
   committed config combines zones with no default CNI, so put this one in
   the test cluster's header:

   ```yaml
   kind: Cluster
   apiVersion: kind.x-k8s.io/v1alpha4
   networking: { disableDefaultCNI: true, podSubnet: "10.244.0.0/16" }
   nodes:
     - role: control-plane
     - { role: worker, labels: { topology.kubernetes.io/zone: a } }
     - { role: worker, labels: { topology.kubernetes.io/zone: b } }
     - { role: worker, labels: { topology.kubernetes.io/zone: c } }
   ```

   Deploy with `nix run .#kix -- deploy <cluster> --flake ./clusters
   --context <context> -y`, taking the cluster key and context from the
   header (`scripts/kind-operators.sh:49`; add `--timeout` for a slow first
   start, `clusters/test-keycloak.nix:12-14`). Run clusters one at a time.
   Kind finds what evaluation cannot: a wrong uid, a duplicate extension, a
   cross-namespace `untrackedRef`, a config-kind readiness condition. Fix
   real bugs in the package. At a genuine environment wall (a kernel module,
   read-only sysfs, hugepages) use an upstream knob, confine the part in the
   cluster file, and state the limit in the header and the pull request.
   Packages are not bent to fit kind.
4. **Docs and skills.** Update what the change touched (file list, items 13
   and 14). The pull request lists the upstream facts with their paths, the
   checks run and their results, what could not be verified, and the
   housekeeping entries filed. When a package-review item proved wrong, add a
   "Checklist feedback" line and fix that skill in the same change.
5. Nothing merges without the user.
