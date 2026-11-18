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
| The values a package is judged against | `PRINCIPLES.md`; `docs/src/content/docs/explanation/packages-and-clusters.mdx`; `docs/src/content/docs/explanation/availability-levels.mdx` |
| The package file contract and option contract | `docs/src/content/docs/reference/package-anatomy.mdx`; `docs/src/content/docs/reference/resources-and-out.mdx`; `.claude/skills/kix-migration/SKILL.md` "Package Anatomy" (line 78) and "Package Meta" (line 780) |
| Second implementation of an alias, facades, operator stacks | kix-migration "Two Implementations, One Alias" (line 870) and "Operator-Managed Stacks" (line 818); `.claude/skills/kix-migration/MULTI_COMPONENT.md`, `STORAGE.md`, and `SECRETS.md` |
| CRDs and operator RBAC | `.claude/skills/crd-vendoring/SKILL.md`; `docs/src/content/docs/reference/secrets-crds-and-rbac.mdx` |
| Any prose, including comments and the header | `CLAUDE.prose.md`, `CLAUDE.md` "Code comments" |
| Logging what you notice and do not fix | `CLAUDE.housekeeping.md` |
| Moving a package to a newer upstream version | "Upgrading the version a package pins" at the end of this file |

Read `PRINCIPLES.md`, the package-review checklist headings, and the closest
reference package in full before writing; open the rest when a decision
needs it. Starting points by shape: a web application on PostgreSQL,
metabase; the same with URL-shaped credentials, vaultwarden; an application
on PostgreSQL and a ClickHouse facade with migrations in an init container,
plausible; a server with a per-consumer facade, clickhouse and
clickhouse-database; an operator and its kinds, cnpg-operator and
cnpg-cluster.

Where reference documentation disagrees with `kix/lib/` or a reference
package in the pattern table below, the code wins.

## Setup

- One git worktree per package, outside the checkout (`../kix-wt/<name>`).
  If one exists, check `git -C <path> status` and its log; reuse it when it
  holds no work, and rebase it on `origin/main` before the review, or the
  reviewer's diff against `origin/main` shows main's newer commits reversed.
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
| 1 | Shape and boundary | tier, stable or experimental, one package or several, facade or not, CRD route | a restart (L4, I9, C1) |
| 2 | Upstream research | the facts every later decision is derived from | every decision made on a guess |
| 3 | Availability | the `pick` table per workload, ceilings and their evidence, strategy | every builder and the header (W1, W4, O19) |
| 4 | Contracts consumed, provider fixes | build args, the contract holding each, what providers must add | every consumer wire and the `out` shape (D5, D30) |
| 5 | Contract provided | `out`, alias, `meta.scope`, `meta.lifecycle`, `conflictsWith` | every consumer written against it (D9, D25, M6) |
| 6 | Secrets | purpose-named secret deps, keys, how the program reads them, rollout | options, env, args guard, and fixtures at once (S1, S2) |
| 7 | Escape hatches and locks | which hatches exist and what each may not touch | a re-read of the whole wiring (E3, E6, E8) |
| 8 | Option surface | which upstream knobs are typed, required inputs, refused combinations | descriptions, docs, fixtures, and tests (O6, O7, O9) |
| 9 | Monitoring and alerts | metrics wiring, the failure modes that become alerts | the rules test and the header |

### 1. Shape and boundary

- Tier (`docs/src/content/docs/explanation/helm-integration.mdx` `#evaluating-helm-charts-at-build-time`, `docs/src/content/docs/reference/helm-and-imports.mdx`): a package with consumers is native (tier 3).
  `importChart` (tier 2) is for a chart whose values you only lock and pass
  through; once the package reads or computes a field inside the chart, go
  native. A chart's singleton default, hooks, and release-name prefixing are
  not evidence of anything (L6, E11, W22).
- Level: stable or experimental. A new package starts in
  `kix/packages/experimental/<pkg>/` unless the maintainer says otherwise,
  and a cluster names it `packages.experimental.<pkg>`. An experimental
  package may break in any release. A stable package
  (`kix/packages/stable/<pkg>/`) breaks only in a minor release and reads
  only stable contracts. An experimental package may read
  `kix.contracts.experimental.<name>` too, and may share a stable package's
  name as a rework of it. No package is named `stable` or `experimental`.
  The package graduates when its folder moves to `stable/`. This skill
  writes paths as `kix/packages/experimental/<pkg>`. Read `stable` there for
  a stable package.
- One package per upstream unit. A multi-component application stays one
  package (`docs/src/content/docs/explanation/packages-and-clusters.mdx` `#packages-versus-instances`). A component other packages would
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
  (C21). Every declaration sets `holdsData`: `true` when deleting a custom
  resource of the kind loses data (a database, a storage pool, a backup),
  `false` otherwise (C24). A stateful package that renders a custom resource
  of a kind without it fails to build.
- Admission webhooks: Kix applies webhook configurations in `requires` order,
  so the package sets the order. When the operator does not read or patch its
  webhook configuration at startup, the configuration `requires` the workload
  that serves it, so the API server never calls a webhook whose pods are not
  ready. When it does (it writes its certificate into `caBundle` at startup,
  as CloudNativePG does), the workload requires the configuration, and every
  CRD handle makes its custom resources wait for a check Job (`cnpg-operator`,
  C21). Either way, the deploy's dry run treats an unreachable webhook as not
  checked only when the deploy writes the webhook's Service or another object
  of the package; otherwise the deploy stops before it writes anything (C26).

### 2. Upstream research

Read at the pinned release, in source, not in the chart. Each fact settles a
named decision; record the fact and its upstream path in the pull request.

