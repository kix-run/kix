# Manage Secrets with SOPS

kix supports SOPS-encrypted secrets that are decrypted at deploy time and injected into Kubernetes `Secret` resources. The encrypted file lives alongside your cluster definition; the plaintext never touches the Nix store or git.

## How it works

1. You commit a SOPS-encrypted JSON file next to your cluster (`*.enc.json`).
2. A `packages.secret` instance points to that file via `source = ./...` and declares the `keys` it contains.
3. `nix build` produces a `Secret` manifest with a `kix.dev/sops-source` annotation but **no data**.
4. `kix deploy` sees the annotation, shells out to `sops --decrypt`, and injects the plaintext into `stringData` just before applying to the cluster.

The decryption is local to the deploying machine. Whoever runs `kix deploy` must have an age (or other SOPS) key that can decrypt the file.

## Prerequisites

The `devenv` shell provides everything you need: `sops`, `age`, and the `kix` CLI.

```bash
devenv shell
```

## One-time setup: age key

Generate an age key for yourself (once per machine):

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

The public key (`age1...`) gets written to stdout — copy it. The private key in `keys.txt` is what `sops` uses to decrypt; keep it safe and never commit it.

Tell `sops` where to find your key:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
```

(Add this to your shell rc, or rely on the devenv shell to set it.)

## Creating a secret

### 1. Pick a location

Encrypted files live next to the cluster that uses them, in a per-cluster subdirectory:

```
clusters/
├── my-cluster.nix
└── my-cluster/
    ├── .sops.yaml              # recipient config
    └── db-credentials.enc.json # encrypted secret
```

### 2. Configure SOPS recipients

Create `clusters/my-cluster/.sops.yaml` listing the age public keys allowed to decrypt files in this directory:

```yaml
creation_rules:
  - path_regex: \.enc\.json$
    age: >-
      age1youralicekey...,
      age1yourbobkey...
```

Every operator who needs to deploy this cluster must be in this list.

### 3. Write the plaintext

Create a flat JSON object with the keys your secret needs:

```bash
cat > /tmp/db-credentials.json <<EOF
{
  "username": "appuser",
  "password": "s3cret-p@ss!",
  "host": "db.prod.svc.cluster.local",
  "port": "5432"
}
EOF
```

Top-level keys must be strings (or numbers/bools, which get stringified). Nested objects are not supported — K8s `Secret.data` is flat.

### 4. Encrypt

```bash
sops --encrypt /tmp/db-credentials.json \
  > clusters/my-cluster/db-credentials.enc.json
rm /tmp/db-credentials.json
```

`sops` picks up `.sops.yaml` automatically, so you don't need to pass `--age` again.

**Commit the `.enc.json` file to git.** Nix needs it inside the flake source tree, and it's safe — it's encrypted.

### 5. Wire it into the cluster

In your cluster module, declare a `packages.secret` instance:

```nix
{ kix, packages }:

kix.buildCluster {
  name = "my-cluster";
  modules = [{
    instances = {
      app = {
        db-credentials = {
          package = packages.secret;
          config = {
            keys = [ "username" "password" "host" "port" ];
            source = ./my-cluster/db-credentials.enc.json;
          };
        };

        my-app = {
          package = packages.my-app;
          # references db-credentials via DI — see below
        };
      };
    };
  }];
}
```

The `keys` list is checked at build time: any package consuming this secret can only ask for keys you declared, so typos fail fast in `nix build` rather than at runtime.

### 6. Deploy

```bash
kix deploy my-cluster --yes
```

You'll see a line like:

```
🔓 default/db-credentials hydrated (4 keys from SOPS)
```

That confirms the SOPS file was decrypted and injected before apply.

## Editing an existing secret

Use `sops` directly — it opens the decrypted content in `$EDITOR` and re-encrypts on save:

```bash
sops clusters/my-cluster/db-credentials.enc.json
```

Commit the updated `.enc.json`. The next `kix deploy` will hydrate the new values.

## Adding a new recipient

When a new operator joins (or you add a new machine), add their age public key to `.sops.yaml`, then re-encrypt all files in that directory so the new recipient can decrypt them:

```bash
sops updatekeys clusters/my-cluster/db-credentials.enc.json
```

Commit the updated file.

## Inline secrets (no SOPS)

For local testing or non-sensitive values, `packages.secret` accepts `stringData` directly:

```nix
db-credentials = {
  package = packages.secret;
  config = {
    stringData = {
      username = "test";
      password = "test";
    };
  };
};
```

`keys` is then derived from `stringData`. **Don't use this for real secrets** — the values land in the Nix store and git history.

## Externally-managed secrets

If a secret is created by another tool (Vault Secrets Operator, External Secrets Operator, cert-manager, manual bootstrap), use `packages.secret-ref` instead. It produces no manifest but exposes the same `out` API (`keyRef`, `mkEnv`, `envFrom`, `volume`) so consuming packages don't need to know whether the secret is kix-managed or imported:

```nix
vault-db-creds = {
  package = packages.secret-ref;
  config = {
    keys = [ "username" "password" ];
  };
};
```

## Troubleshooting

**`sops: command not found`** — you're not in the devenv shell. Run `devenv shell`.

**`Failed to get the data key required to decrypt the SOPS file`** — your age key isn't in the recipient list, or `SOPS_AGE_KEY_FILE` isn't set. Check `.sops.yaml` and `echo $SOPS_AGE_KEY_FILE`.

**`SOPS source file not found`** — the path in `source = ./...` is wrong, or the file isn't tracked by git (Nix won't see untracked files inside a flake). Run `git add` on the `.enc.json` file.

**`content hash mismatch`** — the encrypted file changed but a pinned hash in the cluster definition didn't. This is opt-in via the `hash` option on `packages.secret`; if you're not using it, you won't see this error.
