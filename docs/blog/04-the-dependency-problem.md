---
title: "The Dependency Problem"
date: 2026-03-09
series: 4
commits:
  - 9046d26  # docs: add dependency tracking design doc
  - e5a7667  # docs: dependency tracking V4 — capability interfaces and architecture redesign
---

# The Dependency Problem

*2026-03-09 -- Post 4*

---

You deploy cert-manager. It installs Custom Resource Definitions, including one called `Certificate`. Then you deploy ingress-nginx. Its config includes a `Certificate` resource that requests a TLS cert for your ingress. Everything works.

Now reverse the order. Deploy ingress-nginx first. Kubernetes rejects the manifest immediately: `no matches for kind "Certificate" in version "cert-manager.io/v1"`. The `Certificate` kind does not exist yet because cert-manager has not created the CRD. Nothing in the ingress-nginx YAML mentions cert-manager by name. The dependency is invisible.

This is not a rare edge case. It is the normal state of a Kubernetes cluster with more than a handful of services.

## Two types of hidden dependencies

The cert-manager example is one of two patterns that keep appearing.

**CRD dependencies.** Resource A uses a `kind` defined by resource B's Custom Resource Definition. The YAML for resource A contains `apiVersion: cert-manager.io/v1` and `kind: Certificate`, but it never names the CRD resource itself (`certificates.cert-manager.io`) or the cert-manager controller deployment. There is no string you can grep for that links A to B.

**Selector dependencies.** Resource A selects pods by label. Resource B creates those pods. A Kubernetes `Service` finds its backends through `spec.selector.matchLabels`, not by naming a `Deployment`. A `PodMonitor` finds scrape targets through label selectors, not by referencing a `Service`. The YAML uses labels, not names, so there is no discoverable link between the two resources.

Both types share the same property: the dependency is **semantic**, not **syntactic**. You cannot find it by scanning for name references. You have to understand what the resource *means*.

## Four iterations in one day

The design docs show four attempts at solving this, all written on the same day.

**V1** started with a simple `requires` list on each resource. Package authors manually listed their dependencies. It worked, but forgetting an entry was easy and there was no way to verify completeness.

**V2** added automatic **ref detection**. When one resource interpolated another resource's name into its spec (e.g., `secretName = secret.out.name`), the system tracked that reference and inferred a dependency. This eliminated manual wiring for the common case of name-based references. But CRD and selector dependencies still had no string to detect.

**V3** tried **capability interfaces**. The idea was that a package could declare "I provide the `Certificate` kind" and consumers could declare "I need the `Certificate` kind." The system would match them up. This added conceptual overhead without solving the fundamental detection problem -- someone still had to write those declarations.

**V4** landed on a hybrid. Nix's string interpolation (`${}`) already tracks store paths through string contexts. When you write `"${service.out.name}"`, Nix knows that the resulting string depends on the service resource. kix uses this native mechanism to **automatically track name-based references**. For dependencies that have no textual manifestation -- CRD kinds and label selectors -- kix provides an explicit `requires` attribute. A **type provider** constructor wraps CRD usage so that `requires` is injected automatically when you create a custom resource.

## The insight

You cannot fully automate dependency detection in Kubernetes. Some dependencies are syntactic: resource A mentions resource B's name in a spec field. Those are automatable -- string interpolation can track them. Other dependencies are semantic: resource A uses a kind that resource B defines, or resource A selects pods that resource B creates. No amount of string scanning will find those.

The best you can do is automate what is automatable and make the manual part explicit and checked. In kix, `${}` handles the first category. `requires` handles the second. Type providers bridge the gap for the most common semantic dependency -- CRDs -- by injecting `requires` transparently through a constructor function. The package author who creates a `Certificate` resource does not need to remember to add cert-manager to `requires`. The type provider does it for them.

The dependency graph is not optional decoration. It is what makes `kubectl apply` work in the right order. The next post looks at how kix turns that graph into a concrete deployment plan.