| Upstream source | Extract | Settles |
|---|---|---|
| Runtime config loader (`config/runtime.exs`, `settings.py`, `config.go`) | every variable, which are required, which are URL-shaped credentials, which are credentials a user would set (API keys, SMTP passwords), which need a restart, and the branch each `raise` sits in (one adapter, one mode) | option set and types (step 8); what comes from a dep's `out`; `keyRef` per variable or `$(VAR)` expansion into an owned URL, with its escaping limit (step 6); the credential names `env` refuses as literal strings (step 7); refusals scoped to the branch that raises |
| Config sources besides the environment (a config directory read before env, `_FILE` twins, a config file path variable) | every path that can override a variable the package owns | owned names (E8): own the directory or path variable too |
| Dockerfile and entrypoint | `USER`, uid, writable paths, `$HOME`, start command, whether the entrypoint migrates, what the runtime listens on by default (Erlang distribution, JMX, debug ports) | numeric `runAsUser`, emptyDir mounts (W12), `enableServiceLinks` (W16), init container or Job, variables that close default listeners (W18) |
| Upstream's own deployment files (compose file, systemd unit, install script) | `ulimits`, `sysctls`, tmpfs mounts, the exact start and migrate commands | runtime limits the image does not state: a BEAM or JVM sized from `nofile` needs an env cap (`ERL_MAX_PORTS`), or the pod is OOM-killed at start on a runtime whose limit is the kernel maximum |
| Migrations, data migrations, and startup queries | `CREATE EXTENSION`; every privilege the statements need on the provider's pinned version, including global objects (`CREATE OR REPLACE` needs DROP too) and reads of system catalogs; `CREATE DATABASE` steps a facade makes unnecessary; advisory locks; whether two pods may migrate at once; engine or table types that only work on one topology | injected extensions or privileges (step 4), Recreate or RollingUpdate (W8), a replica ceiling, a refusal of a provider topology |
| Outbound calls (HTTP clients, mailers, updaters, favicon or geo downloads) | each destination and port, whether it is required or cosmetic | egress under default-deny: a static intent, a policy built from config (pattern table, "Config-derived egress"), or a header line naming what stays unreachable |
| Health endpoints | what each endpoint checks; whether liveness dials a dependency | probes (W13), startup deadline (W14) |
| Metrics | port, whether on the public port, auth, the flag that enables them | `kix.monitor` wiring (Mo11, Mo12) |
| Clustering and HA, in source | in-memory state, sessions, caches, job queues, leader election, peer discovery, cron singletons | the `pick` table and any ceiling (step 3) |
| Monitoring material and failure reports | shipped rules or mixins, outage threads | alerts (step 9) |
| Admission webhook configurations (chart templates, `config/webhook/`, the controller's startup code) | whether the controller reads or patches its own configuration at startup (certificate injection into `caBundle`), and whether it fails to start without it | which object requires which, and whether CRD handles need a check Job (C21, C26) |
| CRDs (chart `crds/`, `config/crd/bases/`, release bundle) | public URL at the tag, conversion webhooks, condition types and which of them the controller sets for a spec it rejects and does not revisit, which status field holds the generation the controller has acted on and whether `status.observedGeneration` means that, whether a spec change can wait for a restart of the running workload, what the operator deletes with each custom resource (its volumes, its backup files) | `crds/sources.txt`, readiness (C5), its `failed` list (C6a), its `observedGeneration` and `pendingRestart` (C6b), `holdsData` (C24) |
| Kubernetes client calls, for a program that calls the API with RBAC not vendored from upstream (crd-vendoring covers vendored roles) | every call (list, get, watch, create, update, patch, delete, deletecollection) on every resource and subresource (`pods/log`, `<kind>/status`), at startup and in every code path | the Role: one rule per call, nothing extra (C10, C23) |

"Does it run replicated, and what does it need for that?" is a mandatory
question, answered from source, not from the chart's default.

Collect a whole class at once rather than meeting it one deploy at a time:
`grep -rhoE "system\.[a-z_]+"` over the source and migrations for catalog
reads, every `CREATE`, `DROP`, or `GRANT` of an object outside the app's
database, every `System.get_env`/`os.environ` name.

Worked example, Plausible CE (`kix/packages/experimental/plausible`):
`config/runtime.exs` takes `DATABASE_URL` and `CLICKHOUSE_DATABASE_URL` as
URLs, so the credentials are `$(VAR)` expansions into owned variables. It
reads every setting from a file in `CONFIG_DIR` before the environment, so
the package owns `CONFIG_DIR`. The ClickHouse migrations run `CREATE OR
REPLACE FUNCTION` and read four system tables, which ClickHouse 26.3 guards
with grants: a provider gap, fixed by a `grants` option on
clickhouse-database that the consumer injects. They also create plain
`MergeTree` tables on a fresh install, and switch to replicated tables only
once the tables already are, which no provider can fix. The consumer runs
the migrations on one replica (the contract's `replicaHosts`) and a second
init container converts the tables and creates them on the other replicas
(`plausible/replicate.py`). Not every upstream fact becomes a provider fix,
and a single-server assumption in an upstream's schema is a step for the
package to add before it is a reason for a ceiling.
The image's Erlang distribution listens on every interface with a cookie
shared by every copy of the image, so the package sets
`RELEASE_DISTRIBUTION=none`. The compose file's `nofile` limit is why it
sets `ERL_MAX_PORTS`; kind found that one.

### 3. Availability

The package honours the cluster's level. If the cluster asks for `zone`, the
package runs replicated at `zone`, and so do its dependencies. A singleton
is a finding from the upstream source, not a default.

1. Name `availability` in the package function (the lib passes only named
   arguments) and start from replicated:
   `kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 2; }`.
   Quorum systems use odd counts (rabbitmq-cluster); leader-elected
   controllers follow W6. Two copies survive the loss of one pod, node, or
   zone, provided they are spread across it, so `zone` needs no more than
   `node`; a quorum (Keeper, etcd, RabbitMQ) is the exception, with three,
   one per zone at `zone`. At `zone`, check that the replicas really are
   spread across zones (item 6 for operator-placed pods); the count does
   not spread them.
2. Check in source: shared in-memory state and whether a dependency (Postgres,
   Valkey) replaces it; leader election or an HA flag; migrations that are not
   concurrent-safe (then Recreate, keycloak:83-88); session affinity (a
   Service setting, not a ceiling); cron or queue singletons (a ceiling on that
   workload only, or upstream's "run the scheduler in one pod" flag); one RWO
   volume as the state (immich:157-159); one owner of an OS resource,
   such as a network interface. For each piece of in-memory state, also note what a
   restart loses (sessions, buffered events), since Recreate and a singleton
   make every deploy a restart; the header's `Limits:` says it.
3. If it replicates with configuration, configure it (keycloak's jdbc-ping,
   header 74-81).
4. A ceiling needs evidence from upstream source, in the comment beside it
   and in the header's `Limits:` line (grafana:67, 425; tempo:37). A
   program-wide limit is `meta.availability.max = "none";`; a limit that
   depends on config, wiring, or one workload is `availability.max` on that
   builder (pattern table, "Ceilings"). W4 and W5 cover the singleton form:
   a literal `replicas = 1` under the `none` ceiling.
5. Load-serving workloads: O19 (the option form is the pattern table's
   "`pick`" row). Strategy: W8.
6. Operator-placed operands map the level into the CR (`instances`,
   `podDistribution`) and use `kix.availability.spreadConstraints` where the
   CR takes a spread list (cnpg-cluster:276); never raw anti-affinity (W2).
7. Dependencies resolve their own level from the cluster default
   (`kix/lib/eval/instance.nix:74-85`); no consumer channel raises a
   provider's level. So check the mapping of each provider the package can
   run on. A provider that caps at `none` without evidence, or a new provider
   with no mapping, is fixed in the same change (step 4); a provider the
   package refuses goes to housekeeping instead. A consumer whose
   availability depends on the provider's says so in its header.

Lib: levels and `pick` in `kix/lib/core/availability.nix:15, 55`; `resolve`
caps at the package ceiling with a warning (`:184-218`); builder ceilings in
`kix/lib/scope/builders.nix:226-280`; the plugin derives spread and
PDB from `replicas > 1`, warns on a one-replica root workload at `node` and
above, and throws on `replicas > 1` under an effective `none`
(`kix/lib/plugins/availability/module.nix:255-282, 292-323`). `every-package-evaluates`
runs each package's defaults at `none` and `zone`, so a level-dependent bug in
the defaults fails there.

### 4. Contracts consumed, and fixing the provider

- Choose by alias and contract, never by package (P10, P13). Contracts
  (`kix/contracts/stable/`, one file per name under `kix.contracts`):
  `kix.contracts.postgresDatabase`, `oidc`, `oidcProvider`, `otlpEndpoint`,
  `redis` (taken as the `redis` dependency), `clickhouse`, and `smtp`; `gateway` is held by `kix.expose`, not by
  the package. A login always travels in the provider's `out.credentials`
  (`credentialsField` in `kix/lib/vocab/contract.nix`), never in a second dependency: a
  provider Kix runs publishes its own Secret, and an outside service is a
  `kix.mkImport` in the consumer's namespace with `credentials =
  ref.<ns>.<secret>`. An application that sends mail takes `smtp ? null`
  and maps `kix.contracts.smtp.helpers.settings` onto its own settings (vaultwarden,
  grafana, plausible, immich); one that keeps mail settings elsewhere calls
  `kix.contracts.smtp.helpers.server` for the egress only (keycloak). One that signs users in takes `oidc ? null` and calls
  `kix.contracts.oidc.helpers.client` (grafana, harbor, immich).
  A contract's own functions sit under its `helpers`, and its option schema
  under `options` (`options.oidc = kix.contracts.oidc.options { ... }`,
  `options.mail = kix.contracts.smtp.options`). Consumers hold the
  dependency with `assertions`, providers pass `root.out` through `check`
  (D30; pattern table, "Contracts").
- A contract that more than one package shares is a file in
  `kix/contracts/`: `stable/<name>.nix`, or `experimental/<name>.nix` for one
  that may still change in any release (read as
  `kix.contracts.experimental.<name>`, by experimental packages only). The
  file name is the name under `kix.contracts`, and the folder listing builds
  the set, so no list needs editing. The file is a function
  `{ lib, mkContract, credentialsField, compose, ... }:` that returns the
  result of `mkContract { name; alias; fields; remedyNoun ? ; extraProblems ? ;
  helpers ? { }; options ? null; }`. Every contract then has the same parts:
  `name`, `alias`, `fields`, `problems`, `check`, `assertions`, `require`,
  `helpers`, and `options`. A field without `required` is required. The
  contract's own functions go under `helpers`
  (`kix/contracts/stable/redis.nix`).
- A package that renames a dependency sets `deps.<arg>.renamedFrom = { name
  = "<old name>"; id = "K1234"; }`, with the id of the `error` change
  record. The error for a missing dependency then carries the id and says
  what the dependency was called before (immich:192-195).
- A consumer that reads an optional field (`username`, `extensions`, `tls`)
  handles its absence on a `kix.mkImport` stand-in
  (`kix/contracts/stable/postgresDatabase.nix:1-8`, D22), and acts on it where the
  program needs telling: `tls = true` means TLS in the connection settings
  (keycloak's `KC_DB_URL_PROPERTIES`, plausible's `sslmode=require`).
- A facade with no contract file (clickhouse-database) is held through
  `deps.<x>.assertions` on the `out` fields the consumer needs
  (clickhouse-logs:104-115, plausible:213-253).
- Config the consumer injects (`deps.<x>.config`) is ignored by a
  `kix.mkImport` stand-in, so the consumer also asserts on the `out` field
  that reports the injected value (plausible checks `out.grants`).
- When the consumer needs a fact every provider can give, extend the contract
  and every provider, not the consumer. Precedent: `extensions`, injected
  through `deps.database.config.extensions`, forwarded by the facade, merged
  by name in cnpg-database (pattern table, "Config injection"). An injected
  option must be mergeable (a list or attrset), or the injection collides with
  the instance's own value.
- Fix the provider in the same change, with tests: a missing `out` field, a
  non-mergeable option, a privilege the facade cannot grant, a singleton
  default with no evidence. Test the provider with two same-named consumers
  in two namespaces; resources it puts in its own namespace collide when
  named by the instance alone. A privilege set is rarely complete from
  reading alone, so deploy on kind before settling the provider option's
  shape. Never re-derive a host, write a NetworkPolicy, or
  widen a privilege in the consumer. Some providers (the ClickHouse packages)
  are new, so a new consumer finding gaps in them is expected.
- Test a contract change three ways: `every-package-evaluates` (every provider
  and consumer re-evaluates); the contract's swap check (`clickhouse-swap`,
  `postgres-swap`, `gateway-swap`; `flake.nix:240, 275, 317`, fixtures under
  `clusters/test-*-swap/`); a lib unit test when a vocab file changed. A new
  consumer that reads fields which differ between implementations gets a swap
  fixture (`clusters/test-clickhouse-swap/consumer.nix`).

### 5. Contract provided

- Decide `out` before any resource exists: names, `fqdn`, ports, URL, operand
  selectors, `crds.<Kind>` handles, and builders only where they gate,
  default, or refuse (D9, D13). Every value that names a resource derives
  from `self.<part>.out.*` so it carries string context (D24).
- `meta.defaultAliases` when others consume it (M8); `meta.scope = "cluster"`
  when consumers in every namespace should find its one instance by name
  (an operator, an ingress controller, or an issuer) and it claims no role and
  no `cluster:` conflict (M16); `meta.scope = "namespace"`
  when it hands consumers a Secret (S9); `meta.lifecycle = "stateful"` when it
  provides state others depend on (M6), and then every custom resource it
  renders is built with `scope.mkCR` from a declaration with `holdsData`; `meta.conflictsWith` only for a
  genuine one-per-cluster package (M9).
- Publish every `out` field at every toggle, null when off (D25).
- Publish `out.version = kix.image.version config.image;` when the package
  has a `meta.version` and an image the user can change (I11). Read the
  image of the main software, never a helper's (I12). The PackageInstance
  record, `kix plan`, and a consumer's `compatibleWith` check then report
  what the instance runs. `meta.version` is the default release, without a
  `v` prefix (M2).

### 6. Secrets

One purpose-named dep per credential, bound once through
`kix.contracts.secret.helpers.use` (S3, S4; `SECRETS.md`). Never a string or
path option for a credential, and never a Secret's name: the test
`secret-options-none-take-a-secret` (`kix/lib/tests/units/secret-options.nix`)
fails the build of the package set, for stable and experimental packages
alike. An option that only matches by name goes in
`kix/packages/not-secret.nix` with the reason. A package that needs the
value in a second namespace renders a copy only from `dep.out.sops`, and
otherwise references a Secret the site writes there (stackgres-database).
The dependency is what lets the site choose between a
value in the build, a SOPS file, and a Secret an operator writes, and what
`cluster.secrets.accept` checks (S1, S16; `docs/src/content/docs/reference/cluster-configuration.mdx` `#clustercontainerd-clustermaintenance-and-clustersecretsaccept`). Configuration
the program reads from a Secret gets a non-Secret route or a dependency
beside the rendered Secret, which is classified `configuration` (S15;
alertmanager, victoria-metrics-alert). Discrete variables take
`keyRef` values; a URL-shaped credential takes `credentials.out.mkEnv` for the
parts and `$(VAR)` expansion in an owned variable. That leaves the password
unescaped inside the URL, so it is a `Limits:` line (vaultwarden:38-40).
Rollout through `"checksum/<name>" = <res>.out.contentHash` or `reloader.out.withReloadOn` (S10). The
pattern table has each form.

### 7. Escape hatches and locks

- The hatch set is E1's.
- Derive the lock lists from the DI wiring, because they are the same list:
  every path, flag (all spellings), and variable the package computes from a
  dependency or option is locked through `kix.mergeGuarded`, `kix.guardArgs`
  (owned flags derived from the owned env groups), and `kix.mergeEnv` owned
  groups (E3, E6, E8; pattern table).
- `env` accepts strings, so refuse the program's credential variables as
  literal strings (pattern table) and point at a `secretKeyRef` to a Secret
  managed outside Kix or at the secret dep (S1).
- Bind `who = "<pkg> ${scope.namespaceName}/${name}"` once in the `let` and
  pass it to every helper (Pr9).

### 8. Option surface

Type only what the package reads or derives from (O6, O7). Refuse at
evaluation every combination evaluation can see, with a negative test and a
positive control (O15, T2). Defaults are public-safe; a site's value goes in
the cluster file (L1, L2). The migration guides' "match the cluster" refers
to that cluster override, never to the package default.
A refusal for a removed or renamed option starts with its change record's
id in brackets, such as `[K0001] <pkg>: ...`. Take the id from
`scripts/change-records.py next-id` (O26). People search CHANGELOG.md
for the id, and tools match it.

### 9. Monitoring and alerts

Follow package-review "Writing a package's alerts" and `docs/src/content/docs/reference/composition-helpers.mdx` (`#monitor`).
The pattern table gives the `kix.monitor`, `kix.alerts`, and metrics-toggle
references.

## Writing the package

### Header

The header is the package's contract for a reader who will not open the code
(Pr2). Order, with the labels new packages use (older packages also carry
`DI deps:` and `Exposes:`; do not copy those):

1. `# <directory name>: <what it runs>`, then what it installs.
2. `Dependencies:`, one per line, `(required)` or `(optional)`, what each
   brings.
3. A minimal instance that the test cluster evaluates (T5).
4. One paragraph per operational fact, with network policy last (metabase:48-74
   is the model).
5. `` `out`: `` the fields consumers read.
6. `Escape hatches:` the hatches and their locked paths.
7. `Limits:` ceilings with the upstream reason and where each is declared,
   what a restart loses, untested paths, host prerequisites (tempo:37,
   falco:46).

A comment that states an upstream fact names the upstream path, and copies
numbers from the source rather than memory (a reviewer found "65536
matches compose" where compose says 65535). A behaviour observed only on a
deploy says where it was observed. Operators add
   `Replicas:` and `Moving to another release:` (cnpg-operator:49, 99).
   A version that existing installs cannot take with a plain deploy adds
   `Upgrades:`, saying what an operator does first (clickhouse-cluster:28).

### Errors

Raise an error a person must fix with `scope.fail`, never a bare `throw`.
Give `message` (what is wrong), `fix` (what to change), and, when they
apply, `id` (the change record id of a removed option, such as `"K9503"`),
`option`, `dependency`, or `clusterOption`. `option` is a path in the
instance's `config` without the `config.` prefix (`"tls.secretName"`),
`dependency` is a name in its `deps` (`"database"`), and `clusterOption` is
a path in the cluster definition (`"cluster.roles.cni.binding"`). A `meta`
field is not an option, so leave `option` out. Start `fix` with a capital
letter. `scope.fail` adds the instance, so the message does not start with
a `who` prefix. Pass a list to report several problems at once
(cluster-issuer). An assertion takes the same `fix`, `id`, `option`,
`dependency`, and `clusterOption` fields. Kix shows these errors from their fields, without a
stack trace (`docs/src/content/docs/reference/package-anatomy.mdx`,
"Raising an error with `scope.fail`"). The database packages'
`_passwordCheck` is the model (cnpg-database).

### Jobs

Kubernetes may run a Job's pod more than once on its own: it retries a
failed pod up to `backoffLimit`, restarts the container under
`restartPolicy = "OnFailure"`, and starts a new pod after an eviction or a
node drain, possibly after the work finished. Kix runs a Job under
`kix.run/rerun` again when its own content changes. So every Job a package
writes must give the same result when it runs again. Check whether the work
is done and stop early, or make each step idempotent (`IF NOT EXISTS`, an
existence check before `CREATE`, an upsert, `kubectl annotate --overwrite`).
Never generate a secret or append to a log in the Job without checking first
(stackgres-database's bootstrap script is the model).

A Job with `kix.run/rerun` reruns when its own manifest changes, including
any `checksum/*` annotations on its pod template. It also reruns when a
Kix-built Secret or ConfigMap read by its pod (through a volume, `env`, or
`envFrom`) changes; the Kix library includes those reads in
`kix.run/rerun-hash`, so do not add `checksum/*` annotations for them. Add a
`checksum/<name>` annotation set to `out.contentHash` on the pod template
only for resources the Job reaches over the network or the Kubernetes API
that should trigger a rerun (such as a server it bootstraps or a webhook it
checks), and omit those resources from `requires`. Kix does not know the
content of a `secret-ref` Secret, so changes to it never rerun the Job;
document this in the package header when relevant.
A change elsewhere in the graph, such as a namespace label, does not run it.

### Pattern to reference package

The only place in this skill with package line numbers. `pkg:N` is
`kix/packages/stable/pkg/default.nix:N`.

| Pattern | Reference |
|---|---|
| Release binding, digest, `who`, `startupSeconds` in one `let` | metabase:89-97 |
| Shared release file for a release group | `immich/release.nix`, immich:107 |
| Running version published from the image (`out.version`) | echo-server:228; among several images, valkey |
| Follower image tag with `tagText` and `mkDefault` | n8n:268-275, 308 |
| `kix.contracts.secret.helpers.use`, read through the binding | metabase:158-163, 208, 264 |
| `mergeEnv` defaults and owned groups | metabase:168-232 |
| Discrete database variables through `keyRef`, owned `_FILE` twins | metabase:187-203 |
| URL-shaped credential through `$(VAR)` | vaultwarden:143-147, 212-233 |
| `guardArgs`, owned flags from owned env groups | keycloak:398 |
| `mergeGuarded` on `settings` or `extraSpec` | tempo:386; cnpg-cluster:323, 430, 514 |
| Migrations at start: Recreate, deadline from `startupSeconds`, probes | metabase:94-97, 252-256, 284-304 |
| Config injection into a dependency | metabase:109-112; stackgres-database:120-125; cnpg-database:94-115 |
| Contracts: consumer `assertions`, provider `check` | metabase:112; stackgres-database:554; keycloak:559; tempo:631 |
| `pick` as an option default with `defaultText` | `cnpg-cluster/options.nix`:12-18 |
| `pick` inline, header names the instance override (O19) | keycloak:256, header 74-76 |
| `atLeast` | valkey:122 |
| Ceilings: package-wide, per builder | tempo:276; valkey:561, `harbor/registry.nix`:245, `harbor/jobservice.nix`:338 |
| `kix.expose`, `exposure.urlOrNull` | metabase:172-175, 367 |
| Metrics toggle that does not restart the workload | metabase:152-157; keycloak header 30-35 |
| `kix.monitor` with alerts | openbao:393; clickhouse:626-636 and `alerts.nix` |
| `kix.alerts` over a PodMonitor | `cnpg-cluster/alerts.nix`:54 |
| `kix.healthCheck` with a script file | victoria-metrics-agent:358-375 |
| Checksum annotations from `out.contentHash`, `enableServiceLinks = false` | metabase:258-271 |
| Facade: consumer-namespace Secret, server-namespace Job | clickhouse-database:1-36; stackgres-database |
| Facade resources in the server's namespace named with the consumer's namespace | clickhouse-database:356 (`serverSideName`) |
| A Job that runs again when its content changes: a fixed name, `kix.run/rerun` (never a hash in the name), and `checksum/*` only for resources reached over the network or the Kubernetes API | stackgres-database:449-465; clickhouse-database:506-523 |
| Privileges injected into a facade, with the upstream file for each, and asserted on `out` | plausible:183-195, 213-253 |
| Migrations in an init container sharing the server's env and mounts (`kix.withMountsOn [ "migrate" "plausible" ]`) | plausible:620-626, 693; vaultwarden:180-202, 277 |
| One volume written by an init container and read by the main containers (two mount records, one `readOnly`) | n8n:499-513, 679-680 |
| Literal credentials refused in `env` | plausible:338-358 |
| Config-derived egress (a port read from config) through `kix.operandPolicy` | plausible:712-737; cnpg-cluster:591-656 |
| A step after the migrations on one replica of a dependency: an init container running a sibling script from a ConfigMap, with a checksum annotation | plausible:518-561, 605-606; `plausible/replicate.py` |
| One alias, two implementations, a contract file | `kix/contracts/experimental/clickhouse.nix`; clickhouse:101, clickhouse-cluster:90 |
| Renamed dependency with `renamedFrom` | immich:192-195; `kix/contracts/stable/redis.nix` (`helpers.renamedFrom`) |

A script of more than a few lines is a sibling file read with
`builtins.readFile`, so it can be linted and run alone
(`clickhouse/health-check.py`, shared with clickhouse-cluster).

Kix evaluates Nix expressions in its local store and writes files with `builtins.toFile`
(and renders Helm charts through `scope.helm.*`), but it cannot run Nix
derivation builds (`pkgs.runCommand`, `pkgs.stdenv.mkDerivation`,
`pkgs.writeText`). Never use a derivation builder inside a package or cluster
definition.

## The files a complete change touches

Mandatory:

1. `kix/packages/experimental/<pkg>/default.nix`.
2. `kix/package-eval.nix`: a `settings` entry when the package needs deps or
   config to evaluate at `none` and `zone` (`:105`; keycloak at `:312-330`).
3. `clusters/test-<pkg>.nix`: every toggle on, each optional dependency
   present at least once, a `cilium` instance and `networkPolicy.enable = true`
   so the kind deploy runs under default deny, and the bring-up, build, and
   deploy commands in the header (`clusters/test-clickhouse.nix:13-21`,
   `clusters/test-keycloak.nix:1-15`). A dependency from an unmerged change
   is a `kix.mkImport` stand-in; note the merge order.
4. Nothing in `flake.nix`: `clusters/test-<pkg>.nix` registers itself under
   the key `<pkg>`. A cluster kept in a directory, such as
   `clusters/test-<pkg>/kind.nix`, needs a line under `clusters` there.
5. `kix/lib/tests/units/<pkg>.nix`: names `<topic>-<what>`, helpers as in
   `kix/lib/tests/units/keycloak.nix:8-19`. Each `evalFails` has a positive
   control (T2). Two instances in two namespaces (Na2, Na10) and each
   optional dependency absent (D15) are evaluated here with `mkCluster`, so
   they are committed, not a scratch run.
6. `housekeeping/YYYY-MM-DD-slug.md` for each problem noticed and not fixed
   (`grep -ril <keyword> housekeeping/` first).
7. `ROADMAP.md`: the package under "Service catalog (prebuilt packages)" with
   release and evaluated or deployed status; gaps found in Kix become items.

Conditional:

8. `clusters/test-<pkg>.rules-test.yaml` when the package ships alerts
   (auto-discovered, `kix/lib/mkFlake.nix:152-170`).
9. `kix/contracts/stable/<name>.nix` (or `experimental/<name>.nix`),
   `kix/lib/tests/units/<contract>.nix`, and `kix/lib/architecture.md` for a
   new contract. A new field on any contract: `git grep -n` an existing field
   name to find every list of fields (`docs/src/content/docs/reference/`, the kix-migration
   skill) and add it there.
10. Provider packages the consumer exposed gaps in, with their tests (step 4).
11. `crds/` with `crds/sources.txt`, and `rbac/` (crd-vendoring skill); sibling
    files such as `health-check.py`, `release.nix`, and `alerts.nix`.
12. `clusters/test-<contract>-swap/` for a second implementation of an alias,
    and `flake.nix` to add both clusters to `clusters` and a `<contract>-swap`
    check to `checks`.
13. `docs/src/content/docs/reference/` and `docs/src/content/docs/explanation/`,
    and the kix-migration, package-review, and crd-vendoring skills and this
    one, when a lib API, role, `meta` key, or convention changes (T6).
14. `kix/lib/eval/roles.nix` and `kix/lib/flavors/*.nix` only for a new role.

## Verification ladder

Cheap first. Each step assumes the earlier ones pass.

```bash
F=--extra-experimental-features; P=pipe-operators
git add -A kix/packages/experimental/<pkg> clusters kix/lib/tests                     # 0. the fetcher sees nothing untracked
nix build .#cluster-<cluster> $F $P                                      # 1. the test cluster, every toggle on (use ./scripts/kix-manifests.sh . <cluster> ./result if it uses Helm); read its traces
nix build .#checks.x86_64-linux.every-package-evaluates $F $P            # 2. defaults at none and zone, option contract, settings entry
nix build .#checks.x86_64-linux.kix-lib-tests $F $P                      # 3. unit tests, negative tests with controls
nix build .#checks.x86_64-linux.rules-cluster-<cluster> $F $P            # 4. promtool check and the .rules-test.yaml (alerts only; use ./scripts/cluster-checks.sh if the cluster uses Helm)
nix build .#checks.x86_64-linux.{clickhouse,postgres,gateway}-swap $F $P # 5. the contract's swap check (contract changes only)
nix shell nixpkgs#uv -c uv run --frozen scripts/vendor-crds.py --check   # 6. CRDs only
nix run .#kix -- check homelab-kind                                       # 7. smoke over the full package set
```

`<cluster>` is the key under `clusters` in `flake.nix`. When `every-package-evaluates`
fails, `evaluate level name` (`kix/package-eval.nix:742`) evaluates one
package at one level. From the worktree root, with `$PWD` absolute:

```bash
nix eval --impure --raw $F $P --expr "let f = builtins.getFlake \"$PWD\"; lib = f.inputs.nixpkgs.lib;
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  r = import $PWD/kix/package-eval.nix { inherit lib; kix = import $PWD/kix/lib { inherit pkgs lib; }; };
  in builtins.deepSeq (r.evaluate \"zone\" \"<pkg>\") \"ok\""
```

One lib test: `nix eval --impure $F $P --expr '(import ./kix/lib/tests { }).tests.<name>'`.

Start the kind cluster (handover step 3) as soon as the test cluster
builds, in the background: for a package whose risk is at runtime
(migrations against a provider's version, privileges, runtime limits) the
deploy is the slowest and most informative step.

## Handover

1. **Self-check.** Run the `package-review` skill as written ("How to run a
   review"). Fix every blocker and should-fix.
2. **Red team.** A fresh agent, given the code and not your conclusions, runs
   package-review and `docs/src/content/docs/explanation/packages-and-clusters.mdx` against the change. Past passes found
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

   Deploy with `nix run .#kix -- deploy <cluster> --context <context> -y`,
   taking the cluster key and context from the
   header (`scripts/kind-operators.sh:49`; add `--timeout` for a slow first
   start, `clusters/test-keycloak.nix:12-14`). Run clusters one at a time.
   Kind finds what evaluation cannot: a wrong uid, a duplicate extension, a
   cross-namespace `untrackedRef`, a config-kind readiness condition, a
   missing grant, a runtime OOM-killed by its own `nofile` sizing. Fix real
   bugs in the package.

   While the deploy waits out a CrashLoopBackOff, read the failing
   container's logs (`kubectl logs <pod> -c <init container> --previous`)
   instead of waiting for the verdict. A change only to a dependency (a
   facade's grants) leaves the consumer's pod template unchanged, so delete
   the crash-looping pod once the dependency's Job completes. A first deploy
   halted part way (a transient image pull error) can leave a webhook
   configuration without its Service. The next deploy writes the Service
   again, so its plan lists the custom resources the webhook guards as not
   checked. If the Service was deleted and the build did not change, the plan
   refuses them instead; `kix deploy <cluster> --reconcile` writes the Service
   again.
   End with one request through the real path (an event in, a row out), not
   only green probes. At a genuine environment wall (a kernel module,
   read-only sysfs, hugepages) use an upstream knob, confine the part in the
   cluster file, and state the limit in the header and the pull request.
   Packages are not bent to fit kind.

   The program runs as the package's own ServiceAccount, never with an
   admin kubeconfig. Check each rule from the client-call research:
   `kubectl --context <context> auth can-i <verb> <resource> -n <ns> --as
   system:serviceaccount:<ns>:<sa>`. A list or watch at startup is the
   usual miss.

   A fresh install misses what breaks clusters already running the
   package. So, on a new kind cluster, deploy the package as it is on main,
   then deploy the change on top:

   ```bash
   git fetch origin && git worktree add ../kix-wt/main origin/main
   nix run .#kix -- deploy <cluster> --flake ../kix-wt/main --context <context> -y
   nix run .#kix -- deploy <cluster> --context <context> -y
   ```

   The second deploy applies with no extra flag (`--accept-migrations`,
   `--force-conflicts`, or any other the fresh install did not need) and
   reaches ready. An object its plan deletes or keeps as an orphan is one
   existing installs lose. This catches a new required input that existing
   installs lack (a Secret the new version reads), a data migration in a
   stateful package (an object renamed, or replaced by one of another kind
   when both hold data by their `kix.run/holds-data` annotation), renamed or
   removed objects, and an immutable field that needs the object recreated. A
   deliberate breaking change that cannot pass says in the header's
   `Upgrades:` paragraph what an operator does. A new package has nothing
   on main; skip this deploy.
4. **Docs and skills.** Update what the change touched (file list, items 13
   and 14). The pull request lists the upstream facts with their paths, the
   checks run and their results, what could not be verified, and the
   housekeeping entries filed. When a package-review item proved wrong, add a
   "Checklist feedback" line and fix that skill in the same change.
5. Nothing merges without the user.

## Upgrading the version a package pins

A version bump is rarely one line. Upstream moves ports, probes, flags,
RBAC rules, and the image's user between releases, and files outside the
package cite the version. The work is done when `scripts/check-bump.sh`
prints `check-bump: PASS` and the upgrade deploy below has run.

### Order of work

1. Decide the target and read what changed upstream.
2. Deploy the old version on kind and write state, before you edit any file
   of the package. Editing first forces you to undo the edits to get the old
   version back.
3. Edit and commit.
4. Run `scripts/check-bump.sh <package-dir> <old-version>` until it passes.
5. Deploy the new version over the old one, verify, and test going back.

### The target and the upstream changes

- The target is the latest stable upstream release, unless the task names
  another. When you stay on an older line, name the newer release and say
  why you did not upgrade to it. Confirm the target's images exist for every
  platform the old ones did: a release whose image publishing failed is
  followed by a fix release.
- Read the notes of every release between the pinned version and the
  target. Release notes omit what a package depends on. Also compare
  upstream's own deployment files between the two versions (manifests, Helm
  chart templates, the Dockerfile, the default config) for ports, probes,
  flags, environment variables, RBAC rules, the image's user, and files the
  image now ships. A package that copies any of these follows them.
- Write down what upstream says about which versions can upgrade directly
  to which, and about going back. Upstream often says nothing. Then say
  what you learned from its source or from testing.
- Find the Kubernetes versions the upstream project supports for the target
  release, and note where it states them. Prefer an explicit support policy,
  compatibility matrix, or requirements page. Fall back to the versions
  upstream tests in CI or end-to-end runs only when it states no support
  range, and use `go.mod`'s `client-go` version only as a last resort. This
  range goes in `meta.k8s.supported`, which warns when `k8sVersion` falls
  outside it.
- Check whether anything fails outside that range. Count only concrete
  incompatibilities: an API version the package emits or the workload reads
  that older Kubernetes releases do not serve, a CRD validation rule added in
  a specific Kubernetes version, a startup version check in the upstream code,
  or a confirmed upstream failure report. Do not treat a support table alone
  as proof that other versions fail. Confirmed failure bounds go at the top
  level of `meta.k8s`, which fails the build.

### The edit

- Record upstream's supported or tested versions in `meta.k8s.supported`
  using `minVersion`, `maxVersion`, and a `source` naming the document or
  workflow. For an open-ended range ("1.25 and later"), set only `minVersion`
  (or only `maxVersion`). When upstream neither states nor tests a Kubernetes
  version range, omit `supported` and note that in the pull request.
- Set top-level `meta.k8s.minVersion` or `meta.k8s.maxVersion` only when you
  have concrete evidence that versions outside that bound fail, and explain
  what fails and how to fix it in `reason`. If a new bound rejects a version
  the package previously accepted, add an `error` change record and start
  `reason` with its ID in brackets (`[Kxxxx]`).
- Before you set a hard bound, check whether the package can leave out the
  one feature that fails. `clusterConfig.k8sVersion` is available in `build`,
  and `kix.version.atLeast` compares it. `kube-state-metrics` turns off the
  collectors whose API the cluster does not serve and drops their kinds from
  its ClusterRole, so it refuses nothing. A cluster with no `k8sVersion`
  keeps upstream's default.
- Add or update the package's entry in `ranges` in
  `kix/lib/tests/units/k8s-window.nix`, listing versions for `accepts`,
  `warns`, and (when top-level `meta.k8s` sets a bound) `refuses` and any
  `[Kxxxx]` `id`.
- Every stable package must accept all Kubernetes versions in the release
  window (`kix/lib/core/kubernetes.nix`), enforced by the
  `k8s-window-stable-packages-cover-it` test. If an upstream upgrade drops a
  version in that window, keep the package working across the window or hold
  the upgrade. Moving the release window is a release decision, so ask first.

- List every image the package renders, including images an operator is
  told to deploy, and decide for each whether it moves.
- Pin the multi-arch index digest of each new tag. Check your lookup first:
  it must return the digest the package already pins for the old tag.
- Re-vendor CRDs and roles with `scripts/vendor-crds.py` (crd-vendoring
  skill).
- Add or update the header's `Upgrades:` paragraph. It says whether the new
  version works with what the old one left behind, whether going back
  works, and what an operator does to go back.
- Add a change record. Its text tells the user what changes for them and
  what to do. Choose the kind from what a user who upgrades gets, and name
  the other kind you considered in the pull request.

### Files outside the package

`scripts/check-bump.sh` finds these and lists every place the old version
still appears. Update each place, or say why it stays.

- `cli/kix-cli/tests/snapshots/` when the package is in the example
  cluster. The snapshots hold hashes that change too, so regenerate them
  instead of editing them directly. From `cli/`: `nix develop .. -c env
  INSTA_UPDATE=always cargo test -p kix-cli --test snapshot_test`.
- `docs/src/command-output/`: leave these files alone. Each Kix release
  regenerates the captured command output in the docs, so
  `scripts/check-bump.sh` skips them.
- `kix/lib/tests/units/`: a test that names the next version as one the
  package must refuse fails after the bump. Move it up.
- `ROADMAP.md`, where the package's entry cites its release.

### The upgrade deploy

Use the package's test cluster (file list, item 3) and the kind deploy in
"Handover", step 3, with these additions.

1. Deploy the old version. Confirm it works by using it, and do not rely on
   pod status alone.
2. Write state that exercises what the package stores or manages: data in a
   volume, objects it reconciles, records it keeps. A package with
   dependents in the repository has one in the test cluster.
3. Deploy the new version with the same command and no extra flag. The plan
   names the old and the new version.
4. Check what the software itself reports. A deploy can return before an
   operator has finished upgrading, and it can report success when an
   operator has refused the change. Read each pod's image digest, the
   version the program logs or serves, an operator's status fields, and the
   PackageInstance version.
5. Check that the state from step 2 is intact and that the package does new
   work. A ready pod does not show this: Grafana 13.3 ran ready with every
   data source missing.
6. Test going back in the way that fits the package. For software that
   keeps data files, start the old version on a copy of the files the new
   version wrote. For an operator, deploy the old package over the new one
   and read what the operator reports. Report the exact result. Look for an
   upstream setting that permits going back, and test it.

### Working beside other agents

- `kind create cluster` and `kind delete cluster` change the current
  context in the shared `~/.kube/config`. Pass `--kubeconfig
  /tmp/kc-<cluster>` when you create the cluster, and set `KUBECONFIG` to
  that file for every command.
- Reach a Service with `kubectl exec`, or pick an unused local port for a
  port-forward and start it again after each deploy. A forward stays on the
  old pod.
- Leave no login in the shared `~/.docker/config.json`.
- Delete your kind cluster when you finish. Each worktree that runs a cargo
  test builds its own target directory under
  `$XDG_CACHE_HOME/kix-cargo-target`. Delete it when the worktree goes.
