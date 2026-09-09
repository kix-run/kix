# Secret Primitives

**Always use `scope.mkSecret` or `scope.mkSecretRef` for secrets** — never raw `scope.mkResource { kind = "Secret"; }`. The secret primitives provide an enriched `out` API with build-time key validation and dependency tracking.

## `scope.mkSecret` — kix-managed secret

Creates a K8s Secret resource with enriched `out`. Accepts inline `stringData` or SOPS `source` + `hash`.

```nix
creds = scope.mkSecret {
  name = "${scope.instanceName}-credentials";
  stringData = {
    username = "admin";
    password = config.password;
  };
  # keys auto-derived from stringData. Explicit keys for SOPS mode:
  # keys = [ "username" "password" ];
  # source = ./secrets/creds.yaml;
  # hash = "sha256-...";
  # type = "Opaque";  # default
};
```

## `scope.mkSecretRef` — externally-managed secret

References a secret that exists outside kix (Vault, ESO, cert-manager, operator-provisioned). Emits a `PackageInstance` import marker with `kix.run/mode=import` that the deploy CLI polls before running the wave that depends on it — if the Secret is missing or the declared keys aren't populated, the wave fails fast.

```nix
appSecret = scope.mkSecretRef {
  name = "my-app-secret";
  keys = [ "API_KEY" "DB_URL" ];  # for build-time validation AND presence check at deploy time
};
```

**Gotcha 1 — the marker must be in the returned attrset, not just `let`.** Package build functions only emit resources that `collectTypedAttrs` finds in the returned attrset. A `mkSecretRef` stashed in a `let` binding will *not* produce a manifest. Always `inherit` the ref in the return attrset:

```nix
let
  superuserSecret = scope.mkSecretRef { ... };
in {
  inherit superuserSecret;   # <- required, otherwise no marker manifest
  root = {
    resource = self.cluster;
    out.superuserSecret = superuserSecret;
  };
}
```

**Gotcha 2 — wave ordering for operator-provisioned secrets.** If the Secret is created by an operator *after* some CR is applied (e.g. StackGres auto-creates `Secret/<cluster-name>` when it reconciles an `SGCluster`), the marker needs an explicit `requires` edge to that CR. Otherwise the marker lands in wave 0, the readiness poll starts before the operator has had a chance to materialize the Secret, and the deploy times out.

```nix
superuserRef = backendScope.mkSecretRef {
  name = builtins.unsafeDiscardStringContext clusterName;  # strips context
  keys = [ "superuser-username" "superuser-password" ];
  requires = [ postgres.raw.cluster ];  # <- re-establish the dep edge
};
```

`requires` is also the right place to re-add a dep edge when you had to `unsafeDiscardStringContext` a name (because `mkSecretRef`'s `name` flows through `builtins.toFile`, which forbids store-path context).

## Secret `out` API (same for both)

```nix
secret.out.name              # K8s name with dependency context
secret.out.keys              # declared key list
secret.out.type              # "Opaque" etc.

# Single key reference -> { valueFrom.secretKeyRef = { name, key }; }
secret.out.keyRef "password"

# Map env var names to secret keys -> [{ name, valueFrom.secretKeyRef }]
secret.out.mkEnv { DB_PASS = "password"; DB_USER = "username"; }

# Inject all keys -> { secretRef = { name }; }
secret.out.envFrom

# Volume -> { name, secret.secretName }
secret.out.volume "creds-vol"
```

`keyRef` and `mkEnv` validate keys at build time:
```nix
secret.out.keyRef "typo"
# -> error: secret "db-creds" does not declare key "typo"
#   declared keys: username, password
```

## Usage patterns

```nix
# Environment variables (most common)
env = creds.out.mkEnv {
  DB_PASSWORD = "password";
  DB_USER = "username";
};

# Single key with custom env name
env = [ (creds.out.keyRef "password" // { name = "DB_PASSWORD"; }) ];

# All keys as env vars
envFrom = [ creds.out.envFrom ];

# Volume mount (use with kix.mount.secret for full mount injection)
volumes = [ (creds.out.volume "creds-vol") ];
```

## Standalone packages for DI

`packages/secret` and `packages/secret-ref` wrap the primitives as first-class instances:

```nix
# Cluster definition -- standalone secret for DI
instances.cloudflare-api = {
  package = packages.secret;
  config = {
    keys = [ "api-token" ];
    source = ./secrets/cloudflare-api.yaml;
    hash = "sha256-...";
  };
};

# External secret ref for DI
instances.vault-creds = {
  package = packages.secret-ref;
  config.keys = [ "username" "password" ];
};

# Consumer receives via DI
instances.my-app.deps.credentials = instances.cloudflare-api;
```

## DON'T: reference secrets by raw string

```nix
# BAD -- no dependency tracking, no key validation
envFrom = [{ secretRef.name = "my-secret"; }];

# GOOD -- tracked, validated
envFrom = [ self.secret.out.envFrom ];
```
