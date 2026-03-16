# Customizing a package: swapping CoreDNS's Deployment for a StatefulSet

## Background

kixpkgs packages Kubernetes charts as Nix modules. Each chart (like `coredns`) is a collection of resources — a Deployment, a Service, a ConfigMap, RBAC objects, etc. When you evaluate a chart, you get all of those resources as output YAML.

But what if you want *almost* the default CoreDNS, with one change — say, a StatefulSet instead of a Deployment? Today you'd have to rewrite the whole chart. The fixpoint pattern (`overrideParts`) lets you surgically replace one resource while keeping everything else.

## The key idea

Each resource in a package can reference other resources via `self`. When you write `self.service.ref`, two things happen:
1. You get the Service's name as a string (to use in your YAML field)
2. The Service is automatically included in the output

This means the output is always exactly the set of resources that are actually needed — no manual bookkeeping.

## Example

```nix
myCoredns = pkgs.coredns.overrideParts (self: super: {
  # super = the original package's resources (Deployment, Service, ConfigMap, SA, etc.)
  # self  = the final resource set after merging our overrides on top of super
  #
  # This attrset gets merged over super. We only set `workload`, so that's
  # the only resource that changes. super.configmap, super.serviceAccount,
  # super.service, etc. all pass through untouched into self.

  # super.workload was a Deployment. By setting `workload` here, we replace
  # it with our StatefulSet. The original Deployment is gone from the output.
  workload = k8s.mkResource {
    kind = "StatefulSet";
    name = "coredns";

    # requires = explicit "include this". Use when the other resource
    # points at us (PDB selects our pods), not the other way around.
    requires = [ self.pdb ];

    spec = {
      serviceName = self.service.ref;       # ← new dependency (Deployments don't have this)
      template.spec = {
        serviceAccountName = self.serviceAccount.ref;  # ← pulls in SA + RBAC chain
        containers = [{ /* ... */ }];
        volumes = [{
          configMap.name = self.configmap.ref;
        }];
      };
    };
  };
});
```

## What changed in the output

The original Deployment pulled in: ServiceAccount, ClusterRoleBinding, ClusterRole, ConfigMap, PDB.

Our StatefulSet pulls in all of those **plus Service** — because we wrote `serviceName = self.service.ref`, which the Deployment never needed.

We didn't add the Service to a list anywhere. It showed up because we referenced it.

## `ref` vs `requires`

There are two ways a resource can pull in another:

- **`self.foo.ref`** — You reference another resource by name. Use this when your YAML mentions another resource's name (like `serviceName` or `configMap.name`).

- **`requires = [ self.foo ]`** — Explicit inclusion. Use this when there's no `ref` to create the link automatically.

  Concrete example: a PodDisruptionBudget protects your StatefulSet's pods. But look at who references whom — the PDB's YAML contains a label selector that matches your pods. Your StatefulSet's YAML never mentions the PDB at all. So there's no place to write `self.pdb.ref`. Yet you still want the PDB in your output. That's what `requires` is for: "I need this resource, even though my YAML doesn't name it."

**Rule of thumb:** if your YAML mentions another resource's name, use `ref`. If you need a resource but your YAML doesn't mention it, use `requires`.
