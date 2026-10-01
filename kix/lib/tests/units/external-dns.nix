# Tests for dependency resolution around meta.scope = "namespace": an
# instance with that scope is never resolved or activated for a requester in
# another namespace.

{
  mkCluster,
  mkCmPackage,
  manifests,
  ofKind,
  hasName,
  byName,
  evalFails,
  ...
}:

let
  credentialsPackage =
    {
      name,
      scope ? "namespace",
    }:
    mkCmPackage {
      inherit name;
      metaExtra = {
        inherit scope;
        defaultAliases = [ "providerCredentials" ];
      };
    };

  # Records which instance `providerCredentials` resolved to in a ConfigMap,
  # or "none".
  describeDep =
    dep: if dep == null then "none" else "${dep._meta.namespaceName}/${dep._meta.instanceName}";

  optionalConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        providerCredentials ? null,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "consumer";
          extra.data.dep = describeDep providerCredentials;
        };
        root = self.cm;
      };
  };

  requiredConsumer = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        providerCredentials,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "consumer";
          extra.data.dep = describeDep providerCredentials;
        };
        root = self.cm;
      };
  };

  resolvedDep = cluster: (byName "consumer" (ofKind "ConfigMap" (manifests cluster))).data.dep;
in
{
  # Consumer in `edns`, namespace-scoped `providerCredentials` instances only
  # in other namespaces. An optional dep resolves to null and the cluster
  # builds; a required dep fails with the not-found error; a cluster-scoped
  # instance beside two foreign namespace-scoped ones is the one chosen.
  external-dns-optional-dep-skips-namespace-scoped-elsewhere =
    let
      optional = mkCluster [
        {
          instances.edns.consumer.package = optionalConsumer;
          instances.other.creds.package = credentialsPackage { name = "other-creds"; };
        }
      ];
      required = mkCluster [
        {
          instances.edns.consumer.package = requiredConsumer;
          instances.other.creds.package = credentialsPackage { name = "other-creds"; };
        }
      ];
      mixed = mkCluster [
        {
          instances.edns.consumer.package = requiredConsumer;
          instances.other.creds.package = credentialsPackage { name = "other-creds"; };
          instances.third.creds.package = credentialsPackage { name = "third-creds"; };
          instances.shared.creds.package = credentialsPackage {
            name = "shared-creds";
            scope = "cluster";
          };
        }
      ];
    in
    (resolvedDep optional == "none" && evalFails required && resolvedDep mixed == "shared/creds")
    || throw "namespace-scoped candidates elsewhere: optional ${resolvedDep optional}, mixed ${resolvedDep mixed}, required fails ${builtins.toJSON (evalFails required)}";

  # Optional instances answering a required dep of `edns/consumer`: a
  # namespace-scoped one in `other` and a cluster-scoped one in `shared`.
  # Activation picks the cluster-scoped one, as resolution does, and leaves
  # the namespace-scoped one inactive.
  external-dns-pick-optional-skips-namespace-scoped-elsewhere =
    let
      cluster = mkCluster [
        {
          instances.edns.consumer.package = requiredConsumer;
          instances.other.creds = {
            package = credentialsPackage { name = "other-creds"; };
            optional = true;
          };
          instances.shared.creds = {
            package = credentialsPackage {
              name = "shared-creds";
              scope = "cluster";
            };
            optional = true;
          };
        }
      ];
      cms = ofKind "ConfigMap" (manifests cluster);
    in
    (resolvedDep cluster == "shared/creds" && hasName "shared-creds" cms && !(hasName "other-creds" cms))
    || throw "pickOptional with a namespace-scoped optional elsewhere: dep ${resolvedDep cluster}, ConfigMaps ${builtins.toJSON (map (m: m.metadata.name) cms)}";
}
