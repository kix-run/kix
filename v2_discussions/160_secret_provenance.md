# 160: Secret provenance: the site chooses where values come from

**Status:** Accepted; §5.1 (cloudflared, firezone), §5.2, §5.3, and §5.4 shipped 2026-10-17. Open: §6.3 (database facades) and §5.5 (generation).
**Related:** `77_secrets_implementation_plan.md` (SOPS hydration, in progress), `archive/75_secrets_what_actually_matters.md` (contracts, not stores), `archive/76_secrets_design.md` (`mkSecret`, `mkSecretRef`, `out.keyRef`), `archive/78_cross_namespace_secret_refs.md` (one value, two namespaces), `archive/138_values_that_vary_per_deploy.md` §9 (a build with inline Secrets is a credential archive), `153_packages_reading_scorecard_policy.md` (how a package may read policy)
**Triggered by:** [kix-run/kixpkgs#236](https://github.com/kix-run/kixpkgs/issues/236)

---

## 1. Problem

A Secret's value can reach the cluster four ways: written in Nix, decrypted
from a SOPS file at deploy, created by something outside Kix (an operator,
cert-manager, a person), or filled in by a controller after Kix creates it
empty. Which way is acceptable is a property of the site. One site runs
External Secrets against a vault and will not deploy a build that carries
a Secret body. Another runs a homelab from SOPS files. A third writes the
value in the cluster file and accepts that the Nix store holds it.

Today the package chooses, not the site. Each package exposes its own
option shape for the same question, and some offer only one answer. Issue
236 found a build that could not be deployed because `victoria-metrics-alert`
renders Alertmanager's configuration into a Secret with inline content, and
no option avoids it. The configuration held no credential. The deploy could
not tell.

The question this doc answers: what is the Kix-native shape for "where does
this Secret's value come from", so that the package declares the shape of a
Secret, the site decides its provenance, and the build can check the site's
rule before anything reaches a cluster.

## 2. Where the packages are today

Counted from `kix/packages` on 2026-10-17 (`grep -c 'mkSecret\b'`, `grep -c mkSecretRef`, `grep -l stringData`).

| Pattern | Packages | Inline | SOPS | Existing Secret |
|---|---|---|---|---|
| Secret as a dependency (`packages.secret` or `packages.secret-ref` behind one alias) | keycloak `bootstrapAdmin`, grafana `grafanaAdmin`, immich `valkeyPassword`, openbao `unsealKey`, tailscale OAuth client, metabase, the `oidcClient` contract, external-secrets store auth, cnpg-barman-cloud S3 credentials | yes | yes | yes |
| `foo` and `fooSource` options, a Secret the package renders | cloudflared `token`/`tokenSource`; cnpg-database, stackgres-database, clickhouse-database `password`/`passwordSource`/`passwordHash` | yes | yes | no |
| Inline only, from options | firezone (eight application keys plus a WireGuard key in two Secrets), alertmanager `settings`, victoria-metrics-alert `alertmanager.settings` | yes | no | no |
| Reference to a Secret something else creates (`scope.mkSecretRef`) | caddy, infisical-operator, rabbitmq-cluster, reloader, stackgres-cluster, stackgres-database (superuser), velero, external-secrets `out.secretRef` | no | no | yes |
| Empty Secret a controller fills (`mkSecret { keys = [ ]; }`) | external-secrets webhook TLS | no | no | controller |

Three things the inventory shows:

- **The dependency route already is the union type.** `packages.secret`
  (inline or SOPS) and `packages.secret-ref` (anything else) share the
  default alias `secret` and the same `out` API, so a package that takes a
  secret dependency already lets the site choose all three sources. The
  `external-secrets` package closes the loop: `out.mkExternalSecret` returns
  `out.secretRef { keys; }`, a `mkSecretRef` ordered after the
  ExternalSecret, so an operator-synced Secret is a first-class dependency.
- **The `fooSource` pattern is the dependency route reimplemented per
  package**, minus the external branch. It exists because these packages
  render the Secret themselves: the database facades put the password next
  to plain keys, and in two namespaces.
- **The inline-only packages are the ones the issue is about.** Two of them
  (alertmanager, victoria-metrics-alert) render software configuration into a
  Secret because the software reads it from one. The third (firezone) holds
  credentials that have no meaning outside the application and that nobody
  should ever type.

What the build already records about each Secret: `kix.run/secret-keys`
(declared keys), `kix.run/sops-source` and `kix.run/content-hash` (SOPS
mode), `kix.run/classification` and `kix.run/rotation-policy` (when the
package sets `meta`), and for a reference the import marker with
`kix.run/import-secret-keys`. The plan hides every value of a Secret
(`kix::plan::without_secrets`). The deploy's `SopsHydrator` fills
`stringData` before the apply, from local files or the files a carried
build brings with it, and plans made before approval decrypt nothing.
Nothing verifies `hash` against the decrypted data.

## 3. Prior art outside Kix

- **Helm `existingSecret`.** Each chart decides whether a credential may
  come from a Secret the user created, under a name the chart author chose.
  The convention is per chart and uneven, which is the situation in §2
  reproduced across a thousand charts. The lesson is that a per-package
  option cannot carry a site-wide rule.
- **sops-nix and agenix on NixOS.** A secret is declared by name with a
  ciphertext file; services receive a path such as `config.sops.secrets.db.path`;
  the plaintext never enters the store. The declaration separates the
  secret's identity and the ciphertext source, and consumers wire to the
  identity. This is `mkSecret` with `source`, and it is the closest analogue
  to Kix's shape-versus-value split.
- **External Secrets, Sealed Secrets, Vault injectors.** The manifest names
  a remote key or a ciphertext and a controller writes the Secret. The
  manifest carries no value, so a build can be published. Kix already treats
  the result as a reference (`out.secretRef`).
- **Flux and Argo CD with SOPS.** Decryption happens in the reconciler with
  a key the cluster holds. The repository and the rendered output carry
  ciphertext only. Kix does the same at deploy, and doc 138 §9 recorded the
  consequence: a Secret with an inline body in a build makes the stored
  build a credential archive, so builds with inline Secrets cannot be
  stored or replayed.
- **Pulumi and Terraform `sensitive`.** A value is marked, and the tool
  redacts it in plans and state. The marking is per value, not per
  resource, which is the granularity §5.2 needs for mixed Secrets.
- **Kyverno and Gatekeeper audit before enforce.** A new policy starts
  advisory, the backlog is worked down, then it blocks. Doc 138 adopted this
  for image digests; §5.3 reuses it.

## 4. The model: shape belongs to the package, provenance to the site

Kix compiles wiring. A package declares what a Secret must contain (its
keys and type) and who reads which key; that is the contract doc 75 named
as Kix's value. Where the bytes come from is an environment fact, like
which StorageClass backs a claim. The package does not pick a StorageClass
and should not pick a secret source.

Four provenances cover every Secret in the repo:

| Provenance | Meaning | How the build shows it today |
|---|---|---|
| `inline` | the value is in the Nix expression, the store, and every build | `stringData` or `data` present |
| `sops` | a ciphertext file is in the build; the deploy decrypts it | `kix.run/sops-source` |
| `external` | something outside Kix creates the Secret; Kix names it and waits for it | `mkSecretRef` import marker |
| `controller` | Kix creates the Secret empty and a controller writes the keys | `keys = [ ]` with no data |

Provenance is per key, not per Secret. The database facades' credentials
Secret has `password` from SOPS and `username`, `host`, `port`, and
`database` inline. A rule that reads the Secret as a whole must call it
inline. A rule that reads keys can say the inline keys are not credentials.

The site's rule is a set of accepted provenances, with one refinement: an
inline key is accepted when the package declares it is not a credential, or
when the site accepts package-rendered configuration (§5.4).

## 5. Proposal

### 5.1 Every credential a site supplies is a secret dependency

This is already package-review rule S1 and S2. The proposal is to apply it
to the packages that predate it and to say so in `package-authoring`:

- **cloudflared**: replace `token` and `tokenSource` with a required
  dependency `tunnelToken` declaring key `token`. The site wires
  `packages.secret` (inline or SOPS) or `packages.secret-ref`.
- **firezone**: replace the eight `secrets.*` options and
  `wireguard.privateKey` with dependencies, grouped by how the program reads
  them (`applicationSecrets` with the eight keys, `wireguardKey` with
  `private_key`). Until Kix can generate values (§5.5) a site writes them
  once into a SOPS file or has an operator mint them.
- **The database facades** gain a `password` dependency beside
  `passwordSource`; §6.3 says how the server-side copy is handled.

A dependency is the only option shape that can express all three sources,
because a reference is a resource with store context and ordering, which an
option value cannot carry. `kix.untrackedRef` in `env` is the escape hatch
and loses key checks and the readiness wait.

### 5.2 Stamp per-key provenance on every rendered Secret

`scope.mkSecret` knows which keys it filled from `stringData`, which it
expects from `source`, and which it leaves to a controller. Write that down
as one annotation, `kix.run/secret-sources`, for example
`username=inline,password=sops`. `scope.mkSecretRef` already is one
provenance (`external`) and needs no new stamp.

Add one builder argument, `plainKeys`, for a key whose value is in the
expression and is not a credential. The type `kubernetes.io/basic-auth`
implies `username` is plain; `kubernetes.io/tls` implies `tls.crt` and
`ca.crt` are plain. The annotation records `plain` for these keys.

Two consumers of the stamp beyond the policy: the plan can redact only the
keys that are credentials and show a changed `host`, and a deploy that
refuses inline content (the one in issue 236) can read the stamp instead of
guessing from `stringData`.

### 5.3 A cluster rule, checked at build, advisory first

A cluster option names the provenances it accepts:

```nix
cluster.secrets.accept = [ "external" "sops" "controller" ];
# default: every provenance, so nothing changes for existing clusters
```

A scorecard rule in the security group (`kix/lib/rules/security.nix`) walks
every rendered Secret and reference, reads `kix.run/secret-sources`, and
reports each key whose provenance the cluster does not accept. The finding
names the package, the instance, the Secret, the key, and the option or
dependency that fed it:

```
victoria-metrics-alert monitoring/alerts: Secret alerts-alertmanager-config
key alertmanager.yaml is inline (from alertmanager.settings), and this
cluster accepts external, sops, controller. Supply the configuration as
the alertmanagerConfig dependency, or set alertmanager.configRawYaml.
```

Severity follows the scorecard's existing machinery. The rule applies only
when the cluster sets `cluster.secrets.accept`; unset, it reports nothing,
because every fixture in this repository writes `stringData` and an
advisory finding on each would be noise without a reader. Setting the
option is the opt-in, at error severity under the cluster's cap.
Per-instance overrides use the scorecard's override mechanism, not a
package switch (doc 153's rule: a policy read may only choose between
building and throwing).

The build is the right place for this check. The deploy in issue 236
refused a build after it was made and shipped; the build can refuse it
while the author still has the cluster file open, and name the option.

### 5.4 Configuration that software reads from a Secret

Alertmanager, VMAlertmanager, Grafana datasources, and others read plain
configuration from a Secret by convention. The rendered Secret is `inline`
by mechanism and configuration by content, and its sensitivity depends on
what the site wrote into it.

Three things, in order of preference, and a package offers each one the
software supports:

1. **Deliver the configuration without a Secret where the API allows.**
   VMAlertmanager has `configRawYaml`; the operator documents it as
   starting without a Secret. The package offers it as an option and the
   rendered Secret disappears.
2. **Accept a dependency in place of the rendered Secret.** An optional
   `alertmanagerConfig` dependency declaring key `alertmanager.yaml`; when
   wired, `configSecret` points at its `out.name` and the package renders
   nothing. A site with External Secrets keeps the configuration in its
   store and delivers it the same way as every other Secret.
3. **Mark the rendered Secret as configuration and keep refusing
   credentials in it.** `meta.classification = "configuration"` already
   renders to `kix.run/classification`. The alertmanager package refuses
   every credential key it knows in `settings` (`inline-secrets.nix`,
   including webhook URLs that carry tokens); the policy records
   `inline+configuration` and a site may list `configuration` in
   `cluster.secrets.accept` to take the package's word for it. The claim is
   the package's best effort, not a guarantee, and the doc for the option
   says so.

### 5.5 Generated values, later

Firezone's eight keys and every database password are credentials that
have meaning only inside the cluster. Doc 22 and doc 74 proposed
`generate` rules the deploy fulfils once and keeps. Nothing was built. The
Kubernetes-native version exists today for sites that run External
Secrets: the `Password` generator kind, which the package already exposes
under `out.crds`. A Kix-native generator conflicts with the identity hash
(the value cannot be in the build, and a second deploy must keep the first
value, not regenerate it), so it needs its own design. Parked in
`interesting_thoughts/` with that constraint named; it is the answer to
§6.3, not a prerequisite for §5.1 to §5.4.

## 6. Worked cases

### 6.1 The issue's case: victoria-metrics-alert and alertmanager

Smallest step, one PR per package:

- `alertmanager.configRawYaml` on victoria-metrics-alert (§5.4 item 1).
- An optional `alertmanagerConfig` dependency on both packages (item 2),
  refusing `settings` when both are given.
- `meta.classification = "configuration"` on the rendered Secret (item 3).
  victoria-metrics-alert gains the same credential-key refusal alertmanager
  has; today its `settings` are not checked.

The default stays as it is: the package renders `settings` into a Secret.

### 6.2 cloudflared

`tunnelToken` dependency, required, key `token`. The site's choice becomes
visible in the cluster file and the policy can read it:

```nix
instances.edge = {
  tunnel = { package = packages.cloudflared; };
  tunnel-token = {
    package = packages.secret-ref;      # or packages.secret with source
    aliases = [ "tunnelToken" ];
    config.keys = [ "token" ];
  };
};
```

The housekeeping entry about the token change not restarting the pods is
the same work: a dependency's `out.identityHash` goes into the pod template
as `checksum/<name>`.

### 6.3 The database facades: one value, two namespaces

cnpg-database needs the password in the consumer's namespace (the
`credentials` Secret consumers read) and in the server's namespace (the
basic-auth Secret CloudNativePG's `Database` role reads). stackgres-database
has the same pair (`credentials` and `bootstrapPassword`). With
`passwordSource` the deploy hydrates both from one file; this is the only
fan-out Kix has, and it is why the pattern survived.

