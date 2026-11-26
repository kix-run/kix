# 148: ClickHouse packages, the plan

**Status:** Implemented on kind, not yet merged (all six phases built and proven on a kind cluster, 2026-09-21; unsigned work staged on `feat/clickhouse-package`)
**Type:** Implementation Plan
**Related:** `archive/133_victoria_metrics_ha_packages.md` (the operator plus operand template this copies), `97_service_contract_primitives.md` (the `out` contract idea, `scope.provideService` is not shipped so the contract here is a convention), `131_fact_kinds_and_operand_attribution.md` (operand netpol), `108_backup_capability_contract.md` and `125_backup_abstraction_levels_and_state_contract.md` (backups, deferred)
**Driver:** logging first (ROADMAP "Logging stack package"), with more consumers expected. The logging stack gets its own doc. This one covers only what ClickHouse has to offer it.

## Decision already made

Two implementations, one alias, one `out` contract:

- `clickhouse`: a bare single-node StatefulSet that Kix renders in full.
- `clickhouse-operator` + `clickhouse-keeper` + `clickhouse-cluster`: the Altinity operator and its two CRs, for replicated installs.

Both data packages answer the `clickhouse` alias and expose the same `out`. A consumer written against one works against the other, and the cluster definition chooses. This is the arrangement `prometheusServer` already has, answered by either `prometheus` or `victoria-metrics-cluster`.

The bare package stays single-node for good. Multi-replica ClickHouse needs per-replica macros, generated `remote_servers`, a Keeper quorum and schema propagation to new replicas, and that is the operator's job.

## 1. The contract

Everything a consumer may read. Anything else on `out` is private to the implementation.

| Output | Value | Notes |
|---|---|---|
| `out.httpUrl` | `http://<fqdn>:8123` | Built on a Service's `out.fqdn` (rendered Service in bare, `scope.mkServiceRef` under the operator) so netpol and ordering follow. |
| `out.nativeEndpoint` | `<fqdn>:9000` | Same Service. |
| `out.host` | the Service FQDN | For clients that want host and port apart (Vector, Grafana datasource). |
| `out.ports.{http,native}` | strings, `"8123"` and `"9000"` | Strings because they go into env vars and URLs. |
| `out.username` | `"default"` | The administrative user. Fixed in the bare package. |
| `out.authSecret` | the Secret holding that user's password | In the bare package this is the `credentials` DI dep (a `secret` or `secret-ref` instance). It lives in the server's namespace, so only the server's neighbours can mount it. Consumers elsewhere go through `clickhouse-database`, which is the point of that package. |
| `out.authPasswordKey` | `"password"` | Use as `out.authSecret.out.keyRef out.authPasswordKey`. |
| `out.clusterName` | string | The name DDL uses in `ON CLUSTER` and that the `{cluster}` macro expands to. Always honoured: the bare package runs embedded Keeper unconditionally. |
| `out.version` | `"26.3"` | The server release as YY.M, from the image tag. What a consumer's version requirement compares against (`clickhouse-database` refuses anything older than what it was verified on). |

The table is code: `kix/packages/clickhouse/contract.nix` names the fields and their shapes, both implementations pass their `out` through `contract.check`, and `clickhouse-database` holds its dep to it with `contract.assertions`. A third implementation that drops a field fails at eval with the package and the field named.

The last row is the one that takes work. Schema is where single-node and replicated ClickHouse diverge: `MergeTree` against `ReplicatedMergeTree`, plain DDL against `ON CLUSTER`. A consumer that writes `MergeTree` tables against the bare package has a data migration ahead of it, whatever the wiring says.

So the bare package runs embedded Keeper, always, and defines a one-shard, one-replica cluster with `{cluster}`, `{shard}` and `{replica}` macros. `ReplicatedMergeTree` and `ON CLUSTER '{cluster}'` then work on both implementations, and the guidance to consumers is one sentence: always write replicated DDL. Embedded Keeper costs a few tens of MB on a single node. A `keeper.enabled` switch existed in the first cut; the second red team pass removed it, because a server without a coordinator does not honour the contract and should be a different package under a different alias rather than a `null` every consumer has to assert on.

