# CRDs and Type Providers in v2

## Working Document -- March 2026

**Status:** Design exploration
**Predecessors:** doc 02 (type providers, section 11), doc 03 (native store path tracking, section 4.5)

---

## 1. The Problem, Restated for v2

CRDs are the only K8s resource type where the consumer has **no textual reference** to the dependency in its spec. A Certificate CR says `apiVersion: cert-manager.io/v1` and `kind: Certificate` -- it never mentions the CRD resource name `certificates.cert-manager.io` or the controller deployment `cert-manager-controller`. There is nothing for `${}` to track.

In v1, the custom ref system had the same blind spot -- the tree walker could not detect CRD dependencies either. The solution was `requires`: manual inverted deps. v1 introduced `mkTypeProvider` to inject those `requires` automatically via a constructor function.

v2 replaces refs with native store path tracking (doc 03). The `${}` mechanism works for all normal resource references (ConfigMap names, Service FQDNs, etc.). But the CRD gap remains: **no `${}` interpolation means no automatic tracking**. `requires` is still essential for CRDs in v2, and `mkTypeProvider` is still the mechanism that injects it transparently.

The question is how `mkTypeProvider` integrates with native store paths, sub-components, the outer fixpoint, and DI resolution.

---

## 2. Type Providers with Native Store Paths

### 2.1 The Core Mechanism

A type provider is a constructor function that wraps `mkResource`. It injects `requires` pointing at the CRD derivation and the controller derivation:

```nix
mkTypeProvider = { crd, controller }:
  {
    inherit crd controller;

    mk = { name, namespace, spec, ... }@args:
      mkResource ({
        apiVersion = crd.apiVersion;
        kind = crd.kind;
        inherit name namespace spec;
        # This is the key line: automatic requires injection
        requires = (args.requires or []) ++ [ crd controller ];
      } // builtins.removeAttrs args [ "requires" ]);
  };
```

This is **unchanged from v1**. The reason: `requires` was always a manual/semantic concept, independent of the tracking mechanism. Whether deps are tracked via refs or store paths, `requires` is still just "include these derivations in my closure and order them before me."

What changes is how the CRD and controller are represented. In v2, they are derivations with store paths. `crd` has an `outPath` like `/nix/store/<hash>-k8s-CRD-certificates.cert-manager.io`. The `requires` list holds derivations, and closure computation finds them via the `requires` attribute, not via `builtins.getContext`.

### 2.2 Why `${}` Cannot Help Here

Consider what would happen if we tried to use `${}` tracking for CRDs:

```nix
# Hypothetical: embed CRD store path somewhere in the CR spec
certificate = mkResource {
  apiVersion = "cert-manager.io/v1";
  kind = "Certificate";
  spec.secretName = "my-tls";
  # Where would we put ${crd}? There's no field for it.
  # K8s will reject any unknown field.
};
```

There is no field in a Certificate spec that references the CRD. The dependency is **structural** (the `kind` field implies it) not **referential** (no name points to it). This is why `requires` exists as a concept -- it captures semantic dependencies that have no syntactic manifestation.

### 2.3 What the Type Provider Constructor Does for You

Without a type provider, every CR creation would need manual wiring:

```nix
# Without type provider -- error-prone, verbose
certificate = mkResource {
  apiVersion = "cert-manager.io/v1";
  kind = "Certificate";
  name = "my-tls";
  namespace = scope.namespace;
  spec.secretName = "my-tls";
  requires = [ certManager.crds.certificate certManager.controller ];  # manual!
};
```

With a type provider, the `requires` injection is invisible to the consumer:

```nix
# With type provider -- clean, correct by construction
certificate = certManager.types.certificate.mk {
  name = "my-tls";
  namespace = scope.namespace;
  spec.secretName = "my-tls";
};
```

The consumer does not know or care about CRDs and controllers. They call `.mk` and get a correctly-wired resource.

---

## 3. CRDs as Sub-Components

