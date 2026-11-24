# gateway-api: the Kubernetes Gateway API (gateway.networking.k8s.io), its
# standard-channel CustomResourceDefinitions and the upstream policy that
# guards them.
#
# Installs the ten CRDs of the standard-channel bundle (crds/, vendored from
# the release's standard-install.yaml): GatewayClass, Gateway, ListenerSet,
# HTTPRoute, GRPCRoute, TLSRoute, TCPRoute, UDPRoute, ReferenceGrant, and
# BackendTLSPolicy. It also installs the bundle's ValidatingAdmissionPolicy
# safe-upgrades.gateway.networking.k8s.io and its binding, which refuse an
# experimental-channel CRD over a standard one and a bundle older than
# v1.7.0. The package runs no workload. A Gateway API implementation, such
# as envoy-gateway-controller or traefik, takes it as a dependency and
# builds its GatewayClass from `out.crds`, and a Gateway package builds its
# Gateway from it.
#
# The instance claims the `gatewayApi` role, so a cluster runs one.
# An environment that installs the CRDs itself (some managed
# Kubernetes offerings do) binds the role `exclusive` and provides it with
# a platform `kix.mkImport { crds = [ ... ]; roles = [ "gatewayApi" ]; }`,
# so this package is refused there at evaluation.
#
# Dependencies: none.
#
#   instances.gateway-system.gateway-api.package = packages.experimental.gateway-api;
#
# A GatewayClass is ready once its controller sets Accepted=True, and a
# Gateway or a ListenerSet once its controller sets Programmed=True. Routes,
# ReferenceGrants, and BackendTLSPolicies report their status per parent
# Gateway rather than in top-level conditions, so they declare no
# readiness.
#
# `out`:
#   out.crds.<Kind>   CRD handles for scope.mkCR, one per kind above.
#   out.version       the Gateway API bundle version, `release`.
#
# Limits: the experimental channel (XListenerSet, XBackendTrafficPolicy,
# XMesh, and the experimental fields of the standard kinds) is not
# installed. The safe-upgrades policy refuses it while the policy exists.
#
# Upgrades: v1.7.0 applies over the v1.6.1 CRDs in place. The stored and
# served versions do not change, and existing Gateways and routes keep
# working. The v1.7.0 safe-upgrades policy refuses any bundle older than
# v1.7.0, so a deploy of an older package stops at its dry run. To go
# back, delete the ValidatingAdmissionPolicyBinding
# safe-upgrades.gateway.networking.k8s.io, then deploy the older package,
# which installs its own binding again. The older CRDs hide fields that
# only v1.7.0 serves, such as an HTTPRoute rule's `retry`, until the
# cluster moves forward again.
#
# Moving to another release: set `release`, move the tag in
# crds/sources.txt, run `uv run scripts/vendor-crds.py gateway-api`,
# compare the policy below with the bundle's
# config/crd/standard/gateway.networking.k8s.io_vap_safeupgrades.yaml, and
# set both `k8s` bounds from the release's crd-validation.yml.

{
  scope,
  lib,
  kix,
}:

let
  # meta.version and out.version read this; crds/sources.txt names the same
  # tag.
  release = "v1.7.0";

  vendored = file: builtins.fromJSON (builtins.readFile ./crds/${file});

  # The apiserver refuses a CRD in a *.k8s.io group without its
  # api-approved.kubernetes.io annotation. The safe-upgrades policy reads
  # the bundle-version and channel annotations, so all three go with the
  # spec.
  crd =
    file: extra:
    let
      upstream = vendored "${file}.gateway.networking.k8s.io.json";
    in
    scope.mkCRD (
      {
        inherit (upstream) spec;
        inherit (upstream.metadata) annotations;
        # No holdsData: Kix treats gateway.networking.k8s.io as a built-in
        # group, decides from each object's shape, and refuses the setting.
      }
      // extra
    );

  # A kind that runs no pods of its own.
  noPods.usesAtLeast = _: { };
  programmed.readiness.condition = {
    type = "Programmed";
    status = "True";
  };

  policyName = "safe-upgrades.gateway.networking.k8s.io";
  bundleAnnotations = {
    "gateway.networking.k8s.io/bundle-version" = release;
    "gateway.networking.k8s.io/channel" = "standard";
  };
  crdRule = {
    apiGroups = [ "apiextensions.k8s.io" ];
    apiVersions = [ "v1" ];
    operations = [
      "CREATE"
      "UPDATE"
    ];
  };
