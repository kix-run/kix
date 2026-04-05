# 73 — Compiled Jobs: What Does It Mean to Compile a Workload?

**Status:** Brainstorm
**Related:** `43_activation_operator.md` (Activation model), `69_hardware_driven_scheduling.md` (hardware-aware scheduling), `72_ai_cluster_recipes.md` (AI stack configuration), `29_compiler-design.md` (compiler model), `42_dep_config_injection.md` (DI)

---

## The Real Question

kix compiles cluster state. It knows the dependency graph — which packages exist, what storage they provision, what schedulers are installed, what GPU hardware is available, what CRDs are registered. Today, all of that knowledge is used to produce long-running resources (Deployments, StatefulSets, DaemonSets) in an Activation.

But a huge class of Kubernetes usage — especially in AI — is **Jobs**: things you run, they complete, you look at results. Training runs, batch processing, data pipelines, fine-tuning experiments. These are typically submitted via operator CRDs (RayJob, PyTorchJob, JobSet) that already handle the orchestration semantics.

The convenience problem is solved. Ray, vLLM, Kubeflow — they all provide good UX for submitting work. The scheduling problem is solved. Kueue, KAI Scheduler, Volcano — they handle queuing, preemption, fair-share.

**What nobody solves is the compilation problem.** When you submit a RayJob, you need to know:
- What tolerations to add for GPU nodes (depends on your cluster's taint scheme)
- What priority class to use (depends on what Kueue ResourceFlavors/ClusterQueues exist)
- What storage to mount for checkpoints (depends on what CSI/S3 is available and how it's configured)
- What NCCL environment variables to set (depends on your network topology — InfiniBand? EFA? TCP?)
- What image registry to pull from (depends on your cluster's pull secret setup)
- What service account to use (depends on what RBAC exists)

All of this information **already exists in the kix compilation graph**. The cluster compiled Kueue with specific queues. It compiled the GPU operator with specific taints. It compiled S3 storage with specific endpoints. The answers to every question above are derivable from the Activation.

**The hypothesis: kix can compile a Job the same way it compiles a Deployment — by deriving the wiring from the dependency graph. The difference is lifecycle, not compilation.**

---

## What "Compiling a Job" Actually Means

### The compiler already does this for services

When a kix package produces a Deployment, the compiler:
1. Resolves dependencies (DI gives you your postgres, your S3, your cert-manager)
2. Derives scheduling (tolerations, affinity from cluster hardware profile)
3. Wires connections (env vars pointing to dependency endpoints)
4. Emits RBAC (ServiceAccount + Role + Binding from intent)
5. Validates constraints (resource requests vs cluster capacity, API version compatibility)

**A Job needs exactly the same compilation.** The only difference: a Deployment lives in the Activation forever, a Job runs once and is done.

### What compilation adds to a RayJob

Consider what a researcher writes today vs. what they'd need:

```yaml
# What the researcher cares about:
apiVersion: ray.io/v1
kind: RayJob
spec:
  entrypoint: "python train.py --lr=1e-4 --epochs=100"
  runtimeEnvYAML: |
    pip: ["torch==2.3", "transformers"]
  rayClusterSpec:
    headGroupSpec:
      template:
        spec:
          containers:
            - image: my-training:v3
    workerGroupSpecs:
      - replicas: 4
        template:
          spec:
            containers:
              - image: my-training:v3
                resources:
                  limits:
                    nvidia.com/gpu: 1
```

```yaml
# What the cluster actually needs (the wiring):
    workerGroupSpecs:
      - replicas: 4
        template:
          spec:
            tolerations:                              # ← from cluster hardware profile
              - key: nvidia.com/gpu
                operator: Exists
                effect: NoSchedule
            affinity:                                  # ← from cluster topology
              nodeAffinity:
                requiredDuringSchedulingIgnoredDuringExecution:
                  nodeSelectorTerms:
                    - matchExpressions:
                        - key: node.kubernetes.io/instance-type
                          operator: In
                          values: ["p4d.24xlarge"]
            serviceAccountName: ml-team-training       # ← compiled RBAC
            priorityClassName: training-batch           # ← from Kueue config
            containers:
              - image: my-training:v3
                env:
                  - name: NCCL_SOCKET_IFNAME            # ← from cluster network config
                    value: "eth0"
                  - name: NCCL_DEBUG
                    value: "INFO"
                  - name: CHECKPOINT_S3_ENDPOINT        # ← from compiled S3 dependency
                    value: "http://minio.storage:9000"
                  - name: CHECKPOINT_S3_BUCKET           # ← from compiled S3 dependency
                    value: "ml-checkpoints"
                  - name: FI_PROVIDER                    # ← from cluster network (EFA)
                    value: "efa"
                resources:
                  limits:
                    nvidia.com/gpu: 1
                    vpc.amazonaws.com/efa: 1             # ← from cluster hardware
                volumeMounts:
                  - name: dshm                           # ← compiled: NCCL needs this
                    mountPath: /dev/shm
            volumes:
              - name: dshm
                emptyDir:
                  medium: Memory
                  sizeLimit: "64Gi"                      # ← derived from node memory
            metadata:
              labels:
                kueue.x-k8s.io/queue-name: ml-team-gpu  # ← from compiled Kueue queues
```

Every line marked `←` is information the kix compiler already has. Today, someone copies it from a wiki or a colleague's YAML. The compiler could derive it.

---

## The Interesting Design Space

### Model A: Jobs as packages (compile-time, in-Activation)

The straightforward model. A Job is just another package. You `nix build` it, it goes in the Activation, the operator applies it.

```nix
# packages/training-run/package.nix
{ scope, config, deps }:
scope.mkRayJob {
  entrypoint = "python train.py --lr=${config.learningRate}";
  workers = { replicas = 4; gpu = 1; };
  deps = { checkpoints = deps.s3; };
}
```

The compiler does its thing — derives tolerations, wires S3 creds, adds Kueue labels, emits RBAC. The output is a fully-wired RayJob CR.

**Pros:**
- Zero new concepts. A Job is a package. The existing compiler handles it.
- Full dependency graph — the Job's S3 dependency, its Kueue queue, its GPU scheduling are all validated at compile time.
- Content-addressed. If parameters change, the hash changes, the operator diffs and re-applies.

**Cons:**
- Every parameter change → new build → new Activation → full deploy cycle. Terrible for iteration.
- The Activation accumulates completed Jobs. Need a GC story (completed Jobs pruned on next Activation? operator-managed TTL?).
- Doesn't match how people actually work with Jobs. Nobody commits a training run to git.

**Where this makes sense:** Scheduled production Jobs (nightly ETL, periodic retraining). Things that _should_ be version-controlled and part of the cluster's declared state. CronJobs are basically this already.

### Model B: Compiled templates + runtime instantiation

The Activation contains not the Job itself but a **template** — a partially-compiled Job with all the infrastructure wiring baked in, and holes for user-specified parameters. At runtime, something fills the holes and submits the completed Job.

The template is a kix package. The filling happens outside the Activation cycle.

```nix
# packages/training-template/package.nix
{ scope, config, deps }:
scope.mkJobTemplate {
  # The "compiled" part — infrastructure wiring
  base = scope.mkRayJob {
    workers = {
      gpu = 1;
      # tolerations, affinity, NCCL, etc. — derived by compiler
    };
    deps = { checkpoints = deps.s3; };
  };

  # The "open" part — what the user fills in at runtime
  parameters = {
    entrypoint = { type = "string"; };
    workerReplicas = { type = "int"; min = 1; max = 16; };
    image = { type = "string"; };
  };
}
```

**The question this raises:** Who fills the template? Options:
1. **The kix operator** — watches a `JobRequest` CRD, merges parameters into template, creates the real RayJob. The operator becomes an admission+compilation layer.
2. **A CLI tool** — `kix run training --replicas=4 --image=...` reads the template from the cluster (or from the local build), fills it, and `kubectl apply`s the result. The operator isn't involved.
3. **The user's own tooling** — kix exports the template as a JSON schema. The user's Jupyter notebook / CI pipeline / Ray dashboard reads the schema and constructs a valid RayJob. kix provides the compilation but not the runtime.

Option 3 is interesting because it doesn't expand the operator's responsibility. The compiled template is just a data artifact — a "here's what a correct RayJob looks like on this cluster" document that any tool can consume.

### Model C: Compilation as a function (not a deployment)

What if compiling a Job is a **build-time function** rather than a deployed template?

```bash
# "Compile this RayJob spec against the cluster's dependency graph"
nix build .#cluster-prod.compileJob --arg spec ./my-rayjob.yaml
# Output: a fully-wired RayJob YAML with all cluster-specific annotations
```

The user writes a minimal RayJob (just the parts they care about). They pass it through the kix compiler, which enriches it with everything the cluster knows. The output is a standalone YAML they can `kubectl apply`.

```
user's minimal spec ──→ kix compiler ──→ fully-wired spec ──→ kubectl apply
                            ↑
                     cluster definition
                     (hardware, deps, config)
```

**Pros:**
- No operator involvement. No new CRDs. No template lifecycle.
- The compiler is a pure function: input spec + cluster context → output spec.
- Works with _any_ CRD — RayJob, PyTorchJob, JobSet, plain Job. The compiler just needs to know which fields to enrich.
- Composable with existing workflows. Jupyter notebooks, CI pipelines, Ray dashboards — they all produce YAML. kix just makes it correct.

**Cons:**
- Requires Nix (or an evaluated cluster definition) at the point of Job submission. Unless you cache the "cluster enrichment context" as a portable artifact.
- No runtime validation — you get a correct YAML at compile time, but nothing stops someone from editing it afterward.
- The compiler needs to understand the schema of each Job CRD to know where to inject tolerations, env vars, etc. This is the "CRD awareness" problem from doc 29, section 4.7.

**Where this is powerful:** This is essentially `kix compile-job` — a standalone tool that takes any Job spec and enriches it against a cluster definition. It doesn't change the deployment model at all. It's a **linter+enricher**, not a new primitive.

### Model D: Dependency-scoped compilation contexts

The deepest version of the idea. Instead of compiling individual Jobs, compile a **context** — a bundle of everything a namespace/team/workload-type needs to submit correct Jobs.

```nix
# In the cluster definition:
teams.ml-research = {
  namespace = "ml-research";
  deps = [ packages.kueue packages.gpu-operator packages.minio ];
  jobCapabilities = {
    gpu = { types = [ "a100" "h100" ]; maxPerJob = 8; };
    storage = { checkpoints = deps.minio; };
    scheduling = { queue = "ml-research-gpu"; priority = "batch"; };
  };
};
```

The compiler evaluates this and produces a **compilation context** — a self-contained artifact that encodes everything the `ml-research` namespace needs:

```json
{
  "scheduling": {
    "gpu_tolerations": [{"key": "nvidia.com/gpu", "operator": "Exists", "effect": "NoSchedule"}],
    "node_affinity": {"nodeSelectorTerms": [...]},
    "priority_class": "batch",
    "kueue_queue": "ml-research-gpu"
  },
  "environment": {
    "NCCL_SOCKET_IFNAME": "eth0",
    "CHECKPOINT_S3_ENDPOINT": "http://minio.storage:9000",
    "CHECKPOINT_S3_BUCKET": "ml-checkpoints"
  },
  "rbac": {
    "service_account": "ml-research-training"
  },
  "constraints": {
    "max_gpu_per_job": 8,
    "allowed_gpu_types": ["a100", "h100"]
  }
}
```

This context is a build artifact — produced by `nix build`, versioned, content-addressed. Any tool can read it and use it to enrich Job specs. A kubectl plugin, a Jupyter extension, a CI step, or a simple shell script.

**Why this is interesting:**
- The compilation happens once (per Activation). Job submission doesn't require Nix.
- The context is portable — it's JSON, not Nix. Any language can consume it.
- It captures exactly the information that's hard to get right: scheduling, networking, storage wiring, RBAC.
- It degrades gracefully. Even without operator changes, this is useful: "here's a JSON file with your cluster's GPU config, paste these tolerations into your Job." The manual process becomes semi-automated.

---

## The Ecosystem Integration Point

Whatever model we pick, the mandatory requirement is: **kix must integrate with the CRD ecosystem, not replace it.**

People use RayJob, PyTorchJob, SparkApplication, Argo Workflow, Tekton TaskRun. These CRDs are the interfaces. kix's job is to produce _correct instances_ of these CRDs, with all the cluster-specific wiring compiled in.

This means the compiler needs CRD awareness (doc 29, section 4.7) — but specifically for the "enrichment" fields:

| CRD field type | What kix compiles into it | Example |
|---------------|--------------------------|---------|
| **Pod template** → tolerations | Derived from cluster hardware profile | GPU node taints |
| **Pod template** → affinity | Derived from cluster topology | Zone-aware placement |
| **Pod template** → env | Derived from dependency graph | S3 endpoints, NCCL config |
| **Pod template** → volumes/mounts | Derived from storage dependencies | Checkpoint storage, shared memory |
| **Pod template** → serviceAccountName | Compiled RBAC | Team-scoped service account |
| **Pod template** → priorityClassName | Derived from Kueue config | Queue-appropriate priority |
| **Metadata** → labels | Derived from Kueue config | Queue assignment labels |
| **Metadata** → annotations | Derived from scheduler config | Scheduling hints |

The pattern: kix doesn't touch the _business logic_ of the CRD (entrypoint, replicas, framework config). It fills in the _infrastructure wiring_ that the CRD expects but can't derive on its own.

**CRD-aware enrichment rules** could be part of the kix package for that operator:

```nix
# packages/ray/package.nix
{
  # ... normal Ray operator deployment ...

  # How kix compiles Jobs that target this operator's CRDs
  jobEnrichment."ray.io/v1/RayJob" = {
    podTemplatePaths = [
      "spec.rayClusterSpec.headGroupSpec.template"
      "spec.rayClusterSpec.workerGroupSpecs[*].template"
    ];
    # Tells the compiler where to inject scheduling, env, volumes, etc.
  };
}
```

This way, when a new operator is packaged for kix, it declares how its CRDs' pod templates should be enriched. The compilation logic is generic (inject tolerations, env, volumes into pod templates); the CRD-specific part is just "where are the pod templates?"

---

## The Lifecycle Question

The remaining fundamental question: **where in the lifecycle does compilation happen?**

```
                    ┌──────────────┐
                    │ cluster def  │
                    │ (nix)        │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
        Model A       Model C       Model D
     Job-in-Activation  compile-fn   context-artifact
              │            │            │
              │            │            │
              ▼            ▼            ▼
        operator       kubectl       any tool
        applies        apply         (jupyter, CI,
                                      ray dashboard)
```

These aren't mutually exclusive. A cluster could use:
- **Model A** for production CronJobs (nightly retraining, ETL)
- **Model D** for researcher ad-hoc Jobs (compilation context exported as artifact)
- **Model C** as a dev tool (`kix compile-job` for one-off enrichment)

The common denominator: **the compiler knows the graph, and Jobs need the graph's answers.** How you get those answers to the Job is a UX/lifecycle question, not a compiler question.

---

## Concrete Next Steps (if we pursue this)

1. **Prove Model C works manually.** Take an existing cluster definition, manually extract the enrichment context (tolerations, env vars, Kueue config), and show that a minimal RayJob + enrichment = a correct, runnable RayJob. This validates the hypothesis without any new code.

2. **Design the enrichment context schema.** What fields does it contain? How does it compose across dependencies? This is the core data structure.

3. **Add `podTemplatePaths` to one CRD-providing package.** The Ray package is the obvious candidate. Have it declare where pod templates live in its CRDs.

4. **Build `kix compile-job`.** A CLI command that takes a user's Job spec + a built cluster and produces an enriched Job spec. Pure function, no operator involvement.

5. **Evaluate whether the operator should be involved.** Once we see how compile-job works, decide if runtime admission (Model B) adds enough value to justify the operator complexity.

---

## What This Means for kix's Position

The insight isn't "kix manages Jobs." It's: **kix already has the answers that Job authors need — the compilation graph contains scheduling, networking, storage, and RBAC information that today lives in tribal knowledge and wiki pages.**

The question is just how to surface those answers:
- As compiled resources (Model A — full control, high friction)
- As a compilation function (Model C — zero friction, no runtime guarantees)
- As a portable context artifact (Model D — zero friction, tool-agnostic)
- As operator-mediated admission (Model B — medium friction, full guarantees)

The compilation itself is the same in all models. The dependency graph doesn't change. The enrichment rules don't change. Only the delivery mechanism changes.

**This is a natural extension of the compiler thesis:** kix compiles wiring. Jobs have wiring. Therefore kix compiles Jobs. The lifecycle question (when and how) is secondary to the core capability (the compiler knows the answers).