### 3.1 The Split Closure Pattern

Doc 03 (section 2.5) establishes that packages can expose **sub-components** -- derivations with their own smaller closures. CRDs are the canonical example:

```nix
certManager = mkPackage (args: self: {
  # CRD resources -- each is its own derivation
  certificateCRD = mkResource {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    name = "certificates.cert-manager.io";
    namespace = clusterScoped;
    spec = { /* full CRD spec */ };
  };

  issuerCRD = mkResource { /* ... */ };
  clusterIssuerCRD = mkResource { /* ... */ };

  # Controller deployment
  controller = mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "cert-manager-controller";
    namespace = scope.namespace;
    # Controller depends on CRDs existing first
    requires = builtins.attrValues self.crds;
    spec = { /* ... */ };
  };

  # Sub-component exposure -- intentional seams
  crds = {
    certificate = self.certificateCRD;
    issuer = self.issuerCRD;
    clusterIssuer = self.clusterIssuerCRD;
  };

  # Type providers -- the recommended consumer interface
  types = {
    certificate = mkTypeProvider {
      crd = self.crds.certificate;
      controller = self.controller;
    };
    issuer = mkTypeProvider {
      crd = self.crds.issuer;
      controller = self.controller;
    };
    clusterIssuer = mkTypeProvider {
      crd = self.crds.clusterIssuer;
      controller = self.controller;
    };
  };

  # RBAC, webhooks, etc.
  serviceAccount = mkResource { /* ... */ };
  clusterRole = mkResource { /* ... */ };
  clusterRoleBinding = mkResource { /* ... */ };
  webhook = mkResource { /* ... */ };

  # Main carries everything
  main = withRequires [
    self.controller
    self.serviceAccount
    self.clusterRoleBinding
    self.webhook
  ] self.service;
});
```

### 3.2 Closure Sizes

The package exposes three closure granularities:

| Access | What you get | Closure size |
|---|---|---|
| `certManager.main` | Full cert-manager: CRDs + controller + RBAC + webhooks + service | Everything |
| `certManager.types.certificate.mk { ... }` | A CR that requires CRD + controller | CRD + controller + its RBAC (but not webhooks unless controller requires them) |
| `certManager.crds.certificate` | Just the CRD derivation | One resource |

The third case -- requiring just the CRD without the controller -- is unusual but valid. Example: a CI job that needs to `kubectl apply` CRDs as a setup step before running integration tests, without deploying the full controller. The package author exposes this seam intentionally.

### 3.3 How `controller requires crds` Interacts with the Fixpoint

The controller has `requires = builtins.attrValues self.crds`. This means the controller's closure includes all CRDs. Since type providers reference the controller, and CRs produced by type providers require the controller, the full chain is:

```
CR (via .mk)
  requires -> CRD (deploy first)
  requires -> controller
               requires -> all CRDs (deploy first)
               deps -> ServiceAccount, RBAC, etc. (from ${} in spec)
```

The deploy order falls out of the DAG:
1. CRDs (no deps)
2. RBAC resources (no deps on CRDs)
3. Controller deployment (requires CRDs, deps on RBAC)
4. CRs (require controller and their specific CRD)
5. Resources that reference CRs (e.g., Ingress referencing a secret created by a Certificate)

The inner fixpoint (`self.crds`, `self.controller`) resolves all of these lazily. No circularity issues because the direction is always CR -> controller -> CRDs.

---

## 4. Shared CRDs and the Outer Fixpoint

### 4.1 The Simple Case: Same Version

Two packages both need cert-manager certificates:

```nix
# Outer fixpoint
clusterPackages = self: {
  certManager = mkCertManager { namespace = "cert-manager"; };

  myApp = mkMyApp {
    namespace = "production";
    certManager = self.certManager;       # DI
  };

  otherApp = mkOtherApp {
    namespace = "staging";
    certManager = self.certManager;       # same instance
  };
};
```

