# 144: In-application resources, compiled through terranix

**Status:** Draft
**Related:** `64_init_and_ci_concerns.md` (§4, the Terraform output bridge), `73_workloads_jobs_and_ad_hoc_compute.md`, `97_service_contract_primitives.md` (the hash-named Job precedent), `117_self_service_platform_interface.md` (§5, day-2 read-back), `129a_grounding_field_and_prior_art.md` (open question 3), `139_external_inputs_and_resolutions.md` (§4 no pluggable resolvers, §7 side-effecting resolutions), `ROADMAP.md` items "Non-K8s side effects" and "Terraform coexistence"

---

## 1. Problem

Some of what a package needs to set up lives inside the application, not in
the Kubernetes API. Harbor projects, users, robot accounts, retention and
replication policies. Forgejo organisations and users. Grafana organisations
and service accounts. Keycloak realms. Every one of these is reachable only
through the application's own API, after the application is healthy.

Kix has two ways of doing this today, and both are the right answer for the
case they were built for:

- `kix/packages/stackgres-database` runs an idempotent bootstrap Job that
  creates a role and a database inside Postgres. The Job name carries a hash
  of its inputs, so a changed input is a new Job and the old one is reaped by
  TTL (`default.nix:196-206`, `:349`). This is create-only. It cannot delete,
  cannot see drift, and its diff in a pull request is "the script changed".
- `kix/packages/grafana` provisions dashboards and datasources through the
  k8s-sidecar, so the in-app resource is a ConfigMap. This is the ideal case
  and it only exists because Grafana offers a manifest-shaped interface.

Harbor offers neither. The question is what a package author writes for the
Harbor case, and the answer should be the same thing for Forgejo, Grafana
organisations and Keycloak.

The roadmap has carried this since early on. `ROADMAP.md` lists "Non-K8s side
effects (e.g. Forgejo user creation), start with execution on ssh, later
crossplane or provider plugins" and, under Terraform coexistence, "a
connector/provider abstraction that can wrap Terraform providers, Crossplane
XRDs, or raw API calls at compile time". Doc 129a open question 3 asks whether
the Terraform relationship stays read-only or whether Kix eventually emits
demands. Doc 139 §7 notes that a resolution with a side effect "may not belong
in the same verb, or in Kix at all". None of these were argued through. This
doc argues one direction through.

## 2. Options

| | Bootstrap Job per package | Operator with CRDs | Terranix, compiled, applied by a Job |
|---|---|---|---|
| New machinery | none | a controller per application, or Crossplane | one image, one helper, one renderer change |
| Delete and drift | author writes it, usually not | yes | yes, from the provider |
| Preview | script diff | manifest diff, no plan | intent diff at eval, plan at deploy |
| Fits the wave model | yes | yes | yes |
| Fits "pure configuration operators get absorbed by evaluation" (`ROADMAP.md` Ecosystem) | yes | no | yes |
| Covers Forgejo, Grafana, Keycloak, MinIO, Vault with the same code | no | only where an operator exists | yes, nixpkgs packages all of these providers |

The operator route is the most Kubernetes-shaped, and it is what the
harbor-operator day-2 CRDs and Crossplane's terraform provider offer. It fails
the roadmap's own test: it adds a runtime reconciler for what is pure
configuration, and doc 129a's loudest criticism of Crossplane is exactly the
missing plan phase.

The bootstrap Job stays right for one-off seeding of a single row. It is
wrong as soon as the set of things is managed over time, which projects and
users are.

**Verdict: the third column.** The rest of this doc is its design.

## 3. Design

### 3.1 The package surface is module options, as always

```nix
# clusters/acme.nix
instances.harbor.harbor.config.projects = {
  team-a = { public = false; storageQuotaGb = 200; };
  library = { public = true; };
};
```

The package declares `projects`, `robotAccounts`, `retentionPolicies` as
ordinary `lib.mkOption` entries, so schema export (doc 117 §3.1), the
scorecard and the eval-time checks see them like any other option. Nothing
about the OpenTofu step leaks into the option types.

### 3.2 Compile: options to a terranix module to JSON, at eval

The package maps its options onto a terranix module and evaluates it with
terranix's module system. Terranix exposes the evaluated configuration as an
attrset, so the package gets `config.tf.json` content as a Nix value with
`builtins.toJSON` and no import-from-derivation. Provider address and
credentials come from the same facts every other consumer uses:

```nix
provider.harbor = {
  url = self.out.coreUrl;            # carries the Service fact: netpol edge, ordering
  username = "admin";
  password = "$${HARBOR_ADMIN_PASSWORD}";   # env var, sourced from self.credentials
};
```