A Secret in one namespace is not readable from another, and doc 78 ruled
out Kix copying values it does not own. A secrets operator has no such
limit: External Secrets writes one remote value into two namespaces with a
ClusterExternalSecret, or with two ExternalSecrets naming the same remote
key. The gap is in the package, which builds both Secrets itself and
cannot say "both exist already, I only point at them". The route:

- **A `password` dependency** in the consumer's namespace replaces
  `passwordSource` for operator sites. The facade reads it as
  `out.credentials`, as the contract already allows.
- **A named reference on the server side.** The facade names the
  server-namespace Secret with `mkSecretRef` (as stackgres-database does for
  the superuser Secret) and documents the name and keys it expects. The site
  delivers the value there too. The deploy waits for it.
- **The SOPS route stays**, because there Kix writes both Secrets from one
  file, and a dependency would make it worse.
- **Generation (§5.5)** later removes the double delivery; it is an
  improvement, not a prerequisite.

Independent of the route, the `credentials` Secret should shrink. The
postgres-database contract (`kix/lib/vocab/postgres-database.nix`) requires
only `username` and `password` on `credentials`; `host`, `port`, and
`database` are separate `out` fields that consumers already read. With the
Secret as `kubernetes.io/basic-auth`, `username` is plain by type and the
Secret has one credential key, so the mixed-Secret question in issue 236
does not arise for it. Check whether any consumer reads `host` from the
Secret before removing the keys.

