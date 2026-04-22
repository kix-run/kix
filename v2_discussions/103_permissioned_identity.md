# 103 — Permissioned Identity (RBAC Trio Abstraction)

**Status:** Brainstorm (2026-04-15).
**Related:** `100_package_dsl_ergonomics_survey.md` (item B1, source),
`35_crd_derived_rbac_webhooks.md`, `kix/lib/rbac.nix` (pipe DSL for rules),
`kix/lib/netpol.nix` (`processInstance` — SA→workload edge walk).

## Problem

Every package that runs a workload ships the same three-resource trio:

1. A `ServiceAccount`.
2. A `Role` or `ClusterRole` granting permissions.
3. A `RoleBinding` or `ClusterRoleBinding` attaching (1) to (2).

The shape is fixed and the subjects/roleRef boilerplate is identical
across packages:

```nix
subjects = [{
  kind      = "ServiceAccount";
  name      = self.sa.out.name;
  namespace = scope.namespaceName;
}];
roleRef = {
  kind     = "ClusterRole";
  name     = self.role.out.name;
  apiGroup = "rbac.authorization.k8s.io";
};
```

Sources: `ingress-nginx:365-373,219-306`, `velero:239-304`,
`stackgres-operator:334-582`, every package with a workload.

Separately, every workload that uses a non-default SA threads the SA name
into `spec.template.spec.serviceAccountName` manually, and the netpol
SA-walk (`netpol.nix:processInstance`) depends on an implicit edge
between the SA resource and the consuming workload.

## Personas

- **Package author writing a new operator.** Today: copy the trio from
  another package, rename, edit rules. Wants: write permissions once,
  attach to a workload, move on.
- **Package author adding a second binding** (e.g. aggregated role,
  leader-election Role in a sibling namespace). Today: hand-write a
  second `RoleBinding` with the same subjects block. Wants: the extra
  binding to be cheap without forcing the primary identity to be
  decomposed.
- **Reader auditing RBAC in a package.** Today: scan three resources,
  match subjects to SA to verify the wiring. Wants: a single place that
  says "this workload runs as this identity with these permissions."
- **kix/lib author extending RBAC tooling** (netpol SA-walk, scorecard
  rules, diagnostics). Today: re-derives the SA→workload edge from
  `serviceAccountName` strings. Wants: a first-class identity object to
  hang metadata on.

## Design constraints (from session notes)

1. **Don't re-engineer K8s.** If a concept already exists at K8s level
   with well-understood semantics, a kix abstraction must add clear
   value — not force readers to unpack it back into the underlying
   resources to reason about behavior.
2. **Abstractions earn their weight on the consume side.** Declaration
   ergonomics alone rarely justify a new concept; consumption ergonomics
   (one object passed around, one place to attach metadata) can.
3. **Don't hide multi-role complexity.** Operators genuinely bind SAs
   to multiple roles (primary + aggregated + leader-election). The
   abstraction must degrade gracefully — extra bindings stay cheap and
   visible, not forced through a composite.

## Direction A — Status quo (three resources, no abstraction)

### Before / After (same)

```nix
# velero-style package today
sa = scope.mkServiceAccount { name = "velero"; };

role = scope.mkClusterRole {
  name  = "velero";
  rules = rbac.pipe [ (rbac.watch [ "pods" "nodes" ]) (rbac.reconcile [ "backups" ]) ];
};

binding = scope.mkClusterRoleBinding {
  name     = "velero";
  roleRef  = { kind = "ClusterRole"; name = self.role.out.name; apiGroup = "rbac.authorization.k8s.io"; };
  subjects = [{ kind = "ServiceAccount"; name = self.sa.out.name; namespace = scope.namespaceName; }];
};

deployment = scope.mkDeployment {
  spec.template.spec.serviceAccountName = self.sa.out.name;
  # …
};
```

### Trade-offs

- ✔ Zero new concepts. Every K8s user recognizes it.
- ✔ Multi-binding is just another `mkClusterRoleBinding` call.
- ✘ The subjects / roleRef block is pure ceremony, repeated in every
  package with a workload.
- ✘ The SA → workload relationship is a string match
  (`serviceAccountName = self.sa.out.name`). netpol's SA-walk is
  correct today because the resource-graph edge flows through Nix store
  context, but it's not *explicit* — a future refactor could break it
  silently.