The JSON lands in a ConfigMap. **One ConfigMap key per resource address**
(`harbor_project.team-a`, `harbor_robot_account.ci`), not one `config.tf.json`
blob. That is the whole trick behind §3.5: the existing diff already renders
ConfigMap keys, so a removed project shows as a removed key with its address
in the name. A single `_provider` key carries the provider and backend blocks.
The Job concatenates the keys back into a directory of `*.tf.json` files,
which OpenTofu reads natively.

### 3.3 Apply: a hash-named Job, in the wave after the application

Same shape as `stackgres-database`:

- Name `<instance>-tofu-<hash of the ConfigMap content>`. A change is a new
  Job; an unchanged intent is skipped by the identity-hash check like any
  other resource. `ttlSecondsAfterFinished` long enough for the log to be
  read, never zero (`housekeeping/2026-09-19-job-ttl-zero-fails-readiness.md`).
- `requires` on the application's root, so it runs after Harbor is healthy.
  The Service fact in the provider URL gives the netpol egress edge to Harbor
  and the DNS dependency. The Job also needs the `apiserver` egress intent for
  the state backend.
- Credentials via `self.credentials.out.mkEnv`, never in the ConfigMap.
- State in OpenTofu's `kubernetes` backend, which stores it in a Secret in the
  Job's namespace. The package emits a ServiceAccount, a Role on `secrets`
  and `leases` in that namespace, and the binding. Kix does not author the
  state Secret and it carries no Kix label, so `kix gc` never sweeps it
  (`fetch.rs` selects candidates by the managed-by label).
- The container runs `tofu init -input=false` against a vendored plugin
  directory, then `tofu plan -detailed-exitcode -out plan`, then the refusal
  check in §3.5, then `tofu apply plan`.

The image is Nix-built: OpenTofu plus the provider from
`nixpkgs#terraform-providers.<name>` with `plugin_cache_dir` pointed at the
vendored copy and `-plugin-dir` set. No network access during `init`, which
matters twice: default-deny egress would block a download, and a download is
a resolution in doc 139's sense, which does not belong inside a deploy.

### 3.4 One helper, many applications

The Harbor-specific part is the option-to-terranix mapping and the provider
block. Everything in §3.3 is generic, so it lives once in the lib as a
builder, working name `scope.mkTofuJob`:

```nix
scope.mkTofuJob {
  name = "${name}-projects";
  provider = { harbor = { ... }; };
  resources = terranixConfig.resource;     # the attrset from §3.2
  env = self.credentials.out.mkEnv { HARBOR_ADMIN_PASSWORD = "adminPassword"; };
  requires = [ self.coreDeployment ];
  onDestroy = "refuse";                    # §3.5; cluster default, per-instance override
  allowDestroy = [ ];                      # §3.5; per-address exception
}
```

It returns the ConfigMap, the Job, the RBAC triple and the netpol intents as
parts, the way `kix.expose` returns its Ingress and Certificate. Forgejo,
Grafana organisations and Keycloak then cost a mapping each.

### 3.5 Three layers of diff, each doing only what it can honestly do

Kix already draws one line for Kubernetes resources: `kix diff` compares the
build against the kix-owned view of each live object, deploy verbs come from
the apiserver's server-side-apply dry run, and drift is a runtime check that
needs a cluster. The plan step draws the same line for Harbor.

**Eval time: the intent diff.** The ConfigMap is an ordinary resource in the
activation, so both diff paths cover it with no new storage: `kix diff`
against the live ConfigMap, and deploy against the previous activation. With
one key per resource address, a reviewer sees "harbor_project.team-a
removed" in the pull request. One renderer change makes it read well: a
`kix.run/tofu-config` annotation on the ConfigMap tells `plan.rs` to list the
keys as resource rows under the package instead of as a data blob. This diff
is pure, needs no Harbor, and answers everything a person chose.

**Deploy time: the plan.** Three facts are unknowable at eval, and all three
are things outside the repository: whether an attribute change is a
replacement (renaming a project is destroy plus create, and the destroy takes
the images), whether somebody changed Harbor by hand, and what computed values
the provider fills in. The Job's plan answers them. It writes the plan
summary, `3 to add, 1 to change, 0 to destroy` plus each replacement, to
`/dev/termination-log`, which the kubelet copies into the pod's terminated
state regardless of exit code. Today `readiness.rs:971` surfaces that message
only on failure. The change is to surface it on success as well, as the Job's
ready line in the deploy log, and to record it in the activation receipt
(doc 139 §3).

**A refusal for what the intent diff cannot show.** By default the Job
refuses to apply a plan that destroys or replaces a resource unless that
resource's address is listed in `allowDestroy`. The refusal exits non-zero
with the plan summary in the termination log, so it reaches the deploy log
through the path that already exists, and the deploy stops with a readable
reason. This is the same stance as `kix gc`: no silent deletes.

