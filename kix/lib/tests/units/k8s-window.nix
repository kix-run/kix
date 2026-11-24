# Tests for the Kubernetes window of a Kix release (core/kubernetes.nix)
# and for the two ranges of `meta.k8s`.

{
  lib,
  eval,
  mkCluster,
  evalFails,
  ...
}:

let
  inherit (import ../../core/kubernetes.nix) window;
  versions = import ../../core/version.nix { inherit lib; };
  metaLib = import ../../meta.nix { inherit lib; };

  stableDir = ../../../packages/stable;
  stableNames = builtins.attrNames (
    lib.filterAttrs (_: type: type == "directory") (builtins.readDir stableDir)
  );

  # Read a package's `meta` without evaluating its build. `path` is
  # relative to kix/packages, such as "stable/valkey".
  metaAt =
    path:
    let
      name = baseNameOf path;
    in
    (eval.callPackagePhase1 {
      package = import (../../../packages + "/${path}");
      scope = {
        instanceName = name;
        namespaceName = name;
      };
    }).meta;
  metaOf = name: metaAt "stable/${name}";

  # What each package's ranges do at chosen Kubernetes versions. `refuses`
  # names versions outside the hard range and `id` the change record the
  # refusal prints. `warns` names versions the package accepts outside
  # upstream's stated support, and `accepts` versions inside both.
  ranges = {
    "stable/kube-state-metrics" = {
      refuses = [ "1.24" ];
      warns = [
        "1.35"
        "1.37.0"
      ];
      accepts = [ "1.36.4" ];
    };
    "stable/cnpg-operator" = {
      refuses = [ "1.30" ];
      warns = [
        "1.33"
        "1.37"
      ];
      accepts = [
        "1.34"
        "1.36"
      ];
    };
    "experimental/cert-manager" = {
      warns = [
        "1.32"
        "1.37"
      ];
      accepts = [
        "1.33"
        "1.36"
      ];
    };
    "experimental/cilium" = {
      warns = [
        "1.32"
        "1.37"
      ];
      accepts = [
        "1.33"
        "1.36"
      ];
    };
    "experimental/db-operator" = {
      warns = [
        "1.33"
        "1.37"
      ];
      accepts = [
        "1.34"
        "1.36"
      ];
    };
    "experimental/descheduler" = {
      warns = [
        "1.34"
        "1.38"
      ];
      accepts = [
        "1.35"
        "1.37"
      ];
    };
    "experimental/external-secrets" = {
      warns = [
        "1.36"
        "1.38"
      ];
      accepts = [ "1.37" ];
    };
    "experimental/gateway-api" = {
      refuses = [ "1.31" ];
      warns = [
        "1.32"
        "1.38"
      ];
      accepts = [
        "1.33"
        "1.37"
      ];
    };
    "experimental/infisical-operator" = {
      warns = [
        "1.28"
        "1.34"
      ];
      accepts = [
        "1.29"
        "1.33"
      ];
    };
    "experimental/openbao" = {
      warns = [
        "1.34"
        "1.38"
      ];
      accepts = [
        "1.35"
        "1.37"
      ];
    };
    "experimental/traefik" = {
      warns = [
        "1.34"
        "1.38"
      ];
      accepts = [
        "1.35"
        "1.37"
      ];
    };
    "experimental/cdi" = {
      warns = [
        "1.34"
        "1.37"
      ];
      accepts = [
        "1.35"
        "1.36"
      ];
    };
    "experimental/kubevirt" = {
      warns = [
        "1.34"
        "1.38"
      ];
      accepts = [
        "1.35"
        "1.37"
      ];
    };
    "experimental/spegel" = {
      refuses = [ "1.33" ];
      id = "K8826";
      warns = [
        "1.34"
        "1.38"
      ];
      accepts = [
        "1.35"
        "1.37"
      ];
    };
    "experimental/keycloak" = {
      warns = [
        "1.30"
        "1.35.0"
      ];
      accepts = [
        "1.31.2"
        "1.34.0"
      ];
    };
  };

  rangeProblems =
    path: want:
    let
      result =
        k8sVersion:
        metaLib.checkMetaStatic {
          packageMeta = metaAt path;
          instanceName = baseNameOf path;
          namespaceName = "apps";
          clusterConfig = { inherit k8sVersion; };
          resolvedDepMeta = { };
          resolutionIndex.byKey = { };
        };
      refusalsAt = v: map (a: a.message) (builtins.filter (a: !a.assertion) (result v).assertions);
      warningsAt = v: (result v).warnings;
      problem = v: what: {
        ${if v == null then "unset" else v} =
          "${what}: refusals ${builtins.toJSON (refusalsAt v)}, warnings ${builtins.toJSON (warningsAt v)}";
      };
    in
    lib.mergeAttrsList (
      map (
        v:
        lib.optionalAttrs (
          refusalsAt v == [ ] || (want ? id && !(builtins.any (lib.hasInfix "[${want.id}]") (refusalsAt v)))
        ) (problem v "expected a refusal")
      ) (want.refuses or [ ])
      ++ map (
        v:
        lib.optionalAttrs (refusalsAt v != [ ] || builtins.length (warningsAt v) != 1) (
          problem v "expected one warning"
        )
      ) (want.warns or [ ])
      ++ map (
        v: lib.optionalAttrs (refusalsAt v != [ ] || warningsAt v != [ ]) (problem v "expected neither")
      ) ((want.accepts or [ ]) ++ [ null ])
    );

  # Name the window versions that the hard range of `name` refuses.
  refusedInWindow =
    name:
    let
      k8s = (metaOf name).k8s or { };
    in
    builtins.filter
      (
        v:
        (k8s ? minVersion && versions.atLeast v k8s.minVersion == false)
        || (k8s ? maxVersion && versions.atMost v k8s.maxVersion == false)
      )
      (
        lib.unique [
          window.minVersion
          window.maxVersion
        ]
      );

  uncovered = lib.filterAttrs (_: refused: refused != [ ]) (lib.genAttrs stableNames refusedInWindow);

  check =
    k8s: k8sVersion:
    metaLib.checkMetaStatic {
      packageMeta = { inherit k8s; };
      instanceName = "app";
      namespaceName = "apps";
      clusterConfig = { inherit k8sVersion; };
      resolvedDepMeta = { };
      resolutionIndex.byKey = { };
    };
  refusals = k8s: v: builtins.filter (a: !a.assertion) (check k8s v).assertions;
  warnings = k8s: v: (check k8s v).warnings;

  both = {
    minVersion = "1.30";
    reason = "[K0000] the operand reads an API served from 1.30";
    supported = {
      minVersion = "1.35";
      maxVersion = "1.36";
      source = "the upstream support table";
    };
  };