Both `myApp` and `otherApp` receive the same `certManager` package. Both call `certManager.types.certificate.mk { ... }`. The `requires` in both CRs point to the **same** CRD and controller derivations (same store paths). When computing the cluster closure, deduplication is automatic -- same store path means same resource.

The combined cluster closure includes:
- cert-manager CRDs (once)
- cert-manager controller (once)
- myApp's Certificate CR
- otherApp's Certificate CR
- everything else each app needs

### 4.2 With Auto-Resolution (doc 04)

If `certManager` is a well-known infrastructure service, DI resolution handles it automatically:

```nix
# Package signature
mkMyApp = { scope, config, certManager, ... }: ...

# Cluster config -- just declare cert-manager exists
services.cert-manager = {
  package = "cert-manager";
  namespace = "cert-manager";
};

services.my-app = {
  namespace = "production";
  # certManager auto-resolved: only one cert-manager-type instance
};
```

The resolution finds `cert-manager` by package type. The injected value is the full package, including `.types`. The consumer uses `certManager.types.certificate.mk` as before.

### 4.3 The Hard Case: Version Conflicts

Team A wants cert-manager v1.13, team B wants v1.14. This is fundamentally a cluster-level decision, not a package-level one. CRDs are **cluster-scoped** -- you cannot have two versions of the same CRD in a cluster.

There are three scenarios:

**Scenario 1: Both teams use the same cluster.** One version wins. The cluster operator decides:

```nix
services.cert-manager = {
  package = "cert-manager";
  version = "1.14";  # cluster-wide decision
};
```

Team A's code must work with v1.14. If it does not, that is a compatibility issue to resolve before deploying -- the same constraint that exists with any shared infrastructure in Kubernetes.

**Scenario 2: Different clusters.** Each cluster has its own fixpoint, its own cert-manager version. No conflict.

**Scenario 3: Multiple CRD versions in one cluster (hypothetical).** Kubernetes itself does not support this. A CRD name is globally unique. If two packages tried to create `certificates.cert-manager.io` with different specs, the cluster would reject the second one (or one would overwrite the other). kixpkgs should **detect this at eval time**:

```nix
# In the cluster evaluator: check for CRD name collisions
let
  allCRDs = collectAllCRDs clusterResources;
  duplicates = groupBy (crd: crd.name) allCRDs
    |> filterAttrs (_: crds: length crds > 1);
in
  assert duplicates == {} ||
    throw "CRD name collision: ${concatStringsSep ", " (attrNames duplicates)}";
```

This catches the error at `nix eval` time rather than at `kubectl apply` time.

### 4.4 CRD Version Upgrades

When the cluster operator bumps cert-manager from v1.13 to v1.14:

1. The `certManager` package derivation changes (different version, different spec)
2. All CRD derivation hashes change (different content)
3. The controller derivation hash changes
4. All CRs that require these CRDs get new hashes (their `requires` changed)
5. `nix-diff` shows exactly what changed and why

The Merkle DAG propagation is correct here: a CRD version bump genuinely affects every CR that uses it (the API server validates CRs against the CRD schema). The changed hashes reflect a real change in the system's state.

---

## 5. CRD Ordering: What `requires` Should Express

### 5.1 The Ordering Question

A CR needs two things to work:
1. The CRD must exist (API server rejects unknown types)
2. The controller must be running (otherwise the CR is never reconciled)

The type provider injects `requires = [ crd controller ]` on every CR. This means the deploy order is: CRD first, then controller, then CR. But is this the right model?

### 5.2 Analysis: CRD in `requires` Is Mandatory

Without the CRD in the closure, `kubectl apply` of the CR fails immediately:

```
error: unable to recognize "certificate.yaml":
  no matches for kind "Certificate" in version "cert-manager.io/v1"
```

The CRD must be applied before the CR. `requires` on the CR pointing to the CRD is the correct way to express this -- it says "include this in my closure and order it before me."

### 5.3 Analysis: Controller in `requires` Is Also Correct

