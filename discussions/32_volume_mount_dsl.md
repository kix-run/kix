# 32 — Volume Mount DSL Redesign

**Status:** Active. The base constructors and injection helpers exist in `kix/lib/vocab/mounts.nix`. Volume deduplication (Phase 3) shipped in 0.7: `withMountsOn` takes a list of container names, searches init containers, and declares a volume once when its name and source match. The proposed `.path` exposure, `.mountAt` on resources, and the volume/mount-point split are not implemented.

## Status quo

### What exists in `lib/compose.nix`

The current mount DSL provides typed constructors and injection helpers:

**Constructors** — each returns a `{ _type = "kix-mount"; name; mountPath; source; ... }` attrset:

| Constructor | Source | Name auto-derived from |
|---|---|---|
| `kix.mount.pvc resource { mountPath; ... }` | `persistentVolumeClaim.claimName` | `resource.out.name` |
| `kix.mount.configMap resource { mountPath; ... }` | `configMap.name` | `resource.out.name` |
| `kix.mount.secret resource { mountPath; ... }` | `secret.secretName` | `resource.out.name` |
| `kix.mount.emptyDir { mountPath; name; ... }` | `emptyDir {}` | (required arg) |

All constructors accept optional `subPath`, and the resource-backed ones accept optional `name` override, `items`, `defaultMode`.

**Injection helpers** — stamp volumes + volumeMounts onto a pre-seal workload attrset:

```nix
# Single container (errors on multi-container):
deployment = { ... } |> kix.withMounts [ m1 m2 ] |> scope.mkDeployment;

# Target a named container:
deployment = { ... } |> kix.withMountsOn "registry" [ m1 m2 ] |> scope.mkDeployment;
```

`_injectMounts` splits each mount object into a K8s `volume` entry (from `source`) and a `volumeMount` entry (from `name`/`mountPath`/`subPath`/`readOnly`), appends them to the existing lists.

### What does NOT exist

- No way to query a mount's path after creation (`mount.path` or `mount.mountPath`).
- No `hostPath` or `projected` constructors.
- Mount objects are plain attrsets with no `out.*` properties — they are not resources.

---

## Pain points (concrete examples)

### 1. Velero — credential secret mounted identically in 7 places

The credential secret volume appears in both the Deployment and the DaemonSet, each defining the volume + volumeMount manually (velero does not use `kix.mount.*` at all):

```nix
# Deployment container volumeMounts (line 426):
{ name = "cloud-credentials"; mountPath = "/credentials"; }

# Deployment volumes (line 445):
{ name = "cloud-credentials"; secret = { secretName = credentialSecretName; defaultMode = 420; }; }

# DaemonSet container volumeMounts (line 527):
{ name = "cloud-credentials"; mountPath = "/credentials"; }

# DaemonSet volumes (line 551):
{ name = "cloud-credentials"; secret.secretName = credentialSecretName; }
```

The string `"cloud-credentials"` appears 4 times, `"/credentials"` appears 2 times, and `credentialSecretName` appears 2 times — just for one volume across two workloads. The credential *path* `/credentials` is also hardcoded in 4 env vars:

```nix
credentialEnvVars = [
  { name = "AWS_SHARED_CREDENTIALS_FILE";     value = "/credentials/cloud"; }
  { name = "GOOGLE_APPLICATION_CREDENTIALS";   value = "/credentials/cloud"; }
  { name = "AZURE_CREDENTIALS_FILE";           value = "/credentials/cloud"; }
  { name = "ALIBABA_CLOUD_CREDENTIALS_FILE";   value = "/credentials/cloud"; }
];
```

If the mount path changes, 6+ locations must be updated in sync.

### 2. Harbor registry — 2 containers share volumes, bypassing kix.mount entirely

The registry Deployment has `registry` + `registryctl` containers that share `registry-config` and `registry-data` volumes. Because `kix.withMounts` targets one container (or all-if-single), the package falls back to raw K8s:

