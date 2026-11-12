# 167: Packages take secrets only through a secret dependency

**Status:** Accepted (decisions of 2026-11-12, §3). Not built.
**Related:** `77_secrets_implementation_plan.md` (SOPS hydration), `archive/78_cross_namespace_secret_refs.md` (one value, two namespaces), `archive/165_package_and_contract_levels.md` (stable and experimental), `interesting_thoughts/167b_generated_secrets.md` (Kix-made values, later)
**Supersedes:** `archive/160_secret_provenance.md`

---

## 1. Problem

A package can get a secret value in two ways today:

- **As a secret dependency.** Grafana takes `grafanaAdmin`, a Secret with the
  keys `admin-user` and `admin-password`. The cluster fills it with any
  secret instance: `packages.secret` (plain text or a SOPS file),
  `packages.secret-ref` (a Secret something else writes), or a source
  package written outside Kix, such as Lithus's `lithus-secret`, which
  renders a `LithusSecret` object that the Lithus secrets operator turns into
  a Secret. The package never learns which.
- **As its own options.** The database packages take `passwordSource` and
  `passwordHash`, a SOPS file and its hash. Only SOPS works. A site that
  keeps its secrets in the Lithus secrets manager or in a vault cannot use
  these packages, which is why the Lithus monorepo wrote its own
  `cnpg-app-database` and `clickhouse-admin-database`.

Doc 160 decided the model: a package says what a Secret must contain, and
the site says where the value comes from. It shipped the per-key provenance
stamp (`kix.run/secret-sources`, `plainKeys`), the cluster rule
`cluster.secrets.accept`, the Alertmanager routes, and moved cloudflared
and firezone onto dependencies. Two things stayed open. The database
packages still take a SOPS path, and nothing stops a new package from
taking a secret as an option. Package review catches it (rule S1), when the
reviewer runs the check.

This doc makes the dependency the only way, and makes it the easiest way to
write a package.

## 2. Where the packages are now

Counted from `kix/packages` on 2026-11-12, after the 0.10 level split.

**Options that take secret material.** Only the three database packages:
`stackgres-database`, `cnpg-database`, and `clickhouse-database`, each with
`passwordSource` (a `path`) and `passwordHash`. Their old `password` option
is removed in 0.10 and refuses with `[K9503]`. Two names match the S1
pattern and are not secrets: `cnpg-cluster`'s `passwordKey` (the name of a
key) and `filebrowser`'s `tokenExpirationTime`.

**Packages that render a Secret with `scope.mkSecret`.** None of these
takes a secret value from its options, apart from the three database
packages:

| Package | What the Secret is |
|---|---|
| `secret` | the source package itself (plain text or SOPS) |
| `cnpg-database`, `stackgres-database`, `clickhouse-database` | the app's credentials and the server-side copy, both from `passwordSource` |
| `alertmanager`, `victoria-metrics-alert` | rendered configuration, `classification = "configuration"`, credential keys refused (doc 160 §5.4) |
| `external-secrets` (`webhook.nix`) | an empty Secret the controller fills (webhook TLS) |

Nine more only name a Secret something else writes, with
`scope.mkSecretRef`: `secret-ref`, `external-secrets`, `infisical-operator`,
`oidc-client`, `rabbitmq-cluster`, `reloader`, `stackgres-cluster`,
`stackgres-database` (the superuser), and `velero`. They need no change.

So the code change is small. The work is in the rule that keeps it so.

## 3. Decisions

Made on 2026-11-12:

1. **A package takes a secret value only through a secret dependency.** No
   option holds a secret, a path to one, or a Secret's name. This holds for
   stable and experimental packages alike.
2. **A check enforces it, at error level, for the packages Kix ships.** It
   runs in this repository's CI. A project's own packages are not checked
   (§5.3).
3. **The shape of a secret dependency becomes a contract,
   `kix.contracts.secret`.** It starts stable. Source packages publish it,
   and consumers read it through one helper (§5.1).
