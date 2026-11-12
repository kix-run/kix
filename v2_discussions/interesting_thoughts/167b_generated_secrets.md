# 167b: Secret values Kix generates

**Status:** Parked (decided 2026-11-12 in doc 167: not now)
**Related:** `../167_secrets_only_through_dependencies.md`, `../archive/160_secret_provenance.md` §5.5, `../archive/74_secrets.md` (`generate` rules)

## The idea

A source package, `generated-secret`, that publishes `kix.contracts.secret`.
The first deploy creates a random value in the cluster. Later deploys keep
it. The value never enters the build, the Nix store, or a plan. This is
what people will ask for most often, for database logins and for
application keys such as firezone's eight, which mean nothing outside the
cluster and which nobody should have to type.

## Why it is parked

- The value cannot be in the build, so the Secret's identity hash cannot
  cover it. The deploy must create the Secret only when it is missing and
  never overwrite it, which is a new kind of apply.
- Losing the cluster loses the value. That is fine for a login the
  database can reset, and wrong for a key that encrypts data at rest.
- A database package needs the value in two namespaces (doc 167 §5.4). A
  generator would have to write both, or write one and have Kix copy it,
  which doc 78 ruled out for values Kix does not own.

Until then, a site uses a SOPS file, or the External Secrets `Password`
generator, which the `external-secrets` package already exposes.

## What would bring it back

A second site asking for it, or the first site that cannot run External
Secrets and does not want SOPS files for app database passwords.