## 7. Alternatives considered

- **A shared option type `kix.options.secretValue`** (inline string, SOPS
  path, or `{ name; key; }` of an existing Secret). Rejected: the third
  branch cannot carry store context, so it loses the dependency edge, the
  key check, and the readiness wait, and every package would reimplement
  the three-way validation that `packages.secret` and `packages.secret-ref`
  already do once. The dependency is the union type.
- **Forbid inline values everywhere.** Rejected: test fixtures, kind smoke
  tests, and sites that accept the Nix store as their secret store all use
  it, and the catalogue should not decide that for them. The cluster rule
  does it where a site wants it.
- **Check at deploy only.** Rejected as the only check: it fires after the
  build is made and shipped, with no option name. The deploy may still
  check, reading the same stamp.
- **A per-package `secretSource` switch.** Rejected: it is the `fooSource`
  pattern again, and a site-wide fact expressed per instance drifts.

## 8. Open questions

1. **Plain keys by type or by declaration?** §5.2 proposes both. Type-based
   rules are few and fixed (basic-auth, tls, dockerconfigjson has none).
   Is `plainKeys` needed at all once the facades shrink their Secrets, or
   does it invite packages to put configuration in Secrets?
2. **Where does the policy live?** A scorecard rule (this doc) or a
   cross-resource check in `kix/lib/eval/validate.nix`? The scorecard has
   severity and overrides; the checks fail the build without a severity.
   Advisory-first needs the scorecard.