in
{
  meta = {
    version = release;
    description = "Kubernetes Gateway API standard-channel CRDs (gateway.networking.k8s.io)";
    owner = "platform";
    # The role admits one managed claimant per cluster, which keeps a
    # second copy of the cluster-scoped CRDs out.
    roles = [ "gatewayApi" ];
    # The TLSRoute CRD validates with CEL's isIP and the BackendTLSPolicy CRD
    # with the CEL format library. The Kubernetes CEL docs list the IP
    # address library from 1.31 and the format library from 1.32. An older
    # apiserver cannot compile those rules and rejects the CRDs. Upstream
    # tests the CRDs' CEL validation on five minor versions
    # (.github/workflows/crd-validation.yml). Move `supported` with `release`.
    k8s = {
      minVersion = "1.32";
      reason = "The Gateway API ${release} CRDs use CEL validation rules from the format library added in Kubernetes 1.32, so older API servers reject them. Upgrade the cluster to Kubernetes 1.32 or newer and update k8sVersion, or stay on an older version of Kix.";
      supported = {
        minVersion = "1.33";
        maxVersion = "1.37";
        source = "Gateway API's CRD validation CI workflow";
      };
    };
  };

  build =
    { self, ... }:
    {
      crds = {
        gatewayClasses = crd "gatewayclasses" (
          noPods
          // {
            readiness.condition = {
              type = "Accepted";
              status = "True";
            };
          }
        );
        # A Gateway runs the proxy pods its controller creates, so it
        # declares no usage of its own.
        gateways = crd "gateways" programmed;
        listenerSets = crd "listenersets" (noPods // programmed);
        httpRoutes = crd "httproutes" noPods;
        grpcRoutes = crd "grpcroutes" noPods;
        tlsRoutes = crd "tlsroutes" noPods;
        tcpRoutes = crd "tcproutes" noPods;
        udpRoutes = crd "udproutes" noPods;
        referenceGrants = crd "referencegrants" noPods;
        backendTlsPolicies = crd "backendtlspolicies" noPods;
      };

      # The bundle's config/crd/standard/gateway.networking.k8s.io_vap_safeupgrades.yaml,
      # with the expressions copied from the release.
      safeUpgradesPolicy = scope.mkClusterResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingAdmissionPolicy";
        name = policyName;
        annotations = bundleAnnotations;
        spec = {
          failurePolicy = "Fail";
          matchConstraints.resourceRules = [ (crdRule // { resources = [ "*" ]; }) ];
          validations = [
            {
              expression = "object.spec.group != 'gateway.networking.k8s.io' || oldObject == null || ( has(object.metadata.annotations) && object.metadata.annotations.exists(k, k == 'gateway.networking.k8s.io/channel') && object.metadata.annotations['gateway.networking.k8s.io/channel'] == 'standard' ) || ( oldObject != null && has(oldObject.metadata.annotations) && oldObject.metadata.annotations.exists(k, k == 'gateway.networking.k8s.io/channel') && oldObject.metadata.annotations['gateway.networking.k8s.io/channel'] == 'experimental' )";
              message = "Installing experimental CRDs on top of standard channel CRDs is prohibited by default. Uninstall ValidatingAdmissionPolicy safe-upgrades.gateway.networking.k8s.io to install experimental CRDs on top of standard channel CRDs.";
              reason = "Invalid";
            }
            {
              expression = "object.spec.group != 'gateway.networking.k8s.io' || (has(object.metadata.annotations) && object.metadata.annotations.exists(k, k == 'gateway.networking.k8s.io/bundle-version') && !matches(object.metadata.annotations['gateway.networking.k8s.io/bundle-version'], 'v1.[0-6].\\\\d+') && !matches(object.metadata.annotations['gateway.networking.k8s.io/bundle-version'], 'v0'))";
              message = "Installing CRDs with version before v1.7.0 is prohibited by default. Uninstall ValidatingAdmissionPolicy safe-upgrades.gateway.networking.k8s.io to install older versions.";
              reason = "Invalid";
            }
          ];
        };
      };

      safeUpgradesBinding = scope.mkClusterResource {
        apiVersion = "admissionregistration.k8s.io/v1";
        kind = "ValidatingAdmissionPolicyBinding";
        name = policyName;
        annotations = bundleAnnotations;
        spec = {
          policyName = self.safeUpgradesPolicy.out.name;
          validationActions = [ "Deny" ];
          matchResources.resourceRules = [ (crdRule // { resources = [ "customresourcedefinitions" ]; }) ];
        };
      };

      root = {
        resource = self.crds.gateways;
        requires = builtins.attrValues self.crds ++ [ self.safeUpgradesBinding ];
        out =
          kix.contracts.experimental.gatewayApi.check
            "gateway-api ${scope.namespaceName}/${scope.instanceName}"
            {
              version = lib.removePrefix "v" release;
              crds = {
                GatewayClass = self.crds.gatewayClasses;
                Gateway = self.crds.gateways;
                ListenerSet = self.crds.listenerSets;
                HTTPRoute = self.crds.httpRoutes;
                GRPCRoute = self.crds.grpcRoutes;
                TLSRoute = self.crds.tlsRoutes;
                TCPRoute = self.crds.tcpRoutes;
                UDPRoute = self.crds.udpRoutes;
                ReferenceGrant = self.crds.referenceGrants;
                BackendTLSPolicy = self.crds.backendTlsPolicies;
              };
            };
      };
    };
}