```nix
# Container "registry" volumeMounts (line 776):
{ name = "registry-config"; mountPath = "/etc/registry/config.yml"; subPath = "config.yml"; }
{ name = "registry-data";   mountPath = "/storage"; }

# Container "registryctl" volumeMounts (line 831):
{ name = "registry-config"; mountPath = "/etc/registry/config.yml"; subPath = "config.yml"; }
{ name = "registry-config"; mountPath = "/etc/registryctl/config.yml"; subPath = "ctl-config.yml"; }
{ name = "registry-data";   mountPath = "/storage"; }

# Pod volumes (line 850):
{ name = "registry-config"; configMap.name = self.registryConfigMap.out.name; }
{ name = "registry-data";   persistentVolumeClaim.claimName = self.registryPVC.out.name; }
{ name = "registry-htpasswd"; secret = { secretName = ...; items = [...]; }; }
```

The volume name `"registry-config"` appears 5 times. The volume name `"registry-data"` appears 3 times. All wiring is manual — the mount helpers buy nothing here.

### 3. Immich ML — mount path duplicated in env vars

The current DSL already works well for the single-container case:

```nix
cacheMount = kix.mount.pvc self.cachePvc { mountPath = "/cache"; };
# or
cacheMount = kix.mount.emptyDir { mountPath = "/cache"; name = "cache"; };
```

But the mount path `/cache` is duplicated in 3 env vars:

```nix
env = kix.mkEnvVars {
  TRANSFORMERS_CACHE   = "/cache";
  HF_XET_CACHE         = "/cache/huggingface-xet";
  MPLCONFIGDIR         = "/cache/matplotlib-config";
};
```

If someone changes the PVC mount path, these break silently.

---

## Proposed redesign

### Design principles

1. **Mount objects expose `path`** — so env vars and config can reference the mount instead of hardcoding strings.
2. **Resources are mount-aware** — volume-backing resources (PVC, ConfigMap, Secret) expose `.mount` / `.mountAt` builders, eliminating type dispatch.
3. **Volumes are declared once, mounted per-container** — separating "what volume" from "where it goes" eliminates the name-sync problem for multi-container pods.
4. **Single-container convenience is preserved** — the common case should not get more verbose.
5. **Raw escape hatches remain** — packages can always use plain `volumes`/`volumeMounts` in the attrset.
6. **`.path` is a plain string** — no string context on mount paths (see design decision below).

### Core change 1: mount objects gain `.path`

```nix
# Mount constructor returns an object with a queryable path:
credMount = kix.mount.secret self.credentialSecret {
  mountPath = "/credentials";
  defaultMode = 420;
};

credMount.path          # => "/credentials"
credMount.path + "/cloud"  # => "/credentials/cloud" — composable
```

This is a non-breaking addition: mount objects already carry `mountPath`; we just expose it as `.path` for ergonomic access.

### Core change 2: resources expose `.mount` / `.mountAt`

Volume-backing resources (PVC, ConfigMap, Secret) gain builder methods directly on the resource object:

```nix
# Instead of:
cacheMount = kix.mount.pvc self.cachePvc { mountPath = "/cache"; };

# You write:
cacheMount = self.cachePvc.mountAt "/cache";

# Or with options:
cacheMount = self.cachePvc.mount { mountPath = "/cache"; readOnly = true; };
```

**Why this works:**
- Follows "resources are rich objects" — the PVC knows its own type, so the user doesn't dispatch through `kix.mount.pvc` vs `kix.mount.configMap` vs `kix.mount.secret`.
- Eliminates a class of errors: you can't accidentally use `kix.mount.pvc` on a ConfigMap.
- More discoverable — you look at the resource and see what operations it supports.

