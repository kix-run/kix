# RBAC DSL Explained — annotated version of Luca's example (10A)

This is a heavily commented walkthrough of Luca's RBAC DSL example from 10A.
The original is preserved as-is in `10A_RBAC_Dsl_Example.md`.

## How to read this if you know K8s but not Nix

Before diving in, here's a Rosetta Stone for the Nix syntax you'll see:

| Nix syntax | What it means | Python equivalent |
|---|---|---|
| `let ... in ...` | Define local variables, then use them | Assigning variables before a `return` |
| `inherit (foo) a b c;` | Pull `a`, `b`, `c` out of `foo` into scope | `a, b, c = foo.a, foo.b, foo.c` |
| `{ key = value; }` | An attribute set (a dict) | `{"key": value}` |
| `[ a b c ]` | A list (NO commas between elements) | `[a, b, c]` |
| `x \|> f` | Pipe: pass `x` as argument to function `f` | `f(x)` — same as Unix `x \| f` |
| `f x` | Function application (no parens needed) | `f(x)` |
| `a // b` | Merge two dicts, `b` wins on conflict | `{**a, **b}` |

The pipe operator `|>` is the key to reading this whole file. When you see:
```
cm.issuers |> reconcile
```
Read it left-to-right: "take `cm.issuers` (a resource reference) and pipe it into `reconcile` (an intent function)."
The result is a K8s RBAC rule — the DSL expands it into the `apiGroups`/`resources`/`verbs` triple you're used to.

---