Without the controller, the CR is accepted by the API server (the CRD makes the type known) but nothing happens -- the CR sits with no status updates, no reconciliation. This is not a hard failure (the API server does not reject it), but it is a semantic failure (the CR is useless).

Including the controller in `requires` means:
- The controller is in the CR's closure (deployed when you deploy the CR)
- The controller is ordered before the CR in the deploy sequence
- If you deploy just the CR's closure, you get the controller too

This is the right behavior. A CR without its controller is like a Deployment without its ServiceAccount -- technically valid YAML, practically broken.

### 5.4 Should the Controller Require CRDs?

Yes. The controller deployment should have `requires = attrValues self.crds` because:

1. The controller itself often creates CRs (cert-manager creates internal Orders, Challenges). It needs the CRDs to exist.
2. Even if the controller does not create CRs, it cannot watch for them until the CRD exists. Starting the controller before CRDs leads to log spam and restarts.
3. It makes the dependency chain unambiguous: CRDs -> controller -> CRs.

The full chain is:

```
Certificate CR
  requires -> certificates.cert-manager.io CRD   (ordering: CRD before CR)
  requires -> cert-manager-controller             (ordering: controller before CR)
               requires -> all CRDs               (ordering: CRDs before controller)
               deps (via ${}) -> ServiceAccount, ClusterRoleBinding, etc.
```

Deploy order: CRDs, then RBAC (parallel with CRDs since no dependency), then controller, then CRs. Topological sort of the DAG produces the correct sequence.

### 5.5 What About Controller Readiness?

`requires` only expresses **ordering** -- "apply A before B." It does not express **readiness** -- "wait until A is Running before applying B." This is intentional.

Controller readiness is a runtime concern. The deploy tool (or kubectl with `--wait`) handles it:

```bash
# Apply CRDs
kubectl apply -f crds.yaml

# Apply controller and wait for readiness
kubectl apply -f controller.yaml
kubectl rollout status deployment/cert-manager-controller

# Apply CRs
kubectl apply -f certificates.yaml
```

kixpkgs provides the **correct ordering** from the DAG. The deploy tool provides the **readiness waiting**. Separation of concerns.

An alternative: kixpkgs could annotate resources with readiness conditions:

```nix
controller = mkResource {
  # ...
  readiness.condition = "Available";  # wait for Deployment condition
};
```

The deploy tool reads this annotation and waits. But this is a deploy-tool concern, not a dependency-graph concern. The DAG is correct regardless of whether the deploy tool waits.

---

## 6. Type Provider DX: Complete Examples

### 6.1 Defining a CRD-Providing Package