4. **The database packages take one `password` dependency.** When it is a
   Kix SOPS secret, Kix writes the copy in the server's namespace from the
   same file. When something else makes it, the site delivers a second copy
   there (§5.4).
5. **Kix does not generate values yet.** Recorded in
   `interesting_thoughts/167b_generated_secrets.md`.

Doc 160's rejections still hold: no shared option type for "a string, a
path, or a Secret name" (it cannot carry the dependency edge, the key check,
or the wait for the Secret), and plain-text values stay allowed, because
`cluster.secrets.accept` is where a site forbids them.

## 4. What people will ask for

In the order we expect, and where each fits:

1. **A password Kix makes once and keeps.** Mostly for databases. Not now
   (decision 5). Until then: a SOPS file, or the External Secrets
   `Password` generator, which the `external-secrets` package exposes.
2. **Vault, cloud secret managers, 1Password.** The External Secrets
   Operator covers all of them. A source package `external-secret` (§5.2)
   makes it one instance in the cluster file.
3. **Sealed Secrets.** A source package like `lithus-secret`: render the
   `SealedSecret`, publish the contract. Write it when someone asks.
4. **KMS keys in place of age keys.** SOPS already supports them. Nothing to
   build.

Each is a new source package. No consumer changes.

## 5. Design

### 5.1 The contract and the helper

`kix/contracts/stable/secret.nix`, built with `mkContract`. Its fields are
what `checkSecretKeys` and `credentialsField` already test:

- `name`: the Secret's name, carrying the store context that orders the
  consumer after it.
- `keys`: the declared keys, or null for a Secret whose keys are not known.
- `keyRef`, `mkEnv`, `envFrom`, `volume`: the functions `mkSecretHelpers`
  builds today (`kix/lib/core/resource.nix`).
- `identityHash`: for the `checksum/<name>` pod annotation (rule S10).
- `sops`, optional: `{ source; hash; }` when Kix fills the Secret from a SOPS
  file. Only `packages.secret` publishes it. §5.4 reads it.

A secret dependency has no fixed name (Grafana's is `grafanaAdmin`, caddy's
is `caddyfile`), so this contract has no single `alias`. `mkContract` takes
`alias = null` for it, and the consumer names the argument.

The consumer helper, `kix.contracts.secret.helpers.use`, replaces
`kix.checkSecretKeys`:

```nix
admin = kix.contracts.secret.helpers.use {
  inherit who;
  arg = "grafanaAdmin";
  dep = grafanaAdmin;
  keys = [ "admin-user" "admin-password" ];
};
# admin.env { GF_SECURITY_ADMIN_PASSWORD = "admin-password"; }
# admin.volume "admin"
# admin.podAnnotations    the checksum, and reloader wiring when present
```

It checks the contract and the keys, and returns the readers with the
checksum annotation ready. That is what makes the dependency the easy path:
a package that takes a secret through the helper gets the key check, the
ordering, the wait for an external Secret, and pod restarts on change in
one call. Taking a string option and rendering a Secret is more code.

`packages.secret`, `packages.secret-ref`, and `scope.mkSecretRef` publish
the contract. `checkSecretKeys` stays as a thin wrapper for one release,
then goes (the library has no experimental level, so its removal is an
`error` record in a minor release).

### 5.2 Source packages

| Package | Level | The value comes from |
|---|---|---|
| `secret` | stable, exists | plain text or a SOPS file |
| `secret-ref` | stable, exists | anything that writes a Secret in the cluster |
| `external-secret` | experimental, new | an `ExternalSecret` the External Secrets Operator syncs from a store |

`external-secret` wraps `external-secrets`'s `out.mkExternalSecret`, as
`lithus-secret` wraps its operator's builder:

```nix
app-db-password = {
  package = packages.experimental.external-secret;
  aliases = [ "password" ];
  config = {
    store = "vault";
    keys.password = "db/app/password";   # Secret key = remote key
  };
};
```