3. **Does the `configuration` classification earn its keep**, or should
   the catalogue rule be that a package rendering configuration into a
   Secret must offer a non-Secret or dependency route, and the
   classification only labels the default?
4. **The server-side Secret name** (§6.3). The facade documents a name the
   operator must write to in the server's namespace. Should the name be an
   option, so the site chooses it, or fixed by the facade so two facades
   never collide?
5. **Should `kix diff` and `kix plan` use the per-key stamp to show plain
   keys?** Today a changed `host` in a credentials Secret is hidden with the
   password. Showing it is useful and changes the redaction contract.

## 9. Phases

1. **Unblock issue 236**: §6.1, both Alertmanager packages. No lib change.
2. **Stamp provenance**: `kix.run/secret-sources` and `plainKeys` in
   `scope.mkSecret`; tests in `kix/lib/tests/units/lib-reference-checks.nix`;
   update `kix/lib/architecture.md`, the `kix-migration` skill's `SECRETS.md`,
   and `package-review` S-rules.
3. **Cluster rule**: `cluster.secrets.accept` and the scorecard rule,
   advisory by default; `docs-legacy/HANDBOOK.md` §21 and
   `FEATURE-CATALOG.md`.
4. **Retire `fooSource` where a dependency fits**: cloudflared, then
   firezone, then the database facades per §6.3 (SOPS route kept).
5. **Generated values**: separate design in `interesting_thoughts/`.