in
lib.mapAttrs' (
  path: want:
  lib.nameValuePair "k8s-range-${baseNameOf path}" (
    rangeProblems path want == { }
    || throw "k8s-range-${baseNameOf path}: ${builtins.toJSON (rangeProblems path want)}"
  )
) ranges
// {
  # A stable package that refuses a version in the window would stop every
  # cluster on that version, so the bump that narrows a range fails here.
  k8s-window-stable-packages-cover-it =
    uncovered == { }
    || throw "these stable packages refuse a Kubernetes version in the window ${window.minVersion} to ${window.maxVersion}: ${builtins.toJSON uncovered}. Make the package work on it, hold the bump, or move the window in core/kubernetes.nix with a change record.";

  # Outside `supported` the build passes with one warning that names
  # upstream's range and its source. Outside the hard range it is refused.
  k8s-supported-range-warns =
    let
      above = warnings both "1.37";
      below = warnings both "1.34";
    in
    (
      refusals both "1.37" == [ ]
      && builtins.length above == 1
      && lib.hasInfix "1.35 to 1.36" (builtins.head above)
      && lib.hasInfix "the upstream support table" (builtins.head above)
      && builtins.length below == 1
      && warnings both "1.36" == [ ]
      && warnings both null == [ ]
      && builtins.length (refusals both "1.29") == 1
    )
    || throw "k8s-supported-range-warns: 1.37 ${builtins.toJSON above}, 1.34 ${builtins.toJSON below}, 1.29 ${builtins.toJSON (refusals both "1.29")}";

  # A cluster on a version this release does not support is warned once,
  # and a package warns for itself where upstream states no support. Both
  # reach `cluster.diagnostics.warnings`, which `kix check` prints.
  k8s-window-cluster-warnings =
    let
      clusterOn =
        k8sVersion:
        mkCluster [
          {
            inherit k8sVersion;
            instances.monitoring.kube-state-metrics.package = import ../../../packages/stable/kube-state-metrics;
          }
        ];
      messagesOn = v: map (w: w.message) (clusterOn v).diagnostics.warnings;
      has = needle: builtins.any (lib.hasInfix needle);
      about = builtins.filter (m: lib.hasInfix "Kubernetes" m);
    in
    (
      about (messagesOn "1.36") == [ ]
      && has "the upstream project supports or tests Kubernetes 1.36 only" (messagesOn "1.37")
      && !(has "This Kix release supports" (messagesOn "1.37"))
      && has "This Kix release supports Kubernetes ${window.minVersion} to ${window.maxVersion}" (
        messagesOn "1.38"
      )
      && has "upstream project supports or tests Kubernetes 1.36 only" (messagesOn "1.35")
      && evalFails (clusterOn "1.24")
    )
    || throw "k8s-window-cluster-warnings: 1.36 ${builtins.toJSON (messagesOn "1.36")}, 1.37 ${builtins.toJSON (messagesOn "1.37")}, 1.38 ${builtins.toJSON (messagesOn "1.38")}";

  # kube-state-metrics turns off the collectors whose API the cluster's
  # Kubernetes does not serve, and its ClusterRole drops the same kinds. On
  # a version that serves them all, and with no version, it passes no
  # `--resources` and keeps upstream's default.
  k8s-window-kube-state-metrics-collectors =
    let
      objectsOn =
        k8sVersion:
        (mkCluster [
          {
            inherit k8sVersion;
            instances.monitoring.kube-state-metrics.package = import ../../../packages/stable/kube-state-metrics;
          }
        ]).rawManifests;
      only = kind: ms: builtins.head (builtins.filter (m: m.kind == kind) ms);
      resourcesFlag =
        v:
        let
          args = (builtins.head (only "Deployment" (objectsOn v)).spec.template.spec.containers).args;
          flags = builtins.filter (lib.hasPrefix "--resources=") args;
        in
        if flags == [ ] then
          null
        else
          lib.splitString "," (lib.removePrefix "--resources=" (builtins.head flags));
      granted = v: builtins.concatMap (r: r.resources or [ ]) (only "ClusterRole" (objectsOn v)).rules;
      mutating = "mutatingadmissionpolicies";
      validating = "validatingadmissionpolicies";
    in
    (
      resourcesFlag "1.36" == null
      && resourcesFlag null == null
      && builtins.elem mutating (granted "1.36")
      && builtins.elem mutating (granted null)
      && !(builtins.elem mutating (resourcesFlag "1.35"))
      && builtins.elem validating (resourcesFlag "1.35")
      && builtins.elem "pods" (resourcesFlag "1.35")
      && !(builtins.elem mutating (granted "1.35"))
      && builtins.elem validating (granted "1.35")
      && !(builtins.elem validating (resourcesFlag "1.29"))
      && !(builtins.elem validating (granted "1.29"))
    )
    || throw "kube-state-metrics collectors: 1.35 ${builtins.toJSON (resourcesFlag "1.35")}, 1.29 ${builtins.toJSON (resourcesFlag "1.29")}, 1.36 ${builtins.toJSON (resourcesFlag "1.36")}, role on 1.35 ${builtins.toJSON (granted "1.35")}";

  # A `supported` bound that is not a version is the author's error.
  k8s-supported-range-malformed-fails =
    builtins.length (refusals { supported.maxVersion = "latest"; } "1.36") == 1
    || throw "a malformed meta.k8s.supported bound was accepted";
}
