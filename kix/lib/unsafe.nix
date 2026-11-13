# Registry of `meta.unsafe` grants that let a package opt out of specific
# structural or security rules.
#
# Grants are validated when a package's scope is constructed and reported by
# the `architecture.unsafeGrants` scorecard rule.

{ lib }:

let
  inherit (import ./core/error.nix { inherit lib; }) fail;
in
rec {
  registry = {
    "raw-pvc" = {
      description = "may emit raw PersistentVolumeClaim resources from its own build";
      rationale = ''
        Storage is the cluster operator's concern (v2_discussions/63a): PVC
        size, storageClass, and lifecycle compose at the cluster definition,
        not inside consuming packages. The canonical author is the
        `persistent-volume-claim` package; everything else declares a
        `storage` dep. Legitimate holders: the canonical package itself, and
        packages wrapping helm charts that emit PVCs when persistence is
        enabled.
      '';
    };
    "host-network" = {
      description = "may run pods on the host network, PID or IPC namespace";
      rationale = ''
        A CNI agent programs the node's own networking, so it has to see
        the host's namespace: cilium's agent, envoy and operator all run
        with `hostNetwork`. The same holds for a node-level exporter that
        reads host metrics. The alternative was a per-namespace severity
        override in every cluster that installs a CNI through kix, which
        exempts everything else in `kube-system` too. Legitimate holders:
        CNI packages and node-level agents.
      '';
    };
    "run-as-root" = {
      description = "may run containers as root";
      rationale = ''
        Writing the node's CNI configuration, mounting the BPF filesystem
        and loading programs into the kernel all need uid 0, so a CNI
        agent and its init containers cannot pass `security.nonRoot`.
        Legitimate holders: CNI packages, CSI node plugins and node-level
        agents. An application package that trips this rule has a bug, not
        a grant: run it as a non-zero uid instead.
      '';
    };
    "privileged" = {
      description = "may run privileged containers";
      rationale = ''
        Mounting BPF into the kernel, writing sysfs parameters or attaching
        to block devices needs a privileged container, and a CNI or a
        storage driver cannot do its job without one. Legitimate holders:
        CNI packages, CSI node plugins, node-level agents, and operators
        that create privileged pods in their own namespace (tailscale's
        proxies run a privileged init container that enables IP forwarding).
      '';
    };
    "cluster-admin" = {
      description = "may bind a ServiceAccount to cluster-admin or to a ClusterRole that grants every verb on every resource";
      rationale = ''
        A backup and restore tool reads every object in the cluster and
        recreates any kind on restore, including custom resources whose
        CRDs are installed after the package is built, so no rule list
        derived at build time covers it. `security.noClusterAdmin` refuses
        every other binding of that reach. Legitimate holders: cluster-wide
        backup tools such as velero. Anything narrower derives its rules
        with `scope.rbac`.
      '';
    };
  };

  grantNames = builtins.attrNames registry;

  knownGrantsHint = "Known unsafe grants: ${builtins.concatStringsSep ", " grantNames}";

  # Return `grant` if it is in `registry`, or fail with an error naming `context`.
  assertKnownGrant =
    context: grant:
    if registry ? ${grant} then
      grant
    else
      fail {
        option = "meta.unsafe";
        message = "unknown unsafe grant '${grant}' (${context}). ${knownGrantsHint}.";
        fix = "Use a supported grant from this list, or remove the entry from meta.unsafe.";
      };
}
