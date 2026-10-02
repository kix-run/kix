# The compiler's closed vocabulary of structural rules that a package may
# explicitly opt out of.
#
# Mirrors the role registry's philosophy (eval/roles.nix): the vocabulary is
# closed on purpose so a typo'd grant throws instead of silently never
# matching. A package opts out with a single declared line
# (`meta.unsafe = [ "raw-pvc" ]`); the grant is validated when the package's
# scope is constructed and surfaced by the scorecard's
# `architecture.unsafeGrants` audit rule, keeping unsafe grants visible in
# review without producing a warning for the waived rule.
#
# Each grant requires a rule that enforces its absence.

{ lib }:

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
    "lossy-option-defaults" = {
      description = "may declare options whose default an instance value that sets part of the option discards";
      rationale = ''
        Instance evaluation refuses a package whose options break the
        option contract (eval/options.nix): an untyped or `attrsOf` option
        with a non-empty attrset default, or a submodule default its fields
        do not repeat. The module system replaces such a default as a whole,
        so an instance that sets one key loses the others. The grant keeps
        a package that has not been retyped yet usable; its instances must
        set each such option in full. Legitimate holders: none. A holder
        should be retyped with submodules and `kix.options.*`.
      '';
    };
  };

  grantNames = builtins.attrNames registry;

  knownGrantsHint = "Known unsafe grants: ${builtins.concatStringsSep ", " grantNames}";

  # Validate a grant name; `context` names the declaration site for the error.
  assertKnownGrant =
    context: grant:
    if registry ? ${grant} then
      grant
    else
      throw (
        "kix: unknown unsafe grant '${grant}' (${context}). ${knownGrantsHint}. "
        + "Use a supported grant from this list, or remove the entry from meta.unsafe."
      );
}
