# 06: Ecosystem Validation

## How existing K8s tooling handles the two-level abstraction problem

Five systems were analyzed for how they separate package-level from
cluster-level concerns, handle cross-cutting features, and solve the
`withAutoscaler` pattern.

## Helm + ArgoCD

**Package level (Helm):** Charts are self-contained. Cross-cutting concerns
(monitoring, autoscaling) are gated by values (`metrics.serviceMonitor.enabled:
true`). Every chart independently implements every cross-cutting feature,
leading to massive duplication and inconsistency.

**Cluster level (ArgoCD):** Charts are opaque. ArgoCD can deploy them but
cannot modify their output. App-of-Apps pattern and ApplicationSet provide
fleet-level orchestration but no resource modification.

**Cross-cutting concerns:** No native mechanism. Workarounds:
- Kustomize post-rendering (`helm template | kustomize build`)
- Separate Applications for cross-cutting resources

**withAutoscaler:** Not possible at ArgoCD level. Must be baked into the Helm
chart.

**Dependency tracking:** Static `sync-wave` annotations. No DAG.

**Lesson for kixpkgs:** Avoid Helm's mistake of putting cross-cutting resource
generation inside individual charts. Phase 5's monitoring policy already
gets this right. The capability interface is the clean generalization.

## Crossplane Compositions

**Package level (Managed Resources):** Individual K8s/cloud resources.

**Cluster level (XRD/Composition):** CompositeResourceDefinition (XRD) defines
a high-level API. A Composition maps it to concrete resources via patches:

```yaml
# XRD: high-level API (like chart options)
kind: XDatabase
spec:
  size: small  # user-facing

# Composition: maps API to resources (like resources.nix)
resources:
  - base:
      kind: DBInstance
    patches:
      - fromFieldPath: "spec.size"
        toFieldPath: "spec.forProvider.instanceClass"
        transforms:
          - type: map
            map: { small: db.t3.micro, large: db.r5.2xlarge }
```

**Cross-cutting concerns:** Composition's resource list can include any resources.
`spec.autoscaling.enabled` controls whether HPA is included.

**withAutoscaler:** Natural. HPA is a resource in the Composition list, patched
from the composite's fields. If the user doesn't set `spec.autoscaling`, the
HPA is omitted.

**Dependency tracking:** Internal reconciliation with readiness checks. No
explicit DAG.

**Lesson for kixpkgs:** The XRD/Composition split maps directly:

| Crossplane | kixpkgs |
|---|---|
| XRD (user API) | Chart options (`pkgs/<name>/options.nix`) |
| Composition (mapping) | Chart resources (`pkgs/<name>/resources.nix`) |
| Composite Resource | Cluster config (`clusters/example.nix`) |
| Managed Resources | `config.manifests` entries |

Crossplane's weakness: its patch language isn't expressive enough for complex
logic, requiring Composition Functions (external programs). Nix doesn't have
this problem — the language IS the transform layer.

## Kustomize Components

**Cross-cutting pattern:** Components are reusable overlay fragments:

```yaml
# components/autoscaler/kustomization.yaml
kind: Component
resources:
  - hpa.yaml                    # adds HPA resource
patchesStrategicMerge:
  - remove-replicas.yaml        # patches Deployment to remove replicas
```

**withAutoscaler:** Exactly what Components are designed for. Include the
component, it adds HPA and patches the Deployment.

**Weakness:** Everything is string-level YAML manipulation. No type safety.
A patch targeting "myapp" silently does nothing if the Deployment is named
"myapp-server". Silent failures everywhere.

**Lesson for kixpkgs:** Components validate the cross-cutting resource pattern.
Our capability interfaces are the typed, safe version of what Kustomize
Components do with YAML patches.

## cdk8s (TypeScript/Python CDK)

**Constructs and Charts:** Construct tree borrowed from AWS CDK:

```typescript
class WithAutoscaler extends Construct {
  constructor(scope, id, target: KubeDeployment, props: HpaProps) {
    super(scope, id);
    new KubeHorizontalPodAutoscaler(this, 'hpa', {
      spec: {
        scaleTargetRef: {
          name: target.name,  // typed reference!
        },
      }
    });
  }
}
```

**Cross-cutting:** Higher-order constructs or functions that take a resource
and augment it. Full language power — conditionals, loops, typed references.

**withAutoscaler:** Natural. Typed references to Deployment objects. Read
properties, create HPA.

**Weakness:** No declarative configuration layer. No option merging. No
`mkDefault`/`mkForce`. Testing requires running the full program.

**Lesson for kixpkgs:** Validates the resource group combinator pattern
(Approach 2 in 04-with-autoscaler.md). cdk8s constructs are essentially
resource groups with typed references. kixpkgs adds what cdk8s lacks:
declarative merge semantics via the NixOS module system.

## Pulumi

**Component Resources:** Similar to Crossplane Compositions but in a real
language:

```typescript
class WebApp extends pulumi.ComponentResource {
  constructor(name, args) {
    const deployment = new k8s.apps.v1.Deployment(...);
    if (args.autoscaling?.enabled) {
      new k8s.autoscaling.v2.HPA("hpa", {
        spec: {
          scaleTargetRef: { name: deployment.metadata.name },
          // ← Output<string>, automatic dependency!
        }
      });
    }
  }
}
```

**Dependency tracking:** Automatic via `Output<T>` type. When you write
`deployment.metadata.name`, Pulumi knows the HPA depends on the Deployment.
This is the **typed reference pattern from V1**, validated at scale.

**Transformations:** Intercept resource creation, modify properties:

```typescript
const provider = new k8s.Provider("k8s", {
  transformations: [(args) => {
    args.props.metadata.labels["managed-by"] = "pulumi";
  }],
});
```

Similar to NixOS module overlays.

**Lesson for kixpkgs:** Pulumi's `Output<T>` validates the typed reference
concept. The difference: Pulumi tracks dependencies through a runtime promise
system; kixpkgs would need to track them through eval-time metadata (underscore
fields) or structural inference. Pulumi's transformations validate the
capability interface pattern.

## Synthesis

| Feature | Helm | ArgoCD | Crossplane | Kustomize | cdk8s | Pulumi | **kixpkgs (proposed)** |
|---|---|---|---|---|---|---|---|
| Declarative merge | No | No | Weak | Weak | No | No | **Yes (NixOS modules)** |
| Full language | No | No | No | No | Yes | Yes | **Yes (Nix)** |
| Structural access | No | No | Patches | No | Yes | Yes | **Yes (attrsets)** |
| Cross-cutting | Per-chart | Separate apps | Composition | Components | Constructs | Transforms | **Capability interfaces** |
| withAutoscaler | Chart-internal | No | Yes | Yes | Yes | Yes | **Groups + capabilities** |
| Dep tracking | No | Sync waves | Internal | No | Manual | Auto (Output) | **Inference + capabilities** |

**kixpkgs is the only system that combines all three of**: declarative merge
semantics, full language power, and structural resource access. The capability
interface pattern is the cleanest solution to cross-cutting concerns seen
across any of these systems.