What the contract does not promise: data does not move when the implementation is swapped. The two packages own different PVCs. Moving data is a backup and restore, or `INSERT ... SELECT FROM remote()`. For logs inside a retention window, starting empty is usually acceptable.

## 2. Phases

Each phase is one pull request, red-teamed before it opens. Verification stays with the parent session: subagents edit, the parent builds.

### Phase 1: `kix/packages/clickhouse` (bare)

Resources: ServiceAccount, ConfigMap for `config.d`, ConfigMap for `users.d`, Secret, StatefulSet with a `volumeClaimTemplate`, Service, headless Service. Root is the main Service. Pattern source is valkey, without its topology switch.

- `meta`: `lifecycle = "stateful"`, `defaultAliases = [ "clickhouse" ]`.
- Image: `clickhouse/clickhouse-server`, current LTS, digest-pinned.
- `config.d`: `listen_host`, console logging, the Prometheus endpoint on 9363, embedded Keeper, macros, the single-entry `remote_servers`. Each file is a separate option-driven fragment so a cluster can add its own without replacing ours.
- `users.d`: the default user's password comes from the Secret through `from_env`, so no credential lands in a ConfigMap.
- Storage: optional `storageClasses` dep, same as `victoria-metrics-cluster/default.nix:227`.
- Memory: ClickHouse reads the cgroup limit. Set `max_server_memory_usage_to_ram_ratio` from an option and require a memory limit, since an unbounded ClickHouse will take the node.
- `kix.monitor` on 9363.
- `kix.healthCheck` probe: `SELECT 1` over HTTP with the credentials, then a read of `system.zookeeper` when Keeper is on. That second query is the one that proves replicated DDL will work.

Done when: a test cluster builds, `nix build ludo/#cluster-ludo-kind` still passes, the package deploys to the `kix-clickhouse` kind cluster and its probe goes green, and a hand-run `CREATE TABLE ... ON CLUSTER '{cluster}' ENGINE = ReplicatedMergeTree` succeeds.

### Phase 2: `kix/packages/clickhouse-database` (the per-consumer facade)

Logging needs a database, a user that can only insert, a user that can only read, and tables with a TTL. The next consumer will need the same, so this is a package and not logic inside the logging stack. Model: `stackgres-database`.

- Dep: `clickhouse` (either implementation).
- Renders one Job running `clickhouse-client` against `out.nativeEndpoint` with idempotent DDL: `CREATE DATABASE IF NOT EXISTS ... ON CLUSTER`, `CREATE USER IF NOT EXISTS`, grants. Optional `schema` option for the consumer's own `CREATE TABLE IF NOT EXISTS` statements.
- Exposes the contract again, narrowed: `out.httpUrl`, `out.nativeEndpoint`, `out.database`, `out.authSecret` for the scoped user. A consumer depends on its database, never on the server directly.
- The Job must not carry `kix.run/rerun: on-change`. Doc 136 records why: bootstrap SQL would re-run whenever anything upstream moved. Idempotent DDL makes a re-run harmless, but an `ALTER` in a consumer's `schema` would not be.

Done when: a second instance of the facade against the same server yields two databases with isolated users, proven on kind.

Schema migrations beyond create-if-absent are out of scope. That is an application concern until a second consumer shows the same need.

### Phase 3: logging, in its own doc

Listed here only to fix what it needs from phases 1 and 2, so they do not ship the wrong surface:

- A shipper with a ClickHouse sink. Vector is the likely pick (native `clickhouse` sink over HTTP, DaemonSet). The OpenTelemetry collector is the alternative and brings its own `otel_logs` schema. Either uses `out.httpUrl` and the insert-only user.
- Grafana: the `grafana-clickhouse-datasource` plugin plus a `clickhouse ? null` auto-wire beside the existing Loki one (`kix/packages/grafana/default.nix:558-589`). That is a change to the grafana package and belongs in the logging work.
- A logs table with `TTL` and a partition key by day. Owned by the logging package, passed to the facade's `schema` option.

Phase 3 can start as soon as phase 2 merges. It does not wait for the operator.

### Phase 4: `clickhouse-operator`

Native package in the VictoriaMetrics shape, not `importChart`. The operator is one Deployment (operator container plus metrics exporter), RBAC, a handful of config ConfigMaps and four CRDs. Native is what lets the CRDs carry `readiness` and `factBehavior`, which a chart wrap does not give us (doc 117 lists the same losses for kube-prometheus-stack). The Altinity chart is the transcription source.