The behaviour is a policy, not a constant. `onDestroy` takes `refuse`
(default) or `apply`, set cluster-wide as `cluster.tofu.onDestroy` and
overridable per instance, the same shape as `cluster.spread.default` in doc
143. A throwaway or CI cluster sets `apply` once and never sees the refusal;
a production registry keeps `refuse` and lists exceptions by address. Both
the policy and the `allowDestroy` list are part of the ConfigMap, so
loosening either is itself visible in the eval-time diff, which is the
point.

What this design does not do is fold the plan into `kix diff`. A plan needs
Harbor reachable and the state Secret readable, and making `kix diff` block on
that gives up the pure-versus-impure boundary for a convenience. If a plan
preview is wanted, it belongs beside the drift check as its own verb, which is
what doc 139 §4 argues for resolvers generally.

### 3.6 Rollback and state: the residual trade-off

The state Secret is truth Kix does not compute. It records what the provider
created and under which IDs. Kix carries it in the cluster and cannot
regenerate it. If it is lost, the next apply tries to create projects that
exist.

Rollback re-applies the previous activation, which contains the previous
ConfigMap and the previous Job. The Job has usually been reaped by TTL, so it
is recreated and runs, and Harbor follows one Job run behind the Kubernetes
side. The Activation only reaches Active after that Job, so the window is
visible rather than hidden.

If the change being rolled back added a project, the rollback plan contains a
destroy, and under the default policy §3.5 refuses it. Rollback for this
package is then not always automatic: somebody reads the reason and either
lists the address in `allowDestroy`, sets `onDestroy = "apply"` for the
instance, or leaves the project. The default is deliberate. An automated
rollback should not be what deletes a registry's images. A cluster whose
Harbor holds nothing worth keeping sets the policy to `apply` and gets clean
rollbacks back.

## 4. Alternatives considered

- **Plan-only Job or CLI-side plan over a port-forward, folded into `kix
  diff`.** Rejected in §3.5. The boundary is worth more than the preview.
- **Store the terranix JSON on the Activation as a separate field.** Not
  needed. The ConfigMap is in the manifest set, and the manifest set is the
  activation. A second copy would be one more thing to keep in step.
- **Plain JSON attrset without terranix.** Viable and smaller. Terranix buys
  the module system for provider-typed options, escaping of `${}` in strings,
  and a body of existing modules. Whether that is worth a flake input is open
  question 5.
- **Crossplane provider-terraform or upjet-generated providers.** Rejected in
  §2: a runtime reconciler with no plan phase, for pure configuration.
- **Run the apply from the CLI on the operator's machine.** Rejected: it
  needs Harbor reachable from wherever `kix deploy` runs, puts provider
  binaries on the operator's path, and moves the state backend out of the
  cluster the activation describes.

## 5. Relationship to prior docs

- Doc 64 §4's bridge direction is unchanged: Terraform outputs for cloud
  resources still come in through `mkImport`. This doc is the other
  direction, and only for resources inside applications Kix deploys.
- Doc 129a open question 3: Kix does emit demands, but not to a provisioning
  layer outside the activation. The demand, its executor and its state all
  live in the cluster the activation describes.
- Doc 139 §4: this is not a pluggable resolver. Nothing here resolves a value
  during evaluation. The Job is execution, ordered by the graph, with its own
  refusal.
- Doc 117 §5: the plan summary in the receipt is a first piece of the day-2
  read-back that section calls an assembly gap.

## 6. Rollout

1. `scope.mkTofuJob` in the lib, the Nix-built image with the Harbor
   provider, and `projects` on the harbor package. Verified on the kind
   cluster from PR #114: create, change quota, remove under both `onDestroy`
   policies.
2. The `plan.rs` renderer change for the annotated ConfigMap.
3. Termination-log summary on success, plus the receipt field.
4. Forgejo users and organisations, Grafana organisations.

## 7. Open questions

1. **State Secret custody.** It holds provider IDs and, for robot accounts,
   the generated tokens. Should the package declare it through the backup
   contract (doc 108) with a `credential` classification, given Kix never
   authors it?
2. **Adoption.** A Harbor that already has projects needs `tofu import`
   before the first plan is clean. Is that a one-time Job variant, a
   documented manual step, or out of scope until it bites?
3. **Success-path termination output.** The smallest CLI change is to treat a
   non-empty termination message on a succeeded Job as its ready-line detail.
   Does any existing Job write one that this would suddenly print?
4. **Which requires.** `stackgres-database` chose `forwardEdges` over
   `postHooks` so consumers gate on the Job. For Harbor projects nothing
   downstream consumes them in the graph, so `requires` from the Job to the
   Deployment is enough. Is there a consumer case, for example a CI package
   that needs a robot account Secret, that flips this?
5. **Terranix or plain JSON.** See §4. Lean: start with terranix, since the
   provider option types are the part a package author would otherwise
   re-derive from provider docs.
6. **Drift.** The plan detects it at the next deploy only. Should `kix
   drift` (doc 106) grow a "plan-only" mode for these Jobs, as the separate
   verb §3.5 defers to?