- ✘ No single object for kix/lib to hang identity-level metadata on
  (e.g. "this identity is privileged, surface it in the scorecard").

## Direction B — Thin `scope.mkBinding` helper only

Keep the trio visible. Collapse only the subjects/roleRef ceremony. No
composite object, no `mountOn`.

### Before

(same as Direction A)

### After

```nix
sa   = scope.mkServiceAccount { name = "velero"; };
role = scope.mkClusterRole    { name = "velero"; rules = rbac.pipe [ /* … */ ]; };

binding = scope.mkBinding {
  sa   = self.sa;       # defaults subjects from sa.out.name + scope.namespaceName
  role = self.role;     # defaults roleRef kind/name/apiGroup from role.kind + role.out.name
};

# multi-binding stays trivial
leaderElection = scope.mkBinding {
  sa   = self.sa;
  role = scope.mkRole { name = "velero-leader"; rules = [ /* … */ ]; };
};

aggregated = scope.mkBinding {
  sa      = self.sa;
  roleRef = { kind = "ClusterRole"; name = "system:aggregated-metrics-reader"; };
};

deployment = scope.mkDeployment {
  spec.template.spec.serviceAccountName = self.sa.out.name;
  # …
};
```

### Trade-offs

- ✔ Removes the worst boilerplate (subjects/roleRef blocks).
- ✔ Stays inside K8s vocabulary — reader sees SA, Role, Binding.
- ✔ Multi-binding is uniformly cheap (just more `mkBinding` calls).
- ✔ `RoleBinding` vs `ClusterRoleBinding` can auto-select based on
  whether `role` is a `Role` or `ClusterRole`, or an explicit arg.
- ✘ Does not help the consume side. Workload still references
  `self.sa.out.name` manually, netpol SA-walk stays implicit, no
  place to hang identity-level metadata.
- ✘ Does not capture "this SA is the identity for this workload" —
  that coupling remains a convention.

Cost: ~20 lines in `eval/scope.nix`, no new `_type`, no traversal
changes.

## Direction C — `scope.mkIdentity` composite with `mountOn`

The identity is a single consumable thing. The trio is its
implementation detail. Multi-binding uses Direction B's `mkBinding` as
an escape hatch; `mkIdentity` handles only the primary identity +
default permissions.

### Before

(same as Direction A)

### After

```nix
identity = scope.mkIdentity {
  name          = "velero";
  clusterScoped = true;
  rules         = rbac.pipe [ (rbac.watch [ "pods" "nodes" ]) (rbac.reconcile [ "backups" ]) ];
};

# workload consumes identity as one thing
deployment = scope.mkDeployment {
  # …
} |> self.identity.out.mountOn;

# multi-binding: plain mkBinding (from Direction B), attaches to the same identity
leaderElection = scope.mkBinding {
  identity = self.identity;  # accepts an identity *or* a bare SA
  role     = scope.mkRole { rules = [ /* … */ ]; };
};
```

### What `mkIdentity` returns

A resource-group: `_type = "k8s-resource-group"` containing the SA,
optional inline Role/ClusterRole, optional inline Binding. Expanded by
`collectTypedAttrs` (`eval/helpers.nix`) — single new case, same
descent pattern as ordinary resources.

`out` surface:

```nix
{
  saRef    = { name; namespace; };   # stable consume handle
  mountOn  = workload: <mutator>;    # sets serviceAccountName + registers edge
  name     = "<identity name>";      # for binding references
  out.sa   = <sa resource>;          # escape hatch for edge cases
  out.role = <role resource or null>;
}
```

`mountOn` does three things:

1. Sets `spec.template.spec.serviceAccountName = saRef.name`.
2. Asserts the workload is in the same namespace as the SA (explicit
   error if not — crossing namespaces requires the author to drop down
   to `mkBinding` with `sa` pointing across namespaces).
3. Registers the SA → workload edge via Nix store context, so
   `netpol.nix:processInstance`'s SA-walk resolves without relying on
   string matching.

### Degenerate cases

- **SA with no inline rules** (pure aggregation target):
  `mkIdentity { name = "foo"; rules = null; }` — emits only the SA and
  returns the same `out` shape. Bindings are attached via `mkBinding`.
- **Workload that uses the default SA** — doesn't call `mountOn`, no
  identity object needed, no behavior change.
- **Identity consumed by multiple workloads** — each workload pipes
  through `self.identity.out.mountOn` independently. Both edges are
  registered.