**Where it lives:** Not in `out` (values there get stringified + context-attached, functions wouldn't survive). Instead, directly on the resource object alongside `manifest`, `rawManifest`, `requires`, etc. Each higher-level builder adds the appropriate mount constructor:

```nix
# In the PVC builder:
resource // {
  mountAt = mountPath: kix.mount.pvc resource { inherit mountPath; };
  mount = args: kix.mount.pvc resource args;
}

# In the ConfigMap builder:
resource // {
  mountAt = mountPath: kix.mount.configMap resource { inherit mountPath; };
  mount = args: kix.mount.configMap resource args;
}

# In the Secret builder:
resource // {
  mountAt = mountPath: kix.mount.secret resource { inherit mountPath; };
  mount = args: kix.mount.secret resource args;
}
```

Not all resources are mountable (a Deployment isn't), so `.mount`/`.mountAt` only appear on volume-backing kinds.

**`emptyDir` stays as `kix.mount.emptyDir`** — it has no backing resource, so there's nothing to put the builder on.

### Before/after: Velero

**Before** (current):
```nix
credentialEnvVars = lib.optionals hasCredentials [
  { name = "AWS_SHARED_CREDENTIALS_FILE";   value = "/credentials/cloud"; }
  { name = "GOOGLE_APPLICATION_CREDENTIALS"; value = "/credentials/cloud"; }
  { name = "AZURE_CREDENTIALS_FILE";        value = "/credentials/cloud"; }
  { name = "ALIBABA_CLOUD_CREDENTIALS_FILE"; value = "/credentials/cloud"; }
];

# In Deployment spec:
volumeMounts = lib.optionals hasCredentials [
  { name = "cloud-credentials"; mountPath = "/credentials"; }
] ++ [ ... ];
volumes = lib.optionals hasCredentials [
  { name = "cloud-credentials"; secret = { secretName = credentialSecretName; defaultMode = 420; }; }
] ++ [ ... ];

# Same volume+volumeMount block repeated in DaemonSet.
```

**After**:
```nix
# Declare mount once in let:
credMount = self.secret.mount {
  mountPath = "/credentials";
  defaultMode = 420;
};

credentialEnvVars = lib.optionals hasCredentials (kix.mkEnvVars {
  AWS_SHARED_CREDENTIALS_FILE   = credMount.path + "/cloud";
  GOOGLE_APPLICATION_CREDENTIALS = credMount.path + "/cloud";
  AZURE_CREDENTIALS_FILE        = credMount.path + "/cloud";
  ALIBABA_CLOUD_CREDENTIALS_FILE = credMount.path + "/cloud";
});

# Deployment — single container, same as today:
deployment = { ... }
  |> kix.withMounts [ credMount pluginsMount scratchMount ]
  |> scope.mkDeployment;

# DaemonSet — reuses the same mount object:
nodeAgent = { ... }
  |> kix.withMounts [ credMount hostPluginsMount hostPodsMount scratchMount ]
  |> scope.mkDaemonSet;
```

**Wins**: mount path `/credentials` defined once. Env vars reference `credMount.path`. Both workloads reuse the same mount object — volume name matching is automatic. No type dispatch — the secret knows it's a secret.

### Before/after: Harbor registry (multi-container)

**Before** (current — raw K8s, no mount helpers):
```nix
# Both containers manually list volumeMounts with matching names.
# Pod volumes manually listed with matching names.
# 5 occurrences of "registry-config", 3 of "registry-data".
```

**After** — option A: `withMountsOn` per container:
```nix
registryConfigMount = self.registryConfigMap.mountAt "/etc/registry";
registryDataMount   = self.registryPVC.mountAt "/storage";
htpasswdMount       = self.registryHtpasswdSecret.mount {
  mountPath = "/etc/registry/passwd";
  subPath = "passwd";
  items = [{ key = "REGISTRY_HTPASSWD"; path = "passwd"; }];
  defaultMode = 420;
};

registryDeployment = { ... (containers with no volumeMounts) ... }
  |> kix.withMountsOn "registry" [
    (registryConfigMount // { subPath = "config.yml"; mountPath = "/etc/registry/config.yml"; })
    htpasswdMount
    registryDataMount
  ]
  |> kix.withMountsOn "registryctl" [
    (registryConfigMount // { subPath = "config.yml";     mountPath = "/etc/registry/config.yml"; })
    (registryConfigMount // { subPath = "ctl-config.yml"; mountPath = "/etc/registryctl/config.yml"; })
    registryDataMount
  ]
  |> scope.mkDeployment;
```

This already works today with `withMountsOn`, but has a subtle problem: each `withMountsOn` call appends the volume to the pod-level `volumes` list independently. If the same mount (same `name`) is used in two `withMountsOn` calls, the volume appears twice.

**Fix needed**: `_injectMounts` should deduplicate volumes by name. This is the only implementation change required.

**After** — option B: split volume from mount-point (new API for complex cases):

```nix
# Volume = "what storage backs this"
# .volume creates a kix-volume without a mount-point:
registryConfigVol = self.registryConfigMap.volume {};
registryDataVol   = self.registryPVC.volume {};
htpasswdVol       = self.registryHtpasswdSecret.volume {
  items = [{ key = "REGISTRY_HTPASSWD"; path = "passwd"; }];
  defaultMode = 420;
};

# Mount-point = "where a container sees it"
# .at creates a lightweight mount-point: { volume, mountPath, subPath? }
registryConfigYml  = registryConfigVol.at "/etc/registry/config.yml"     // { subPath = "config.yml"; };
ctlConfigYml       = registryConfigVol.at "/etc/registryctl/config.yml"  // { subPath = "ctl-config.yml"; };
storageDir         = registryDataVol.at "/storage";
passwdFile         = htpasswdVol.at "/etc/registry/passwd"               // { subPath = "passwd"; };

registryDeployment = { ... }
  |> kix.withMountsOn "registry"    [ registryConfigYml passwdFile storageDir ]
  |> kix.withMountsOn "registryctl" [ registryConfigYml ctlConfigYml storageDir ]
  |> scope.mkDeployment;
```

In option B, `.at` creates a mount-point referencing the parent volume. `_injectMounts` collects unique volumes from mount-points and generates the pod `volumes` list automatically. The volume name is derived once from the resource — never typed by hand.

Note: `.volume` lives on the resource (like `.mount`/`.mountAt`), not on `out`. `kix.volume.emptyDir` remains a standalone constructor for the same reason `kix.mount.emptyDir` does.

### Before/after: Immich ML

**Before**:
```nix
cacheMount = kix.mount.pvc self.cachePvc { mountPath = "/cache"; };

env = kix.mkEnvVars {
  TRANSFORMERS_CACHE = "/cache";
  HF_XET_CACHE       = "/cache/huggingface-xet";
  MPLCONFIGDIR        = "/cache/matplotlib-config";
};
```

**After**:
```nix
cacheMount = self.cachePvc.mountAt "/cache";

env = kix.mkEnvVars {
  TRANSFORMERS_CACHE = cacheMount.path;
  HF_XET_CACHE       = cacheMount.path + "/huggingface-xet";
  MPLCONFIGDIR        = cacheMount.path + "/matplotlib-config";
};
```

Minimal change — `.mountAt` + `.path` together eliminate both the type dispatch and the path duplication.

---

## Design decision: no string context on `.path`

### The question

Should `cacheMount.path` carry the backing resource's Nix string context? This would mean using `cacheMount.path` in an env var automatically creates a DAG edge to the PVC.

### Decision: `.path` is a plain string — no context

### Arguments for context on `.path` (rejected)

- **Validation**: you could detect "this workload references a mount path but doesn't actually have that volume attached" by checking whether the env var's context references a PVC that isn't in the workload's volume list.
- **Completeness**: if env vars are the *only* way a workload references a PVC (unusual but possible), the dependency still gets tracked.

### Arguments against (why we rejected it)

1. **Semantic mismatch.** `"/cache"` is a container-internal filesystem path, not a K8s resource reference. The *volume definition* references the PVC — the mount path is arbitrary. Attaching PVC identity to an arbitrary path is a category error.

2. **Phantom dependencies.** If workload A uses `credMount.path` in an env var but workload B is the one that actually mounts the volume, workload A gets a false dependency on the secret. The path is only meaningful if the mount is attached to *this* workload — context can't express that conditional.

3. **Context propagation is viral.** `cacheMount.path + "/huggingface-xet"` would carry PVC context through every derived string. If those strings end up in ConfigMaps or other resources, you get spurious DAG edges.

4. **`emptyDir` asymmetry.** `emptyDir` mounts have no backing resource. Context-bearing paths for PVC/ConfigMap/Secret but context-free paths for `emptyDir` is an inconsistency that would surprise users.

5. **Dependency tracking already works.** The mount's `source.persistentVolumeClaim.claimName` (or `source.configMap.name`, etc.) already carries context. When `withMounts` injects the volume into the workload, the dependency is tracked through the manifest. Adding context to `.path` is redundant for the common case.

### Alternative: structural lint instead of context

For the validation use case (detecting mount-path references without a matching volume), a structural lint is more precise:

- Mount objects carry `_backingResource` (a reference to the resource, not stringified).
- A lint pass checks: "every `_backingResource` referenced by mounts in `withMounts` calls resolves to a resource in this package."
- This catches real errors without the false-positive problem of context propagation.

---

## Implementation plan

### Phase 1: Add `.path` to mount objects (non-breaking)

Each mount constructor already stores `mountPath`. Add:

```nix
path = mountPath;
```

to every returned attrset. This is backward-compatible — existing code ignores extra keys.

For option B mount-points (`.at`), the path comes from the `.at` argument.

### Phase 2: Add `.mount` / `.mountAt` to volume-backing resources

Each higher-level builder (PVC, ConfigMap, Secret) adds mount builders to the resource object:

```nix
resource // {
  mountAt = mountPath: kix.mount.<type> resource { inherit mountPath; };
  mount = args: kix.mount.<type> resource args;
}
```

The existing `kix.mount.*` constructors remain as the underlying implementation (and as a direct API for users who prefer explicit type dispatch). `.mountAt` / `.mount` are convenience wrappers.

`kix.mount.emptyDir` stays standalone — no backing resource to attach to.

### Phase 3: Deduplicate volumes in `_injectMounts`

Change the volume list construction from:

```nix
volumes = map (m: { inherit (m) name; } // m.source) validMounts;
```

to:

```nix
volumes = lib.unique (map (m: { inherit (m) name; } // m.source) validMounts);
```

Or better, deduplicate by `name` key (last wins, or error on conflict). This makes chained `withMountsOn` safe for shared volumes.

### Phase 4 (optional): Volume/mount-point split for complex cases

Add `.volume` to volume-backing resources, returning `{ _type = "kix-volume"; name; source; at = mountPath: { ... }; }`. The `.at` method creates a mount-point referencing the parent volume.

`_injectMounts` would detect both old-style mount objects and new-style mount-points, extracting unique volumes from either.

This is only needed if the option A pattern (reusing mount objects with `//` overrides) proves too awkward.

### Phase 5: Add `hostPath` and `projected` constructors

```nix
kix.mount.hostPath { mountPath = "/host_pods"; hostPath = "/var/lib/kubelet/pods"; type = "Directory"; }
kix.mount.projected { mountPath = "/tokens"; sources = [ ... ]; }
```

Straightforward — same pattern as `emptyDir`.

---

## Escape hatches

Raw volumes and volumeMounts in the workload attrset continue to work. `_injectMounts` appends to existing lists — it never overwrites them. This means packages like harbor can mix mount-helper volumes with hand-written ones during migration.

## Non-goals

- **Mount objects are not resources.** They do not get store paths or participate in the DAG. They are composition helpers.
- **No mount inheritance across packages.** Mounts are local to a package's build function. Cross-package volume sharing goes through PVC resources (DI).
- **No implicit env var injection.** The DSL provides `.path` for manual wiring. Auto-injecting env vars from mounts would be too magical.
- **No string context on `.path`.** See design decision above. Dependency tracking goes through `source.*` fields, not mount paths.