```nix
# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  RBAC DSL — Luca's proposal for how cert-manager RBAC *should* look      ║
# ║                                                                          ║
# ║  CONTEXT: The current cert-manager resources.nix has ~70 lines of raw    ║
# ║  RBAC rules that look like this:                                         ║
# ║                                                                          ║
# ║    { apiGroups = [ "cert-manager.io" ];                                  ║
# ║      resources = [ "issuers" "issuers/status" ];                         ║
# ║      verbs = [ "update" "patch" ]; }                                     ║
# ║    { apiGroups = [ "cert-manager.io" ];                                  ║
# ║      resources = [ "issuers" ];                                          ║
# ║      verbs = [ "get" "list" "watch" ]; }                                 ║
# ║                                                                          ║
# ║  That's just raw Kubernetes YAML wearing a Nix costume.                  ║
# ║  This DSL compresses the INTENT behind those rules into something        ║
# ║  readable and auditable. The DSL functions expand back into the same     ║
# ║  apiGroups/resources/verbs triples at evaluation time.                   ║
# ╚════════════════════════════════════════════════════════════════════════════╝

let
  # ──────────────────────────────────────────────────────────────────────────
  # STEP 1: Import the DSL vocabulary
  # ──────────────────────────────────────────────────────────────────────────
  #
  # `inherit (x) a b c;` is Nix for "pull names a, b, c out of attrset x
  # into the current scope." It's destructuring, like:
  #   group, core, grant, ... = dsl.group, dsl.core, dsl.grant, ...
  #
  # kixlib'.rbac.dsl is a (hypothetical) module that provides:
  #   - `group`      — constructor: takes an API group string, returns a
  #                     namespace object whose attributes are resource names
  #   - `core`       — pre-built group for the "" (core) API group, so you
  #                     can write `core.secrets` instead of `group("").secrets`
  #   - `grant`      — takes a list of rules, returns a role definition
  #   - `grantWith`  — like grant but also accepts extra metadata (labels, etc.)
  #   - intent functions (watch, reconcile, etc.) — each one is a function
  #                     that takes a resource reference and returns a K8s RBAC rule
  #
  inherit (kixlib'.rbac.dsl)
    group core grant grantWith

    # ── Intent functions ──────────────────────────────────────────────────
    #
    # Each intent is a FUNCTION that takes a resource reference (like
    # `cm.issuers`) and returns one or more K8s RBAC policy rules.
    #
    # Think of them as macros that expand to the verbs you'd write by hand.
    # The mapping to actual K8s verbs:
    #
    #   INTENT            K8s VERBS GENERATED                  WHEN TO USE
    #   ─────────────────────────────────────────────────────────────────────
    #   watch             get, list, watch                     Read-only observation.
    #                                                          "I need to see these
    #                                                          resources but never
    #                                                          touch them."
    #
    #   reconcile         get, list, watch,                    The standard controller
    #                     update, patch (on /status),          pattern: watch a resource,
    #                     update (on /finalizers)              write its status, manage
    #                                                          its finalizers. This is the
    #                                                          bread and butter of any K8s
    #                                                          operator.
    #
    #   own               get, list, watch,                    For child/owned resources.
    #                     create, delete                       The controller creates and
    #                                                          deletes them but doesn't
    #                                                          update in place. Think:
    #                                                          "I spawn Pods, I delete Pods,
    #                                                          but I never patch Pods."
    #
    #   readWrite         get, list, watch,                    Full lifecycle management
    #                     create, update, delete               without patch. Used when the
    #                                                          controller does complete
    #                                                          replacement (update) rather
    #                                                          than strategic merge (patch).
    #
    #   full              get, list, watch,                    Unrestricted mutation.
    #                     create, update, delete, patch        Used sparingly — e.g., for
    #                                                          Secrets where the controller
    #                                                          both creates and patches.
    #
    #   watchAndFinalize  get, list, watch,                    Observe + set finalizers.
    #                     update (on /finalizers)              For resources the controller
    #                                                          doesn't own but needs to
    #                                                          clean up after. E.g., the
    #                                                          ingress-shim watches Ingresses
    #                                                          (doesn't own them) but adds
    #                                                          a finalizer so it can clean
    #                                                          up Certificates when an
    #                                                          Ingress is deleted.
    #
    #   emit              create, patch                        For the Events resource only.
    #                                                          K8s events are append-only
    #                                                          (create) with dedup (patch).
    #
    #   allow [verbs]     (exactly what you pass)              Escape hatch for anything
    #                                                          that doesn't fit the above
    #                                                          intents. You provide raw
    #                                                          K8s verbs explicitly.
    #
    #   restrictTo [names]  (adds resourceNames field)         Scope a rule to specific
    #                                                          named resources. Used with
    #                                                          `allow` for things like
    #                                                          signing only specific issuers.
    #
    watch reconcile own readWrite full
    watchAndFinalize emit allow restrictTo;

  # ──────────────────────────────────────────────────────────────────────────
  # STEP 2: Define API group aliases
  # ──────────────────────────────────────────────────────────────────────────
  #
  # In raw K8s RBAC, you write apiGroups as strings everywhere:
  #   { apiGroups = [ "cert-manager.io" ]; resources = [ "issuers" ]; ... }
  #
  # `group` is a constructor function. It takes an API group string and
  # returns an object where you access resources as attributes:
  #
  #   cm = group "cert-manager.io";
  #   cm.issuers       → { apiGroup = "cert-manager.io"; resource = "issuers"; }
  #   cm.certificates  → { apiGroup = "cert-manager.io"; resource = "certificates"; }
  #
  # This means typos become Nix evaluation errors instead of silent RBAC
  # misconfigurations. "cert-manger.io" would be caught; in raw YAML it
  # would just silently grant nothing.
  #
  # `core` is pre-defined (imported above) for the "" API group — that's
  # the K8s core group where Secrets, Pods, Services, Events etc. live.
  # So `core.secrets` means { apiGroup = ""; resource = "secrets"; }.
  #
  cm    = group "cert-manager.io";           # cert-manager CRDs
  acme  = group "acme.cert-manager.io";      # ACME-specific CRDs (orders, challenges)
  gw    = group "gateway.networking.k8s.io"; # Gateway API resources
  net   = group "networking.k8s.io";         # Ingress, NetworkPolicy, etc.
  certs = group "certificates.k8s.io";       # K8s-native CSR signing API
  authz = group "authorization.k8s.io";      # SubjectAccessReview etc.
  ocp   = group "route.openshift.io";        # OpenShift Routes

# ════════════════════════════════════════════════════════════════════════════
# STEP 3: Define the roles
# ════════════════════════════════════════════════════════════════════════════
#
# `in` ends the `let` block. Everything after `in` is the expression that
# uses all those local variables. Here, the entire expression is a call to
# `mkRoleSet { ... }`.
#
# mkRoleSet already exists in kixlib (Phase 7). It takes:
#   - subjects: who gets bound to these roles (a ServiceAccount, Group, etc.)
#   - roles: an attrset where each key is a ClusterRole name and each value
#            is the role definition (currently raw rules; DSL would change
#            that to `grant [ ... ]`)
#
# mkRoleSet then generates BOTH the ClusterRole AND its ClusterRoleBinding
# for each entry — that's the boilerplate it already eliminates today.
# The DSL adds the SECOND layer: compressing the rules themselves.
#
in mkRoleSet {
  # `controllerSubjects` is defined elsewhere — it's the ServiceAccount
  # that all these roles bind to:
  #   kixlib.rbac.subjects.sa { name = "cert-manager"; namespace = cfg.namespace; }
  # which expands to:
  #   [{ kind = "ServiceAccount"; name = "cert-manager"; namespace = "cert-manager"; }]
  subjects = controllerSubjects;

  roles = {

    # ── Issuer controllers ──────────────────────────────────────────
    #
    # Each key ("cert-manager-controller-issuers") becomes the name of a
    # ClusterRole in Kubernetes. The value is `grant [ ... ]` which takes
    # a list of DSL rules and produces { rules = [ ... ]; } — the same
    # format mkRoleSet already expects, but expanded from intent notation.

    "cert-manager-controller-issuers" = grant [
      # ┌─────────────┐     ┌───────────┐
      # │ RESOURCE REF │ |>  │  INTENT   │
      # └─────────────┘     └───────────┘
      #
      # cm.issuers |> reconcile
      #
      # Reading left to right:
      #   1. cm.issuers    = { apiGroup = "cert-manager.io", resource = "issuers" }
      #   2. |> reconcile  = pipe that into the reconcile function
      #   3. reconcile expands it to MULTIPLE K8s rules:
      #        { apiGroups = ["cert-manager.io"]; resources = ["issuers"];
      #          verbs = ["get" "list" "watch"]; }
      #        { apiGroups = ["cert-manager.io"]; resources = ["issuers/status"];
      #          verbs = ["update" "patch"]; }
      #        { apiGroups = ["cert-manager.io"]; resources = ["issuers/finalizers"];
      #          verbs = ["update"]; }
      #
      # Compare that to the CURRENT code which spells all of this out by hand.
      # The DSL encodes the PATTERN ("this controller reconciles issuers")
      # instead of the MECHANISM ("get, list, watch issuers; update, patch
      # issuers/status; update issuers/finalizers").
      #
      cm.issuers   |> reconcile
      core.secrets |> readWrite     # create/read/update/delete Secrets (ACME keys etc.)
      core.events  |> emit          # create + patch Events (the standard controller event pattern)
    ];

    "cert-manager-controller-clusterissuers" = grant [
      # Same pattern as issuers but for the cluster-scoped variant.
      # In K8s, Issuers are namespaced; ClusterIssuers are cluster-wide.
      # The RBAC rules are structurally identical — only the resource name differs.
      cm.clusterissuers |> reconcile
      core.secrets      |> readWrite
      core.events       |> emit
    ];

    # ── Certificate lifecycle ───────────────────────────────────────

    "cert-manager-controller-certificates" = grant [
      cm.certificates        |> reconcile       # watch certs, update status, manage finalizers
      cm.certificaterequests |> reconcile       # same for CSRs
      cm.clusterissuers      |> watch           # look up issuer config (read-only)
      cm.issuers             |> watch           # (both namespaced and cluster-scoped)
      acme.orders            |> own             # create/delete ACME orders as children
                                                # (own = watch + create + delete, no update)
      core.secrets           |> full            # store issued certs + read CA bundles
                                                # (full = readWrite + patch — needs patch
                                                #  because cert-manager patches Secret data)
      core.events            |> emit
    ];

    # ── ACME flow ───────────────────────────────────────────────────
    #
    # ACME (Let's Encrypt) has a multi-step flow:
    #   Order → Challenge → Solver (HTTP01 pod/ingress or DNS01)
    # Each step has its own controller with its own RBAC role.

    "cert-manager-controller-orders" = grant [
      acme.orders       |> reconcile            # drive order state machine
      acme.challenges   |> own                  # spawn challenges for each order
      cm.clusterissuers |> watch                # resolve issuer references
      cm.issuers        |> watch
      core.secrets      |> watch                # read ACME account keys
      core.events       |> emit
    ];

    "cert-manager-controller-challenges" = grant [
      acme.challenges        |> reconcile       # drive challenge solvers
      cm.issuers             |> watch           # look up solver config
      cm.clusterissuers      |> watch
      core.secrets           |> watch           # read solver credentials
      core.events            |> emit
      core.pods              |> own             # spin up HTTP01 solver pods
      core.services          |> own             # expose solver pods via Services
      net.ingresses          |> readWrite       # create/update solver ingresses
      gw.httproutes          |> readWrite       # or gateway API equivalents

      # ┌──────────────────────────────────────────────────────────────────┐
      # │ ESCAPE HATCH: `allow`                                           │
      # │                                                                 │
      # │ When none of the named intents fit, `allow` lets you specify    │
      # │ raw K8s verbs explicitly. This is intentionally ugly — it       │
      # │ stands out in review as "something unusual is happening here."  │
      # │                                                                 │
      # │ Here: OpenShift routes need only "create", which doesn't map    │
      # │ to any standard intent.                                         │
      # │                                                                 │
      # │ Also note `ocp."routes/custom-host"` — the quotes let you use  │
      # │ a subresource path as an attribute name. In Nix, attribute      │
      # │ names with special characters (like /) need to be quoted.       │
      # └──────────────────────────────────────────────────────────────────┘
      ocp."routes/custom-host" |> allow [ "create" ]
    ];

    # ── Ingress/Gateway shim ────────────────────────────────────────
    #
    # The ingress-shim watches Ingresses/Gateways for cert-manager
    # annotations and automatically creates Certificate resources.

    "cert-manager-controller-ingress-shim" = grant [
      cm.certificates        |> readWrite       # create certs for annotated ingresses
      cm.certificaterequests |> readWrite
      cm.issuers             |> watch           # resolve issuer annotations
      cm.clusterissuers      |> watch

      # watchAndFinalize = watch + update /finalizers
      # The shim doesn't OWN ingresses (it didn't create them), but it
      # needs to add a finalizer so it can clean up the Certificate
      # resource when the Ingress is deleted. This is a distinct intent
      # from `reconcile` (which also manages /status).
      net.ingresses          |> watchAndFinalize
      gw.gateways            |> watchAndFinalize
      gw.httproutes          |> watchAndFinalize
      core.events            |> emit
    ];

    # ── Signer permissions ──────────────────────────────────────────
    #
    # These two roles use `grantWith` instead of `grant`.
    # grantWith is like grant but also accepts an attrset of extra metadata
    # (labels, annotations, etc.) that gets merged into the ClusterRole.
    #
    # The `//` operator merges two attrsets (right side wins on conflicts):
    #   controllerLabels.all // { "app.kubernetes.io/component" = "cert-manager"; }
    # is like:
    #   {**controllerLabels_all, "app.kubernetes.io/component": "cert-manager"}

    "cert-manager-controller-approve:cert-manager-io" = grantWith {
      labels = controllerLabels.all // { "app.kubernetes.io/component" = "cert-manager"; };
    } [
      # ┌──────────────────────────────────────────────────────────────────┐
      # │ CHAINING: restrictTo |> allow                                   │
      # │                                                                 │
      # │ Pipes can chain. Reading left to right:                         │
      # │   1. cm.signers           — the "signers" resource in the       │
      # │                             cert-manager.io API group           │
      # │   2. |> restrictTo [...]  — scope to specific resourceNames     │
      # │                             (only these issuer patterns)        │
      # │   3. |> allow ["approve"] — grant only the "approve" verb       │
      # │                                                                 │
      # │ This produces:                                                  │
      # │   { apiGroups = ["cert-manager.io"];                            │
      # │     resources = ["signers"];                                    │
      # │     resourceNames = ["issuers.cert-manager.io/*"                │
      # │                      "clusterissuers.cert-manager.io/*"];       │
      # │     verbs = ["approve"]; }                                      │
      # │                                                                 │
      # │ In K8s terms: "allow this SA to approve signing requests, but   │
      # │ ONLY for cert-manager issuers — not arbitrary signers."         │
      # └──────────────────────────────────────────────────────────────────┘
      cm.signers
        |> restrictTo [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]
        |> allow [ "approve" ]
    ];

    "cert-manager-controller-certificatesigningrequests" = grantWith {
      labels = controllerLabels.all // { "app.kubernetes.io/component" = "cert-manager"; };
    } [
      # Same resource can appear multiple times with different intents.
      # This is valid — K8s RBAC rules are additive (union of permissions).
      # Splitting them makes the REASON for each permission clear:
      #   - watch: so the controller can observe CSRs
      #   - allow ["update"]: so it can approve/deny them (separate from watching)
      certs.certificatesigningrequests          |> watch
      certs.certificatesigningrequests          |> allow [ "update" ]

      # Subresource access: "certificatesigningrequests/status"
      # In Nix, attribute names with / need quotes.
      certs."certificatesigningrequests/status" |> allow [ "update" "patch" ]

      # Scoped signing permission — same pattern as the approve role above.
      certs.signers
        |> restrictTo [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]
        |> allow [ "sign" ]

      # SubjectAccessReview — the controller checks if the requesting user
      # is authorized to use a particular signer.
      authz.subjectaccessreviews |> allow [ "create" ]
    ];

  };
}
```

## What just happened?

If you read through that and it made sense, you now understand the core idea:
**replace mechanical verb lists with semantic intent labels**.

The DSL doesn't change what RBAC rules get created — the Kubernetes output is
identical. It changes how you *think about* and *review* RBAC:

| You write | DSL expands to (what K8s sees) |
|---|---|
| `cm.issuers \|> reconcile` | 3 rules: watch the resource + patch status + manage finalizers |
| `core.secrets \|> full` | 1 rule: all CRUD verbs including patch |
| `core.events \|> emit` | 1 rule: create + patch |
| `cm.signers \|> restrictTo [...] \|> allow ["approve"]` | 1 rule: approve verb, scoped to named resources |

The security benefit: in a code review, you scan for `full` (overprivileged?)
and `allow` (escape hatch — why?). The intent names make audit tractable.

For reference, the current implementation lives in `pkgs/cert-manager/resources.nix`
lines 136-208 — compare the raw rules there to this version.