### Trade-offs

- ✔ Consume-side is one object: `self.identity.out.mountOn`. That's
  the main ergonomic win.
- ✔ SA → workload edge is explicit, not string-derived. kix/lib can
  evolve its RBAC tooling against a typed handle.
- ✔ Single object to hang metadata on (scorecard rules: "identity X is
  cluster-scoped and mounts 3 workloads — is that intended?").
- ✔ Multi-binding story is unchanged from Direction B —
  `scope.mkBinding { identity = ...; role = ...; }` stays the escape
  hatch.
- ✘ New concept to learn. Reader must know `mkIdentity` expands to
  SA+Role+Binding to fully audit RBAC.
- ✘ Resource-group extension in `collectTypedAttrs` is a small but real
  structural change; not free.
- ✘ `mountOn` is a workload mutator (a function on `out`). That's a new
  kind of `out` value in kix — today `out` is mostly passive data plus
  a few derived properties (`selector`, `fqdn`). Needs a precedent
  check.

### Implementation cost

- `eval/scope.nix`: new `mkIdentity` function (~60 lines).
- `eval/helpers.nix`: extend `collectTypedAttrs` to descend into
  `k8s-resource-group` (~10 lines).
- `eval/scope.nix`: `mkBinding` (~20 lines, shared with Direction B).
- Documentation + migration examples.

Total: ~100 lines + docs, no changes to the netpol SA-walk (it keeps
working because the edge is still there — it just becomes explicit
instead of string-derived).

## Decision

**Adopt Direction C, with Direction B's `mkBinding` included as the
multi-binding escape hatch.** Direction A is rejected; Direction B
alone is insufficient.

### Reasoning

1. **Consume-side ergonomics justify the new concept.** Direction B
   reduces declaration noise but leaves the workload → SA wiring as a
   string match. Direction C's `mountOn` turns that into a typed
   reference, which is the kind of structural guarantee kix should be
   providing (per CLAUDE.md DSL principles: "automation over brevity",
   "resources are rich objects").
2. **Netpol SA-walk becomes explicit.** Today the edge exists by
   accident of Nix store context flow. Making it explicit protects
   against future refactors silently breaking netpol.
3. **Multi-binding is not hidden.** `mkBinding` stays a first-class
   primitive usable with either an identity or a bare SA. Readers
   auditing "what does this SA have access to" follow the `mkBinding`
   calls in the package — same as K8s.
4. **Identity-level metadata has a home.** Scorecard rules,
   diagnostics, and future tooling (e.g. "privileged identity warning")
   get a single object to key off, without a parallel registry.
5. **The abstraction matches a real K8s gap.** K8s has no concept of
   "permissioned identity bound to a workload" — it's assembled from
   three resources every time. This is a case where K8s shape is
   historical decomposition, not a user-facing primitive. kix earning
   its keep here is legitimate.

### Not decided

- Whether `mountOn` as a workload-mutator function on `out` needs a
  precedent check — today `out` is mostly data. A 30-line prototype
  against velero would answer this before full commit.
- Default naming: if `name` is omitted, should `mkIdentity` pull from
  the instance name? Probably yes, matching other `mk*` helpers.
- Interaction with doc 35 (CRD-derived RBAC). `mkIdentity.rules` being
  auto-populated from CRD metadata is the natural extension; doc 35
  keeps `mkIdentity` as its target.

## Next step

Prototype `mkIdentity` + `mkBinding` against velero, measure the
`out.mountOn` pattern in practice, confirm the netpol SA-walk resolves
cleanly via the explicit edge. If the prototype holds, graduate to an
RFC and migrate the three worst offenders (velero, stackgres-operator,
cert-manager) as the landing PR.

## Open questions

1. Should `mountOn` also set `automountServiceAccountToken`? Some
   operators explicitly disable it for non-API-consuming workloads.
   Probably an opt-in arg on `mkIdentity`.
2. Cross-namespace bindings: `mkBinding { identity; role; namespace ? }`
   — does the user specify target namespace, or does it come from
   `role.namespace`? Latter is cleaner but assumes role is kix-managed.
3. Image-pull secrets are attached via the SA today. Should
   `mkIdentity` take an `imagePullSecrets` arg and wire them through,
   or stay out of it?
4. How does this interact with passthrough instances (doc 65) that
   re-export an identity from a sub-package?