- `kinds.nix` and `crds.nix` as in `victoria-metrics-operator/`. Ship all four kinds (`ClickHouseInstallation`, `ClickHouseInstallationTemplate`, `ClickHouseOperatorConfiguration`, `ClickHouseKeeperInstallation`) until it is proven the operator tolerates a missing one. The VM operator did not (`victoria-metrics-operator/kinds.nix`, the runtime invariant note), and the failure was a slow crashloop.
- Readiness on CHI and CHK: `status.status == "Completed"`. Verify on kind that the status resets to `InProgress` on a spec change before the old `Completed` can be read as the new generation's verdict.
- `factBehavior` on CHI: `endpoint = "terminate"` with the operand selector `clickhouse.altinity.com/chi = <name>`, because the CR spec carries the Keeper address that the operand pods dial. CHK gets the matching selector for its own pods.
- Builders: `out.mkClickHouseInstallation scope { ... }`, `out.mkKeeperInstallation scope { ... }`. No raw kind strings downstream.
- The operator's own ClickHouse credentials (it connects to every server on 8123 to propagate schema) come from a Secret the package renders.

Done when: the operator runs on kind with no restarts for ten minutes (the VM crashloop took three to show), and an empty build with only the operator is green under the scorecard.

### Phase 5: `clickhouse-keeper` and `clickhouse-cluster`

One CR each, through the builders. HA has to be the default posture because the scorecard cannot see operator-created pods.

- Keeper: 3 replicas, anti-affinity, PDB.
- Cluster: 1 shard by 2 replicas, anti-affinity through the operator's `podDistribution`, no service template if the CR Service really is a headless ClusterIP by default, as the 0.27.3 source suggests (unverified), PVC template with the `storageClasses` dep. Requires `clickhouseOperator` and `clickhouseKeeper`.
- `scope.mkServiceRef` for the operator's Service (`clickhouse-<name>`), contract outputs built on its `out.fqdn`.
- `out.clusterName` is the CHI's cluster name, and the operator supplies the macros.
- Same probe as phase 1, plus a check that `system.clusters` lists the expected replica count.
- Shards stay at 1. More shards change how consumers must write (`Distributed` tables), which would break the contract. Reopen only with a consumer that needs it.

The netpol work is the risk in this phase. Four flows exist only between operator-created pods, or from the operator to them, so nothing in the build's graph describes them: operator to servers on 8123, server to server on 9009 (interserver replication), server to Keeper on 2181, Keeper to Keeper on 9234 (raft). Test on the Cilium kind cluster (`clusters/test-kind-probe.nix`) under default-deny before anything else. What `factBehavior` does not cover goes into doc 131's residue list with a package-level policy as the stopgap.

Done when: a 3-node kind cluster runs the trio under default-deny, the probe is green, and draining one node leaves inserts and selects working.

### Phase 6: the swap proof, then docs

- A fixture cluster with the facade and a dummy consumer, built twice: once on `clickhouse`, once on the trio. The only difference in the consumer's manifests should be the hostname inside its URLs. This is the test that the contract holds, and it should run in `nix flake check`.
- `.claude/skills/kix-migration/SKILL.md`: extend "Operator-Managed Stacks" with the two-implementations-one-alias pattern. `docs-legacy/FEATURE-CATALOG.md`: the new packages. `ROADMAP.md`: tick the item.
- Archive this doc on ship. Anything still open moves to `ROADMAP.md § Open design questions`.

## 3. Order and size

Phases 1, 2 and 3 are the path to working logs and none of them needs the operator. Phases 4 and 5 are the larger half (the VM equivalent was about 1,800 lines of Nix across four packages) and can run in parallel with phase 3 once the contract has survived a real consumer.

## 4. Not in this plan

- Backups. `clickhouse-backup` to object storage fits doc 108's engine shape. Logs can live without it at first; the second consumer probably cannot.
- TLS between servers and to clients.
- More than one shard.
- The official ClickHouse Inc. operator. Look again when phase 4 starts. If it has matured, the contract means only phases 4 and 5 change.
- S3-backed or tiered storage.

