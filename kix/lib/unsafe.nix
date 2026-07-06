# The unsafe-grant registry — the compiler's closed vocabulary of structural
# authoring rules a package may explicitly opt out of (v2_discussions/128).
#
# Mirrors the role registry's philosophy (eval/roles.nix): the vocabulary is
# closed on purpose so a typo'd grant throws instead of silently never
# matching. A package opts out with a single declared line
# (`meta.unsafe = [ "raw-pvc" ]`); the grant is validated when the package's
# scope is constructed and surfaced by the scorecard's
# `architecture.unsafeGrants` audit rule — an unsafe grant is never invisible
# in review, it just isn't a warning to dismiss.
#
# Adding a grant here requires a rule that enforces its absence (doc 119's
# demand test applies: no speculative vocabulary).

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
        + "The unsafe vocabulary is closed — a new grant is added to kix/lib/unsafe.nix together with the rule it escapes (v2_discussions/128)."
      );
}