```nix
# packages/cert-manager.nix
{ scope, config }:

let
  mkCRD = { name, group, kind, versions, spec }:
    mkResource {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      name = name;
      namespace = clusterScoped;
      spec = spec // {
        group = group;
        names = {
          inherit kind;
          plural = builtins.replaceStrings [" "] [""] (lib.toLower kind) + "s";
          singular = lib.toLower kind;
        };
        scope = "Namespaced";
        versions = map (v: {
          name = v.name;
          served = true;
          storage = v.storage or false;
          schema.openAPIV3Schema = v.schema;
        }) versions;
      };
    } // { inherit group kind; apiVersion = "${group}/${(builtins.head versions).name}"; };

in self: {
  # ---- CRD resources ----
  crds = {
    certificate = mkCRD {
      name = "certificates.cert-manager.io";
      group = "cert-manager.io";
      kind = "Certificate";
      versions = [{ name = "v1"; storage = true; schema = { /* ... */ }; }];
      spec = {};
    };
    issuer = mkCRD {
      name = "issuers.cert-manager.io";
      group = "cert-manager.io";
      kind = "Issuer";
      versions = [{ name = "v1"; storage = true; schema = { /* ... */ }; }];
      spec = {};
    };
    clusterIssuer = mkCRD {
      name = "clusterissuers.cert-manager.io";
      group = "cert-manager.io";
      kind = "ClusterIssuer";
      versions = [{ name = "v1"; storage = true; schema = { /* ... */ }; }];
      spec = {};
    };
  };

  # ---- Controller ----
  serviceAccount = mkResource {
    apiVersion = "v1"; kind = "ServiceAccount";
    name = "cert-manager";
    namespace = scope.namespace;
    requires = [ self.clusterRoleBinding ];
  };

  clusterRole = mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    name = "cert-manager-controller";
    namespace = clusterScoped;
    rules = [ /* cert-manager RBAC rules */ ];
  };

  clusterRoleBinding = mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "cert-manager-controller";
    namespace = clusterScoped;
    spec = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "${self.clusterRole}";  # native ${} tracking
      };
      subjects = [{
        kind = "ServiceAccount";
        name = "${self.serviceAccount}";  # native ${} tracking
        namespace = scope.namespace;
      }];
    };
  };

  controller = mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "cert-manager-controller";
    namespace = scope.namespace;
    requires = builtins.attrValues self.crds;  # CRDs before controller
    spec.template.spec = {
      serviceAccountName = "${self.serviceAccount}";
      containers = [{
        name = "controller";
        image = config.image or "quay.io/jetstack/cert-manager-controller:v${config.version or "1.14.0"}";
        args = [
          "--v=2"
          "--cluster-resource-namespace=${scope.namespace}"
        ];
      }];
    };
  };

  webhook = mkResource {
    apiVersion = "apps/v1";
    kind = "Deployment";
    name = "cert-manager-webhook";
    namespace = scope.namespace;
    spec.template.spec = {
      serviceAccountName = "${self.serviceAccount}";
      containers = [{
        name = "webhook";
        image = config.webhookImage or "quay.io/jetstack/cert-manager-webhook:v${config.version or "1.14.0"}";
      }];
    };
  };

  webhookService = mkResource {
    apiVersion = "v1"; kind = "Service";
    name = "cert-manager-webhook";
    namespace = scope.namespace;
    spec.ports = [{ port = 443; targetPort = 10250; }];
  };

  # ---- Type providers: the public API ----
  types = {
    certificate = mkTypeProvider {
      crd = self.crds.certificate;
      controller = self.controller;
    };
    issuer = mkTypeProvider {
      crd = self.crds.issuer;
      controller = self.controller;
    };
    clusterIssuer = mkTypeProvider {
      crd = self.crds.clusterIssuer;
      controller = self.controller;
    };
  };

  # ---- Service (entrypoint for the package) ----
  service = mkResource {
    apiVersion = "v1"; kind = "Service";
    name = "cert-manager";
    namespace = scope.namespace;
    spec.ports = [{ port = 9402; name = "metrics"; }];
  };

  main = withRequires [
    self.controller
    self.webhook
    self.webhookService
  ] self.service;
}
```

### 6.2 Consuming a Type Provider

