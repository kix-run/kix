---
title: "The Idea: Kubernetes Manifests as Nix Packages"
date: 2026-03-07
series: 1
commit: b979523  # feat: initial kix — Kubernetes resources as Nix modules
---

# The Idea: Kubernetes Manifests as Nix Packages

*2026-03-07 -- Post 1*

---

If you run anything on Kubernetes, you have probably fought with **Helm** or **Kustomize**. Helm charts are Go-templated YAML: you pass in a `values.yaml`, the template engine string-interpolates your values into manifests, and you hope nothing was misspelled. Kustomize takes a different route -- you write base manifests, then layer patches on top. Both tools produce opaque output that is hard to inspect before you apply it. And neither lets one service's config reference another service's output. Values flow in one direction and you cannot ask questions back.

I wanted something different. What if each Kubernetes service was a **Nix package**?

## Why Nix

Nix is a pure-functional language originally built for OS package management (NixOS). Three things matter here: (1) expressions are deterministic -- same inputs, same output, (2) values are lazy -- nothing evaluates until needed, (3) everything composes -- functions take **attrsets** (attribute sets, Nix's name for key-value maps) and return attrsets. kix uses Nix's **module system** (originally designed for NixOS configuration) to define typed options and merge configurations from multiple sources.

## The proof of concept: CoreDNS

CoreDNS was the first **kix package**. The goal was simple: define a Kubernetes service the way NixOS defines a system service -- typed options in, manifests out.

Here is a simplified version of what the CoreDNS package looked like:

```nix
# packages/coredns/default.nix
{ lib, pkgs, config, kixlib }:

let
  types = lib.types;
in {
  options.services.coredns = {
    enable = lib.mkOption { type = types.bool; default = false; };
    namespace = lib.mkOption { type = types.str; default = "default"; };
    image = lib.mkOption { type = types.str; default = "coredns/coredns:1.11.1"; };
    replicaCount = lib.mkOption { type = types.int; default = 2; };
    servers = lib.mkOption {
      type = types.listOf (types.submodule { /* zone, port, plugins ... */ });
    };
  };
}
```

Each option has a **type** and a **default**. If you pass `replicaCount = "three"` the module system rejects it before any manifest is generated. That alone removes an entire class of bugs that Helm silently propagates.

## The builder pattern: kixlib

Options define *what* you want. The next question is how those options become Kubernetes resources. The original **kixlib** used `lib.makeExtensible` to create a chainable builder:

```nix
kixlib = lib.makeExtensible (self: {
  withMetadata = metadata: self.extend (...);
  withPreprocessor = preprocessor: self.extend (...);
  mkDeployment = { name, spec, ... }: /* builds a K8s Deployment manifest */;
  mkService = { name, spec, ... }: /* builds a K8s Service manifest */;
});
```

**`lib.makeExtensible`** is a Nix pattern that gives you an object you can extend without mutating. Each `.extend` call returns a new copy with the modification applied. So the CoreDNS implementation could do something like:

```nix
kixlib
  .withMetadata { namespace = cfg.namespace; }
  .mkDeployment {
    name = "coredns";
    spec = {
      replicas = cfg.replicaCount;
      containers = [{
        name = "coredns";
        image = cfg.image;
      }];
    };
  }
```

The builder carries metadata forward. You set the namespace once and every resource inherits it. You cannot forget it on one resource and remember it on another.

## What this buys you

The key property is that packages can **reference each other's outputs**. If a monitoring package needs the CoreDNS service's cluster IP, it queries the CoreDNS module's evaluated config rather than hard-coding a string. The dependency is explicit, type-checked, and evaluated lazily -- the monitoring package does not need to know *when* CoreDNS is evaluated, only that the value will exist.

This is the fundamental difference from Helm. A Helm chart is a closed box: values go in, YAML comes out, and no other chart can see inside. A kix package is an open expression: its outputs are part of a shared, queryable attribute set.

## What comes next

The CoreDNS proof of concept showed that the idea worked. It also showed what was missing: the builder pattern was verbose, resource cross-references were manual, and there was no way to diff generated manifests against a live cluster. The next post covers how we proved those manifests were actually correct.