## Current state (2026-09-21)

**All six phases are built and proven on kind. Phase 1 first, which was also red-teamed** (`kix/packages/clickhouse`, `clusters/test-clickhouse.nix`). The build has no errors under every scorecard rule set; the package draws two warnings, `governance.hasOwner` (no catalogue package sets an owner) and `security.hasNetworkPolicy` (the test cluster has no enforcer).

Where it departs from the phase 1 sketch above, and why:

- **Storage and credentials are DI deps**, not a `volumeClaimTemplate`, a `storageClasses` dep and a generated Secret: `storage` is a `persistent-volume-claim` instance and `credentials` a `secret` or `secret-ref` instance with a `password` key, asserted at eval time. This is STORAGE.md and SECRETS.md applied as written.
- **Config is YAML fragments from Nix attrsets** (`serverConfig`, `usersConfig`), in ClickHouse's own vocabulary, merged over the package's own fragments by name. A null removes a key or a whole fragment. No option stands in for a ClickHouse setting, so there is no `max_server_memory_usage_to_ram_ratio` option either: the memory limit is required and ClickHouse's own 0.9 default does the rest.
- **The probe is on by default** for this package, because it is the only thing that notices a default user left with an empty password.
- **One gap found in Kix and fixed there**: a `kix.healthCheck` probe could not receive a secret, because `kix.mkEnvVars` only took strings. It now accepts a `valueFrom` source (`secret.out.keyRef "k"`) and refuses any other attrset at eval time (lib tests t102, t103).

Lessons taken from reading the Bitnami and Altinity charts, each verified on the live pod before it was kept:

- The expanded config, password included, is written to `preprocessed_configs/` on the data volume. It is now a memory-backed emptyDir.
- **`hide_in_preprocessed` is the documented fix for that and must not be used**: on 26.3 it makes the server drop the `from_env` substitution and run with an empty password, while looking healthy. The probe asserts that a login with no password is refused.
- Running the server binary directly leaves a watchdog as PID 1. `CLICKHOUSE_WATCHDOG_ENABLE=0`; a pod delete now completes in about 3 seconds with data intact.
- The shipped config enables a dozen system log tables with no TTL. They get 30 days.
- Liveness and startup are TCP checks; only readiness asks `/ping`, so a saturated server is not restarted.
- The MySQL and PostgreSQL emulation ports are closed.

From the red team pass (a Fable agent, no blockers, six should-fix, all taken):

- **Embedded Keeper is reachable on the pod IP and has no login.** Its DDL queue is executed by the server without asking who wrote the entry, so that was a way past the password. The server now connects with a digest identity derived from its password (`CLICKHOUSE_KEEPER_IDENTITY`, a Kubernetes `$(VAR)` expansion of the password env var), so every znode it creates carries an ACL. Verified from a pod in another namespace: create, list and get_acl under the DDL queue all return "Not authenticated". The interserver port listens on localhost only. Raft (9234) still listens on the pod IP; it accepts no peer that is not in its one-server configuration.
- The system-logs fragment had switched on `zookeeper_log`, which upstream ships commented out. Removed, with the rule written next to the list.
- With Keeper off the package exposed a cluster name it could not honour. It rendered no cluster and a null `out.clusterName` for a while; the switch is now gone (see the second pass below).
- `clusterName` is typed to what an XML element name allows, and the probe binds it as a query parameter.
- `mkEnvVars`: the env var's own name wins over a `name` inside the source, matching `secret.out.mkEnv`.
- `fsGroupChangePolicy: OnRootMismatch`, a size limit on `/tmp`.

Tests run on kind (fresh cluster): both variants deploy and probe green; replicated DDL round trip; the Keeper attack above; port scan from another namespace (8123 and 9000 open, 9009, 9004, 9005 closed); a bad `clusterName` fails at eval; an empty password fails the deploy at the probe and the previous activation stays live; pod kill with data intact. Lib tests and `ludo-kind` build.

Known and accepted: the `default` user has `access_management` and is reachable from any pod that holds the password, with network policy as the outer boundary; nothing stops a `partsOverlay` from setting `replicas = 2` against the single volume; on kind's local-path volumes `fsGroup` has no effect and the server logs an ownership warning.