```nix
# packages/my-web-app.nix
{ scope, config, certManager }:

in self: {
  # Use the type provider to create a Certificate
  certificate = certManager.types.certificate.mk {
    name = "${scope.instanceName}-tls";
    namespace = scope.namespace;
    spec = {
      secretName = "${scope.instanceName}-tls-secret";
      issuerRef = {
        name = "${self.clusterIssuer}";  # ${} tracks dep on our issuer
        kind = "ClusterIssuer";
      };
      dnsNames = config.domains or [ "${scope.instanceName}.example.com" ];
    };
  };

  clusterIssuer = certManager.types.clusterIssuer.mk {
    name = "${scope.instanceName}-letsencrypt";
    namespace = clusterScoped;
    spec.acme = {
      server = "https://acme-v02.api.letsencrypt.org/directory";
      privateKeySecretRef.name = "${scope.instanceName}-acme-key";
      solvers = [{ http01.ingress.class = "nginx"; }];
    };
  };

  deployment = mkResource {
    apiVersion = "apps/v1"; kind = "Deployment";
    name = scope.instanceName;
    namespace = scope.namespace;
    spec.template.spec.containers = [{
      name = "app";
      image = config.image;
      volumeMounts = [{ name = "tls"; mountPath = "/etc/tls"; readOnly = true; }];
    }];
    spec.template.spec.volumes = [{
      name = "tls";
      secret.secretName = "${scope.instanceName}-tls-secret";
      # Note: the secret is created by cert-manager at runtime,
      # not by kixpkgs. No ${} tracking needed here.
    }];
  };

  service = mkResource {
    apiVersion = "v1"; kind = "Service";
    name = scope.instanceName;
    namespace = scope.namespace;
    spec.ports = [{ port = 443; targetPort = 8443; }];
  };

  ingress = mkResource {
    apiVersion = "networking.k8s.io/v1";
    kind = "Ingress";
    name = scope.instanceName;
    namespace = scope.namespace;
    metadata.annotations."cert-manager.io/cluster-issuer" = "${self.clusterIssuer}";
    spec.tls = [{
      hosts = config.domains or [ "${scope.instanceName}.example.com" ];
      secretName = "${scope.instanceName}-tls-secret";
    }];
    spec.rules = map (domain: {
      host = domain;
      http.paths = [{
        path = "/";
        pathType = "Prefix";
        backend.service = {
          name = "${self.service}";
          port.number = 443;
        };
      }];
    }) (config.domains or [ "${scope.instanceName}.example.com" ]);
  };

  main = withRequires [
    self.deployment
    self.certificate
    self.clusterIssuer
    self.ingress
  ] self.service;
}
```

### 6.3 Cluster-Level Wiring

```nix
# clusters/production.nix
{
  services.cert-manager = {
    package = "cert-manager";
    namespace = "cert-manager";
    version = "1.14.0";
  };

  services.my-web-app = {
    package = "my-web-app";
    namespace = "production";
    image = "myapp:v2.1.0";
    domains = [ "app.example.com" "www.example.com" ];
    # certManager auto-resolved (only one cert-manager in cluster)
  };

  services.other-app = {
    package = "other-web-app";
    namespace = "staging";
    image = "otherapp:v1.0.0";
    # certManager auto-resolved (same instance)
  };
}
```

### 6.4 Overriding the CRD Provider

To use a different cert-manager version for a specific app (while keeping the cluster-wide default):

This is **not possible** at the CRD level because CRDs are cluster-scoped. You cannot have two versions of `certificates.cert-manager.io`. The override must happen at the cluster level:

```nix
# Override cert-manager version for the whole cluster
services.cert-manager.version = "1.15.0";
```

However, you can override the cert-manager **package** (e.g., to add custom webhook config):

```nix
# Overlay on the outer fixpoint
overlays = [
  (self: super: {
    cert-manager = super.cert-manager.overrideParts (pSelf: pSuper: {
      webhook = mkResource {
        # Custom webhook configuration
        # All CRDs, type providers, controller carry over from pSuper
      };
    });
  })
];
```

The type providers remain valid because they reference `self.crds.certificate` and `self.controller` through the inner fixpoint. Overriding the webhook does not change the CRD or controller unless you explicitly override those too.

---

## 7. Resulting Closure and Deploy Order

### 7.1 Full Closure for `my-web-app`

