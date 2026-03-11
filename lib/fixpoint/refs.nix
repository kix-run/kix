# Reference tracking for the fixpoint pattern.
#
# A Ref is a value that remembers which resource produced it — the K8s
# equivalent of a Nix string with context. When you write `self.configmap.ref`
# in another resource's spec, the tree walker (resolve.nix) sees the `_type`
# tag and records the dependency automatically.
#
# Tracked strings (`str`) preserve ref metadata through string concatenation.
# Native Nix `${}` interpolation calls `__toString`, which returns a plain
# string and loses tracking. Use `k8s.str` instead when building values that
# go into resource specs.
#
# Example:
#   # BAD: loses tracking (dep on db is invisible to tree walker)
#   value = "postgresql://${db.out.host}:${toString db.out.port}/mydb"
#
#   # GOOD: preserves tracking
#   value = k8s.str [ "postgresql://" db.out.host ":" db.out.port "/mydb" ]

{

  # Creates a reference to a resource output.
  #
  # Arguments:
  #   resource — the source k8s-resource attrset
  #   output   — output name (e.g., "ref", "port", "clusterIP")
  #   value    — the plain value this ref resolves to
  #
  # The returned attrset is tagged with `_type = "k8s-ref"` so the tree walker
  # can detect it. `__toString` is provided for ergonomics in debug contexts,
  # but using `${}` in tracked specs loses dependency info.
  mkRef = resource: output: value: {
    _type = "k8s-ref";
    inherit resource output value;
    __toString = _self: toString value;
  };

  # Tests whether a value is a k8s-ref.
  isRef = v: builtins.isAttrs v && (v._type or "") == "k8s-ref";

  # Tracked string concatenation that preserves ref metadata.
  #
  # Takes a list of parts — each part is either a plain value (string, int)
  # or a Ref. The tree walker resolves tracked strings by concatenating the
  # resolved values and collecting deps from all ref parts.
  #
  # Example:
  #   str [ coredns.ref ":53" ]
  #   # Resolves to "kube-dns:53" with a dep on the coredns Service resource.
  str = parts: {
    _type = "k8s-tracked-str";
    inherit parts;
    # __toString provided for debug contexts (loses tracking).
    __toString =
      _self:
      builtins.concatStringsSep "" (
        map (
          p: if builtins.isAttrs p && (p._type or "") == "k8s-ref" then toString p.value else toString p
        ) parts
      );
  };

  # Tests whether a value is a k8s-tracked-str.
  isTrackedStr = v: builtins.isAttrs v && (v._type or "") == "k8s-tracked-str";

}
