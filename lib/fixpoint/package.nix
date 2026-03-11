# Package constructor — the inner fixpoint.
#
# A "K8s package" is a self-referential set of resources. The inner fixpoint
# (lib.fix) lets any resource within a package reference any other resource
# in the same package via `self.*`, and lazy evaluation means only what's
# needed gets computed.
#
# Every package must define a `main` resource — the public interface that
# other packages interact with. The `main` resource carries `requires` that
# pull in the workload and everything behind it. When another package
# references `pkgs.coredns.ref`, it gets the Service name — but
# `pkgs.coredns.closure` includes the Deployment, RBAC, ConfigMap, and
# everything else needed to make that Service work.
#
# Packages expose two override mechanisms:
# - `overrideParts`: swap one resource while everything else re-resolves
#   (inner fixpoint override — like nixpkgs `overrideAttrs`)
# - `override`: change package arguments (namespace, image, replicas)
#   (argument override — like nixpkgs `override`)

{ lib }:

rec {

  # Creates a K8s package from a package function and default arguments.
  #
  # packageFn: args -> self -> { ... resources ..., main = ... }
  #   - args: the package arguments (namespace, image, replicas, etc.)
  #   - self: the fixed point — lets resources reference each other
  #   - must define a `main` resource (the public interface)
  #
  # defaults: the default values for package arguments
  #
  # Returns the fixed-point attrset with additional package-level operations.
  mkPackage =
    packageFn: defaults:
    let
      parts = lib.fix (packageFn defaults);
    in
    parts
    // {
      _type = "k8s-package";

      # The public interface — what other packages see.
      # Throws if the package forgot to define `main`.
      main = parts.main or (throw "Package must define a 'main' resource");

      # Shortcuts: pkg.ref = pkg.main.ref, pkg.out = pkg.main.out
      ref = parts.main.ref;
      out = parts.main.out;

      # Closure rooted at main — this is what you deploy.
      closure = parts.main.closure;

      # Cherry-pick closure from a different root (for partial deploys).
      # Example: pkgs.coredns.closureOf pkgs.coredns.serviceAccount
      closureOf = resource: resource.closure;

      # Override individual parts (inner fixpoint).
      #
      # overrideFn: self -> super -> { ... overridden parts ... }
      #   - self: the NEW fixed point (after override)
      #   - super: the original parts (before override)
      #
      # Example: swap Deployment to StatefulSet while keeping everything else:
      #   pkgs.coredns.overrideParts (self: super: {
      #     workload = k8s.mkResource { kind = "StatefulSet"; ... };
      #   })
      overrideParts =
        overrideFn:
        mkPackage (
          args: self:
          let
            base = packageFn args self;
          in
          base // (overrideFn self base)
        ) defaults;

      # Override package arguments (namespace, image, replicas, etc.).
      #
      # Example:
      #   pkgs.coredns.override { namespace = "staging"; replicas = 1; }
      override = newArgs: mkPackage packageFn (defaults // newArgs);
    };

}