```
my-web-app.main.closure:

  Service/my-web-app@production
  +-- requires -> Deployment/my-web-app@production
  +-- requires -> Ingress/my-web-app@production
  |               +-- dep (via ${}) -> Service/my-web-app@production  (self-ref, deduped)
  |               +-- dep (via ${}) -> ClusterIssuer/my-web-app-letsencrypt
  +-- requires -> Certificate/my-web-app-tls@production
  |               +-- requires -> CRD/certificates.cert-manager.io    (from type provider)
  |               +-- requires -> Deployment/cert-manager-controller@cert-manager  (from type provider)
  |               |               +-- requires -> CRD/certificates.cert-manager.io
  |               |               +-- requires -> CRD/issuers.cert-manager.io
  |               |               +-- requires -> CRD/clusterissuers.cert-manager.io
  |               |               +-- dep (via ${}) -> ServiceAccount/cert-manager@cert-manager
  |               |                                    +-- requires -> ClusterRoleBinding/cert-manager-controller
  |               |                                                    +-- dep -> ClusterRole/cert-manager-controller
  |               +-- dep (via ${}) -> ClusterIssuer/my-web-app-letsencrypt
  +-- requires -> ClusterIssuer/my-web-app-letsencrypt
                  +-- requires -> CRD/clusterissuers.cert-manager.io   (from type provider)
                  +-- requires -> Deployment/cert-manager-controller    (from type provider, same derivation)
```

### 7.2 Topological Deploy Order

```
 1. CRD/certificates.cert-manager.io          -- no deps
 2. CRD/issuers.cert-manager.io               -- no deps
 3. CRD/clusterissuers.cert-manager.io        -- no deps
 4. ClusterRole/cert-manager-controller        -- no deps
 5. Namespace/cert-manager                     -- no deps
 6. Namespace/production                       -- no deps
 7. ServiceAccount/cert-manager@cert-manager   -- deps on ns
 8. ClusterRoleBinding/cert-manager-controller -- deps on ClusterRole, SA
 9. Deployment/cert-manager-controller         -- requires CRDs, deps on SA
10. ClusterIssuer/my-web-app-letsencrypt       -- requires CRD + controller
11. Certificate/my-web-app-tls@production      -- requires CRD + controller, deps on ClusterIssuer
12. Deployment/my-web-app@production           -- deps on ns
13. Service/my-web-app@production              -- deps on ns
14. Ingress/my-web-app@production              -- deps on Service, ClusterIssuer
```

CRDs first, controller second, CRs third, application resources last. The ordering is correct and fully derived from the DAG.

---

## 8. Design Decisions and Rationale

### 8.1 Type Provider Belongs to the CRD-Installing Package

The type provider lives inside the cert-manager package, not in a separate library. Rationale:

- The type provider references `self.crds.certificate` and `self.controller` through the inner fixpoint. Moving it outside the package would require passing these explicitly.
- The type provider's `apiVersion` and `kind` come from the CRD definition. Keeping them together prevents version skew.
- Override mechanics work naturally: `overrideParts` on cert-manager can swap the controller, and all type providers automatically reference the new controller via `self`.

### 8.2 `requires` on the CR Points to Both CRD and Controller

Not just the CRD. The alternative -- requiring only the CRD and letting Kubernetes handle controller ordering -- would mean:

- The CR's closure would not include the controller. Deploying just the CR's closure would give you a CRD and a CR but no controller. The CR would never be reconciled.
- There would be no ordering guarantee between controller and CR. In practice this matters less (the CR is accepted regardless), but it is semantically wrong to say "the controller is not a dependency of the CR."

The controller IS a dependency of the CR. Including it in `requires` reflects reality.

### 8.3 CRD Collision Detection at Eval Time

The cluster evaluator should check for CRD name collisions. Two packages that both define `certificates.cert-manager.io` (e.g., because they bundle their own cert-manager CRDs) must be caught at eval time:

```nix
# In cluster evaluator
let
  allResources = collectAllResources cluster;
  crds = filter (r: r.kind == "CustomResourceDefinition") allResources;
  byName = groupBy (crd: crd.name) crds;
  collisions = filterAttrs (_: cs: length cs > 1) byName;
in
  if collisions != {}
  then throw "CRD collision: ${toJSON (mapAttrs (_: map (c: c.sourcePackage)) collisions)}"
  else /* proceed */;
```

The error message should indicate which packages are the source of the conflicting CRDs so the operator knows what to fix.

### 8.4 Type Providers Work with Auto-Resolution

