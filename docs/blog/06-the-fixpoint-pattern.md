---
title: "The Fixpoint Pattern"
date: 2026-03-11
date_end: 2026-03-12
series: 6
commits:
  - 1767801  # feat: first rough fixpoint impl
  - 7db9223  # feat: migrate example clusters to fixpoint approach
---

# The Fixpoint Pattern

*2026-03-11 to 2026-03-12 -- Post 6*

---

You want to customize a package. The CoreDNS package creates a Deployment with 1 replica. Your production cluster needs 3 replicas, higher resource limits, and a custom annotation on the Service. What do you do?

## The fork approach

Copy the package. Change the values. Ship it. Now you maintain a fork. When upstream fixes a bug or bumps a version, you either miss the fix or manually cherry-pick it into your copy. Every customization multiplies the maintenance cost. This does not scale.

## The config approach

kix packages already have typed options. You can override values at the instance level without touching the package source:

```nix
instances.kube-system = {
  coredns = {
    package = packages.coredns;
    config = { replicaCount = 3; };
  };
};
```

This is clean. The package defines the default. The cluster definition overrides it. No fork needed.

But typed options only cover what the package author anticipated. What if you need to add an annotation the author never exposed as an option? What if you need to inject a sidecar container? What if you need to patch the Deployment's strategy or add a toleration? You cannot add an option for every possible Kubernetes field -- that would recreate Helm's `values.yaml` sprawl.

You need a way to modify the **actual resources** a package produces, without forking the package and without requiring the author to predict every customization.

## The overlay approach

kix lets you intercept a package's output with an **overlay function**:

```nix
coredns = {
  package = packages.coredns;
  overlay = self: super: {
    deployment = super.deployment // {
      metadata = super.deployment.metadata // {
        annotations = { "custom.io/managed" = "true"; };
      };
      spec = super.deployment.spec // {
        replicas = 3;
      };
    };
  };
};
```

Two arguments. **`super`** is what the package originally produced -- the unmodified resources. **`self`** is what the package will become after all overlays are applied. Your overlay function sits in the middle, taking the original output and returning a modified version.

You only touch what you need to change. The rest passes through untouched. The original package never knows about your overlay. It continues to evolve independently. When the author bumps the CoreDNS image version, your overlay still applies cleanly -- it never referenced the image.

## Why it is called a fixpoint

This pattern has a name in mathematics and functional programming: a **fixpoint**. A fixpoint is when you define something in terms of its own final value. The package sees `self`, which is itself *after* all overlays are applied. This means overlays can reference each other's results. An overlay that adds a sidecar container can reference the final service name from `self`, even if that name was set by a different overlay.

Nix uses this pattern everywhere. NixOS overlays customize the package set the same way. The module system's `config` is a fixpoint of all module contributions. kix applies the same idea at the Kubernetes resource level.

## What this enables

Composable customization without forking. A platform team can publish a CoreDNS package with sensible defaults. Each cluster applies its own overlay: production gets 3 replicas and strict resource limits, staging gets 1 replica and relaxed limits. The overlays live in the cluster definition, not in copied package code.

It also enables **cross-cutting concerns**. A security overlay can inject a pod-security annotation onto every Deployment across every package, without modifying any package source. The overlay pattern turns packages from closed boxes into extensible building blocks.

## The migration

The existing example clusters and a client's production infrastructure were migrated to use this pattern. Instances that previously used forked or inline packages were rewritten to use overlays. The result was less duplicated code and a clearer separation between what a package defines and what a cluster customizes.

The next post covers why all of this had to be redesigned.
