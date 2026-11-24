# Shared helper namespace for cluster definitions, package evaluation, and tests.
# Import this module to include composition, availability, and pin helpers.
{ lib }:
let
  compose = import ./compose.nix { inherit lib; };
  durations = import ./durations.nix { inherit lib; };
  storageClass = import ./storage-class.nix { inherit lib; };
  snapshotClass = import ./snapshot-class.nix { inherit lib; };
  toleration = import ./toleration.nix { inherit lib; };
  cloudIdentity = import ./cloud-identity.nix { inherit lib; };
  versions = import ../core/version.nix { inherit lib; };
  availability = import ../core/availability.nix { inherit lib; };
  scorecard = import ../scorecard.nix { inherit lib; };
  quotaUse = import ./quota-use.nix { inherit lib; };
  errors = import ../core/error.nix { inherit lib; };
in
compose
// {
  types =
    compose.types
    // durations.types
    // {
      # Define a StorageClass submodule option (`vocab/storage-class.nix`).
      storageClass = storageClass.type;
      # Define a VolumeSnapshotClass submodule option (`vocab/snapshot-class.nix`).
      volumeSnapshotClass = snapshotClass.type;
      # Define a pod toleration submodule option (`vocab/toleration.nix`).
      toleration = toleration.type;
    };
  storage = {
    # Render StorageClasses from `kix.types.storageClass` values and pick the
    # default class for consumers that do not name one (`vocab/storage-class.nix`).
    inherit (storageClass) mkClasses;
    # Check and render a CSI driver's VolumeSnapshotClasses from
    # `kix.types.volumeSnapshotClass` values (`vocab/snapshot-class.nix`).
    inherit (snapshotClass) snapshotClassProblems mkSnapshotClasses;
  };
  # Check `kix.types.toleration` values against the apiserver's rules, and
  # render them for a pod spec (`vocab/toleration.nix`).
  tolerations = {
    inherit (toleration) problems render;
  };
  # Cloud identities: the values a cluster author gives a credentials
  # dependency (`aws`, `gcp`, `azure`), `use`, which a package calls on that
  # dependency, and the mechanisms the `cloudIdentity` role's provider puts in
  # its `out` (`vocab/cloud-identity.nix`).
  cloudIdentity = {
    inherit (cloudIdentity)
      aws
      gcp
      azure
      use
      annotationsFor
      irsa
      eksPodIdentity
      gke
      azureWorkloadId
      ;
  };

  # The contracts in `kix/contracts`, by name, with the experimental ones
  # under `contracts.experimental`.
  contracts = import ../../contracts { inherit lib; };
  # Stop evaluation with an error for a person to fix (`core/error.nix`).
  inherit (errors) fail;
  options = compose.options // {
    oidc = errors.fail {
      id = "K0106";
      message = "kix.options.oidc moved to kix.contracts.oidc.options.";
    };
    mail = errors.fail {
      id = "K0106";
      message = "kix.options.mail moved to kix.contracts.smtp.options.";
    };
  };
  # Compare version strings such as a cluster's `k8sVersion`. Both return
  # null when the version is less precise than the bound. `ofTag` reads the
  # version a tag names, as `kix.image.version` does for an image.
  version = {
    inherit (versions) atLeast atMost ofTag;
  };
  # Map availability levels to replica counts, quorums, and topology spread
  # constraints (`core/availability.nix`). Single-replica workloads set a
  # ceiling of "none" via `availability.max` on the builder call or
  # `meta.availability.max` on the package.
  availability = {
    inherit (availability)
      levels
      pick
      atLeast
      rank
      spreadConstraints
      ;
  };
  # Resolve the effective severity of a scorecard rule for this cluster and
  # namespace, or return null when the scorecard or rule is disabled. Packages
  # use this to replace generic scorecard findings with option-specific advice.
  scorecard.effectiveSeverity =
    {
      clusterConfig,
      rule,
      namespaceName,
      owner ? null,
    }:
    let
      sc = clusterConfig.scorecard or { };
      path = lib.splitString "." rule;
      ruleDef = lib.attrByPath path null (sc.rules or { });
    in
    if !(sc.enable or false) || ruleDef == null then
      null
    else
      scorecard.resolveEffectiveSeverity {
        ruleName = rule;
        rule = ruleDef;
        ruleDefaults = sc.ruleDefaults or { };
        ruleOverrides = sc.ruleOverrides or { };
        maxSeverity = sc.maxSeverity or "error";
        inherit namespaceName owner;
      };
  # Build the usage a CRD's `usesAtLeast` returns: one pod's usage from its
  # containers, a usage times a count, and the sum of several usages
  # (`vocab/quota-use.nix`).
  usage = quotaUse.helpers;
  # Convert Prometheus durations and compute staleness thresholds for scheduled
  # jobs (`vocab/durations.nix`).
  inherit (durations) durations schedules;
  pins = import ./pins.nix {
    inherit lib;
    inherit (compose) image;
  };
}