The `certManager` argument in a consumer package resolves to the cert-manager instance via the DI system (doc 04). The resolved value is the full package, including `.types`. No special handling needed -- type providers are just attributes on the package.

For auto-install (doc 05), if a package needs `certManager` and none is declared, the system could auto-create a cert-manager instance with defaults. This is appropriate for dev environments but should be gated by the auto-install safety controls described in doc 05.

---

## 9. Open Questions

### 9.1 Should Type Providers Be the Only Way to Create CRs?

Current design: type providers are the **recommended** way, but raw `mkResource` with manual `requires` also works. This is the right trade-off -- advanced users and edge cases need the escape hatch.

A stricter alternative: validate at the cluster level that every CR has a matching CRD in its closure. This would catch the case where someone uses raw `mkResource` for a CR and forgets the `requires`:

```nix
# In cluster evaluator
let
  customResources = filter (r: r.apiVersion not in builtinAPIVersions) allResources;
  missingCRDs = filter (cr:
    let crdName = "${toLower cr.kind}s.${cr.apiGroup}";
    in !(any (crd: crd.name == crdName) cr.closure)
  ) customResources;
in
  if missingCRDs != []
  then warn "CRs without CRDs in closure: ${map (cr: cr.name) missingCRDs}"
  else /* proceed */;
```

This is a valuable safety check, but should be a warning, not an error -- there are legitimate cases where the CRD is installed out-of-band (e.g., by a cluster operator before kixpkgs runs).

### 9.2 Controller-Only vs Full-Package Requirements

The type provider currently requires `[ crd controller ]`. The controller's closure includes all CRDs, RBAC, etc. So transitively, the CR's closure includes everything the controller needs.

But what if the controller deployment does not explicitly list all CRDs in its `requires`? Then the CR only gets the specific CRD it needs, plus the controller, but not the other CRDs. Is this a problem?

For cert-manager specifically: the controller needs all CRDs to function (it watches multiple types). So the controller should require all CRDs. But for simpler operators with a single CRD, the controller might only need that one CRD. The type provider correctly handles both cases -- it requires the specific CRD for the CR, and the controller carries whatever other deps it needs.

### 9.3 Webhook Dependencies

cert-manager has a webhook that validates CRs. The webhook should be running before CRs are created. Currently, the type provider does not include the webhook in `requires`. Options:

1. **Webhook in controller's closure:** The controller `requires` the webhook. Then all CRs transitively get the webhook. This is correct if the webhook is tightly coupled to the controller.

2. **Webhook in type provider:** `mkTypeProvider { crd, controller, webhook }` adds the webhook to `requires`. More explicit but adds a parameter.

3. **Webhook as part of `main` only:** The webhook is only in the full package closure, not in individual CR closures. Risk: deploying just a CR's closure might miss the webhook.

Option 1 is simplest and correct for most CRD operators. The controller and webhook are usually deployed together. If they are not, option 2 gives explicit control.

### 9.4 Interaction with `overrideParts`

When you override a cert-manager resource:

```nix
myCertManager = certManager.overrideParts (pSelf: pSuper: {
  controller = mkResource {
    # Custom controller with different args
    requires = builtins.attrValues pSelf.crds;  # still references crds via fixpoint
  };
});
```

The type providers (`pSelf.types.*`) automatically pick up the new controller because they reference `self.controller` through the inner fixpoint. This is the key benefit of the fixpoint pattern -- overriding one piece re-wires everything consistently.

But if someone overrides a CRD:

```nix
myCertManager = certManager.overrideParts (pSelf: pSuper: {
  crds = pSuper.crds // {
    certificate = mkCRD {
      # Modified CRD spec (e.g., additional printer columns)
    };
  };
});
```

The type provider for certificates picks up the new CRD (via `self.crds.certificate`). The controller picks up all new CRDs (via `builtins.attrValues self.crds`). Everything re-wires. This is correct behavior.