### Phases 2 to 6

Everything below ran on one kind cluster: a control plane and three workers, no default CNI, Cilium from `packages.cilium` enforcing the policies Kix derives, so every namespace is under default-deny (`clusters/test-clickhouse.nix`). An unrelated pod in another namespace cannot reach ClickHouse on 8123 or Keeper on 9181.

- **Phase 2, `clickhouse-database`.** The stackgres-database shape: credentials Secret in the consumer's namespace, bootstrap Job next to the server (`scope.forService`), Job named by a hash of its inputs. Proven: a writer that can insert and not select, a reader that can select and neither insert nor create, both on one database; the schema file produced a `ReplicatedMergeTree` table with its TTL; a changed password made a new Job, the old password was refused and the new one worked. The §5 question on table DDL is settled as planned: `schema` is an attrset of SQL files mounted from a ConfigMap with `kix.mount.configMap`, `{database:Identifier}` bound by the Job. It needed no special case. The password is bound as `{password:String}` and never enters the SQL text.
- **Phase 3, `clickhouse-logs`**, doc 149. Logs from all four nodes arrive under default-deny; the path from the agents to ClickHouse crosses two namespaces and a ConfigMap and Kix derived it unaided.
- **Phase 4, `clickhouse-operator`.** Native, all four CRDs with vendored schemas (`scripts/vendor-clickhouse-crd-schemas.py --check`), RBAC set-equal to upstream's ClusterRole, `readiness` and `factBehavior` on CHI and CHK, credentials as a DI dep. It runs with a read-only root as uid 65534. **The operator watches only its own namespace unless it lives in `kube-system`** (its source calls anything else a "local installation"); the package sets `watch.namespaces.include = [ ".*" ]`. Without it a CR in another namespace is accepted and never reconciled.
- **Phase 5, `clickhouse-keeper` and `clickhouse-cluster`.** Three Keepers, one shard by two replicas, spread over nodes. The Keeper address enters the CHI spec as `clickhouseKeeper.out.host`, so `factBehavior` derives the servers' egress to Keeper. The flows with no address to ride on (Keeper raft, replica to replica, operator and exporter to every replica on 8123) are package policies over the operator's pod labels, the stackgres-cluster precedent; the operator's half lands in the operator's namespace through `scope.forService`. Confirmed live from the chart reading: the CR Service is `clickhouse-<name>`, headless, so no service template; PDBs come from the operator; `podDistribution` placed the replicas on different nodes. The probe is the bare package's script plus a replica count. **Drain proof:** with the node under replica 0 and a Keeper member drained, an insert and a select through the Service succeeded and Keeper kept quorum; replica 0 came back and held the row written while it was away.
- **Phase 6, the swap.** `clusters/test-clickhouse-swap/` builds one consumer twice, on `clickhouse` and on `clickhouse-cluster`, and the `clickhouse-swap` flake check requires its four manifests to be identical but for the hostname. On the live cluster the same `clickhouse-database` config ran against both.

### Found in Kix on the way, and fixed there

- **An explicitly wired dep still failed as ambiguous** when two instances answered its name (`deps.clickhouse = ref...` with three `clickhouse` instances in the cluster). The first resolution pass cannot see explicit wiring; it no longer raises errors that belong to the pass that can (`kix/lib/eval/resolve.nix`, lib tests t98 and t99).
- `kix.mkEnvVars` takes `valueFrom` sources (phase 1).
- Two more were found here and fixed on main in the same weeks, so this branch carries neither: Cilium refused the empty rule lists the default-deny policy rendered, and an egress rule on a named port matched nothing when the name meant different numbers on different pods. Main renders one empty rule per direction and writes the container port number into every Service `kix.service.fromWorkload` produces.

### Second red team pass (2026-09-22), on the pattern itself

A Fable agent reviewed the two-implementation arrangement against `BEST-PRACTICES.md` and its interaction with dependency injection. Verdict: the packages pass the purist test, the resolver change made to let them build did not. Taken:

- **The resolver.** `ref.<ns>.<inst>` was the cluster fixpoint, so the phase-1 pre-pass could not read explicit wiring, and my `tryEval` around it turned a loud "ambiguous" into a silently dropped config injection: a consumer that injects config into a facade it wired explicitly (exactly what `clickhouse-logs` does) got nothing, with a clean eval and a clean scorecard. `ref` is now a static pointer built over the merged instance names, the pre-pass reads it, injections follow the wiring, and `meta.scope` and version constraints apply to wired deps again (`kix/lib/eval/cluster.nix`, `resolve.nix`; lib test t100). The `phase-1 caveat` paragraph in `BEST-PRACTICES.md` §8.4 is gone with it.
- **The contract in code.** `contract.nix` as above, with `version` added.
- **`keeper.enabled` removed**, and with it the nullable `clusterName`, the facade's assertion on it, the probe's branch and the third server instance in the test cluster.
- **`extraSpec` is guarded.** `kix.mergeGuarded` refuses an override on a path the package computed for correctness, in `clickhouse-cluster`, `clickhouse-keeper` and `victoria-metrics-cluster` (issue #107's shape, three callers).
- **One source for the operand selector.** The operator exposes `out.operandSelector.<kind>` from `kinds.nix` and `out.podSelector` with dependency context; the CR packages read them instead of spelling the label.
- **The swap check** diffs the facade's bootstrap Job in the server's namespace too (seven manifests, not four).

Not taken here, recorded in `ROADMAP.md`: `deps.<dep>.version` sugar over the assertion form and retiring `meta.compatibleWith`; whether a version requirement should drive auto-instantiation.

Left for Kix, recorded in `ROADMAP.md`: `kix.withMountsOn` cannot put one volume into two containers (the operator package copies the rendered mounts across); `kix deploy` gives a custom resource 180 seconds without progress, and an operator rolling three Keepers one at a time takes longer on a first install, so the first deploy halts and a second one completes it; a probe that needs root-only access has no package-side way to be accepted by `security.nonRoot`.

Carried forward to phases 4 and 5 from the chart reading (operator 0.27.3 source, unverified until those phases run): the operator's Services select on a `clickhouse.altinity.com/ready=yes` label it manages; the CR Service is `clickhouse-<chi>`, reported to be a headless ClusterIP by default; `serviceTemplates[].spec` replaces operator defaults wholesale, and a CHK replica Service override must keep `publishNotReadyAddresses: true` or Keeper cannot form a quorum; a CHI references Keeper natively with `spec.configuration.zookeeper.keeper: { name }`; anti-affinity is `podDistribution`, not raw affinity; PDBs are created by the operator (`maxUnavailable` only); the operator reaches servers on 8123 with a `username`/`password` Secret and watches all namespaces by default; its chart installs CRDs with a Helm hook, which the native package replaces with plain resources; `config.yaml`'s `configurationRestartPolicy` table says which settings need a restart.

## 5. Decisions (2026-09-21)

**The test for every choice in this work: would a Kix purist be happy with the implementation?** Concretely, per `PRINCIPLES.md` and the DSL rules in `CLAUDE.md`: standard Kubernetes and ClickHouse fields only, no invented spec keys; consumers read `out`, never interpolate names; every address reaches its consumer as a value that carries dependency context, so netpol and ordering are derived and not written; mounts, monitoring, exposure and probes go through the `kix.*` build entries and not hand-rolled equivalents; defaults prevent mistakes (a memory limit is required, replicated DDL works everywhere). Where the first draft of a phase fails this test, fix the package, or record the gap in Kix itself in `ROADMAP.md`, and do not paper over it inside the package.

1. **Test clusters: kind only** (revised by Adam later the same day; the first answer was kind, then stage1 and stage2). Everything in this plan is proven on a dedicated kind cluster, `kix-clickhouse`, plus a Cilium default-deny kind cluster for the netpol work. Nothing here is deployed to stage1, stage2 or any other cluster. The node-drain proof of phase 5 runs on a multi-node kind cluster.
2. **Embedded Keeper is always on** in the bare package (was "on by default"; the switch went in the second red team pass).
3. **The operator package is native**, not `importChart`.
4. **Facade and table DDL:** decided in phase 2 by the purist test. The shape to try first: the consumer passes SQL as files, the facade mounts them through `kix.mount.*` from a ConfigMap, and the Job's identity follows the ConfigMap's hash. If that reads as natural Kix, it stays. If it needs special cases, the facade owns databases and users only.