### 5.3 The check

A test beside `levels-stable-packages-read-stable-contracts`, run on every
package under `kix/packages/{stable,experimental}/`. It evaluates each
package's `options` and fails when an option:

- has type `path` (or `nullOr path`), unless the package is a source
  package;
- has type `str` (or `nullOr str`) and a name that matches the S1 pattern
  (`password`, `token`, `apiKey`, `secretKey`, `privateKey`, `secretName`,
  and the like).

It also builds each package with the `kix/package-eval.nix` fixtures and
fails on a rendered Secret with a plain-text key that is neither in
`plainKeys` nor under `classification = "configuration"`, again unless the
package is a source package. A source package is one whose root publishes
`kix.contracts.secret`.

False matches go in one file, `kix/packages/not-secret.nix`, as
`{ "<package>.<option path>" = "<why>"; }`. It starts with `passwordKey` and
`tokenExpirationTime`. Every entry is in the diff a reviewer reads.

The test fails the same way for stable and experimental packages. The
package-review skill's S1 points at it, and the package-authoring skill
says to use the helper from §5.1.

### 5.4 The database packages

Each of `stackgres-database`, `cnpg-database`, and `clickhouse-database`:

- Drops `passwordSource` and `passwordHash`. Setting either fails with an
  `error` record id naming the `password` dependency. The packages are
  experimental, so this can go in any release.
- Takes a required dependency `password`, read through the helper, with the
  key `password`.
- Builds the server-side copy by the dependency's source:
  - **`sops` published** (a `packages.secret` with `source`): the package
    renders the server-side Secret from the same file and hash, as it does
    today. Doc 78 ruled out copying values Kix does not own; this one Kix
    decrypts itself.
  - **Otherwise**: the package names the server-side Secret with
    `scope.mkSecretRef` in the server's namespace, under the name it already
    uses for its own objects there (`<instance>-<consumer namespace>`, and
    `<consumer namespace>-<instance>` for `cnpg-database`), with the key
    `password`. Its header and the error for a missing Secret say
    so. The site delivers the value there too: a second `secret-ref`
    filled by its operator, a `ClusterExternalSecret`, or a second
    `lithus-secret`. The deploy waits for it.
- Keeps rendering the app's `credentials` Secret (`username` plain, as
  `kubernetes.io/basic-auth`, and `password`) when the source is SOPS. When
  it is not, the contract's `credentials` must point at a Secret with both
  keys, which the package cannot build (§6, question 1).

The bootstrap Job's name keeps changing with the password: it takes the
dependency's `identityHash` where it took `passwordHash`.

## 6. Open questions

1. **Credentials from an external source.** The `postgresDatabase` contract
   wants `credentials` with `username` and `password` in one Secret. With
   an external source the package holds only `password`. Options: the site
   puts both keys in its store, or the contract's `credentials` needs only
   `password` and consumers read `username` from `out.username` (already an
   optional field). The second is a change to a stable contract, so a minor
   release. Check every consumer before choosing.
2. **Should `kix plan` and `kix diff` show plain keys?** Carried from doc
   160. A changed `host` in a credentials Secret is hidden with the
   password. The per-key stamp makes it possible. It changes what the plan
   hides.
3. **Does `checkSecretKeys` need its one release of overlap?** Nothing
   outside Kix is known to call it, apart from Lithus packages, which we
   can change together.

## 7. Phases

1. The contract, the helper, and `packages.secret`, `packages.secret-ref`,
   and `mkSecretRef` publishing it. Move the consumers to the helper.
   Update `docs/.../secrets-crds-and-rbac.mdx`, `kix/lib/architecture.md`,
   and the package-authoring, package-review, and kix-migration skills.
2. The check (§5.3) and `kix/packages/not-secret.nix`. It passes once the
   database packages move, so phase 3 lands in the same pull request or
   the check starts with them listed and the list shrinks.
3. The database packages (§5.4), after question 1.
4. `external-secret` (§5.2).
