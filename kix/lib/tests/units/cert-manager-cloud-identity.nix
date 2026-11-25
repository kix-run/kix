# Tests for the cloud identity of the cert-manager controller: the
# `controllerIdentity` dependency of cert-manager, which binds it to the
# controller's ServiceAccount and publishes `out.identityCloud`, and the
# check cluster-issuer makes for each DNS-01 solver that sets no key.
# cert-manager runs as instance `cert-manager` in namespace `cert-manager`.

{
  lib,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  flavor = name: import (../../flavors + "/${name}.nix");
  certManagerPackage = import ../../../packages/experimental/cert-manager;
  issuerPackage = import ../../../packages/experimental/cluster-issuer;
  secretRefPackage = import ../../../packages/stable/secret-ref;
  ci = kixlib.cloudIdentity;

  helpers = import ../caught.nix { inherit lib; };
  # The evaluator loaded so that a failed assertion does not stop the
  # build, which leaves `diagnostics.failedAssertions` readable.
  evalCaught = helpers.loadCaught ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };
  k8s = import ../../core { inherit lib; };
  failedOf =
    modules:
    (evalCaught.buildCluster {
      name = "test";
      inherit modules;
    }).diagnostics.failedAssertions;

  roleArn = "arn:aws:iam::111122223333:role/cert-manager";
  clientId = "00000000-0000-0000-0000-000000000000";
  googleAccount = "cert-manager@my-project.iam.gserviceaccount.com";

  # A DNS-01 solver for each cloud that sets no key.
  keyless = {
    aws.dns01.route53.region = "eu-west-1";
    gcp.dns01.cloudDNS.project = "my-project";
    azure.dns01.azureDNS = {
      subscriptionID = "11111111-1111-1111-1111-111111111111";
      resourceGroupName = "dns";
      hostedZoneName = "example.com";
    };
  };

  # cert-manager on `flavorName` with `identity` (or null) in
  # `controllerIdentity`, a secret-ref `keys` holding the given keys, and a
  # ClusterIssuer `letsencrypt` with `solvers`. `issuerExtra ref` is merged
  # into the issuer instance.
  clusterOn =
    {
      flavorName,
      identity ? null,
      solvers,
      keys ? [ ],
      issuerExtra ? _: { },
    }:
    [
      (flavor flavorName)
      (
        { ref, ... }:
        {
          instances.cert-manager = {
            cert-manager = {
              package = certManagerPackage;
            }
            // lib.optionalAttrs (identity != null) { deps.controllerIdentity = identity; };
            keys = {
              package = secretRefPackage;
              config.keys = keys;
            };
            letsencrypt = {
              package = issuerPackage;
              config.spec.acme = {
                server = "https://acme.example.test/directory";
                email = "platform@example.test";
                inherit solvers;
              };
            }
            // issuerExtra ref;
          };
        }
      )
    ];

  # The controller's ServiceAccount annotations, its pod template metadata,
  # and the instance's `out.identityCloud`.
  controllerOf =
    modules:
    let
      cluster = mkCluster modules;
      ms = manifests cluster;
    in
    {
      serviceAccount = (byName "cert-manager" (ofKind "ServiceAccount" ms)).metadata.annotations or { };
      pod = (byName "cert-manager" (ofKind "Deployment" ms)).spec.template.metadata;
      identityCloud = cluster.instances.cert-manager.cert-manager.out.identityCloud;
    };

  stamped = c: c.pod.annotations or { } ? "checksum/cloud-identity";
in
{
  # On each cloud, the identity lands on the controller's ServiceAccount
  # with `kix.run/cloud-identity`, the controller pod gets the restart stamp
  # (and on Azure the webhook's label), and an issuer whose keyless solver
  # calls the same cloud builds.
  cert-manager-cloud-identity-each-cloud =
    let
      on =
        flavorName: cloud: identity:
        let
          modules = clusterOn {
            inherit flavorName identity;
            solvers = [ keyless.${cloud} ];
          };
        in
        {
          failed = failedOf modules;
          controller = controllerOf modules;
        };
      aws = on "eks" "aws" (ci.aws { inherit roleArn; });
      gcp = on "gke" "gcp" (ci.gcp { serviceAccount = googleAccount; });
      azure = on "aks" "azure" (ci.azure { inherit clientId; });
    in
    (
      aws.failed == [ ]
      && gcp.failed == [ ]
      && azure.failed == [ ]
      && aws.controller.serviceAccount."eks.amazonaws.com/role-arn" == roleArn
      && gcp.controller.serviceAccount."iam.gke.io/gcp-service-account" == googleAccount
      && azure.controller.serviceAccount."azure.workload.identity/client-id" == clientId
      &&
        builtins.all (c: c.controller.serviceAccount ? ${kixKeys.cloudIdentity} && stamped c.controller)
          [
            aws
            gcp
            azure
          ]
      && azure.controller.pod.labels."azure.workload.identity/use" == "true"
      && !(aws.controller.pod.labels ? "azure.workload.identity/use")
      && aws.controller.identityCloud == "aws"
      && gcp.controller.identityCloud == "gcp"
      && azure.controller.identityCloud == "azure"
    )
    || throw "each cloud: ${
      builtins.toJSON {
        inherit aws gcp azure;
      }
    }";

  # Without an identity the controller uses the node's credentials: no
  # annotation, no stamp, `out.identityCloud` null, and a keyless solver for
  # any cloud builds.
  cert-manager-cloud-identity-node-credentials =
    let
      modules = clusterOn {
        flavorName = "eks";
        solvers = [
          keyless.aws
          keyless.gcp
          keyless.azure
        ];
      };
      controller = controllerOf modules;
    in
    (
      failedOf modules == [ ]
      && !(controller.serviceAccount ? ${kixKeys.cloudIdentity})
      && !(controller.serviceAccount ? "eks.amazonaws.com/role-arn")
      && !(stamped controller)
      && controller.identityCloud == null
    )
    || throw "node credentials: ${builtins.toJSON controller}";

  # A keyless solver for another cloud than the controller's identity is
  # refused, naming the solver, the cert-manager instance, and both clouds.
  # A solver that sets a key for that other cloud builds beside it.
  cert-manager-cloud-identity-mismatch =
    let
      aws = ci.aws { inherit roleArn; };
      gcp = ci.gcp { };
      azure = ci.azure { inherit clientId; };
      mismatched =
        flavorName: identity: solver:
        failedOf (clusterOn {
          inherit flavorName identity;
          solvers = [ solver ];
        });
      awsOnGcp = mismatched "eks" aws keyless.gcp;
      gcpOnAzure = mismatched "gke" gcp keyless.azure;
      azureOnAws = mismatched "aks" azure keyless.aws;
      message = builtins.head (map (a: a.message) awsOnGcp);
      keyed = failedOf (clusterOn {
        flavorName = "eks";
        identity = aws;
        keys = [ "key.json" ];
        solvers = [
          {
            dns01.cloudDNS = {
              project = "my-project";
              serviceAccountSecretRef.key = "key.json";
            };
          }
        ];
        issuerExtra = ref: { deps.issuerCredentials = ref.cert-manager.keys; };
      });
    in
    (
      builtins.length awsOnGcp == 1
      && builtins.length gcpOnAzure == 1
      && builtins.length azureOnAws == 1
      && lib.hasInfix "`spec.acme.solvers[0].dns01.cloudDNS`" message
      && lib.hasInfix "`cert-manager/cert-manager`" message
      && lib.hasInfix "to call Google Cloud" message
      && lib.hasInfix "identity for AWS" message
      && keyed == [ ]
    )
    || throw "mismatch: ${
      builtins.toJSON {
        inherit
          awsOnGcp
          gcpOnAzure
          azureOnAws
          keyed
          ;
      }
    }";

  # A solver with static keys from issuerCredentials builds beside a bound
  # controller on each cloud, and renders the Secret's name into the key
  # selectors. Route 53's `auth` uses another ServiceAccount's token, so it
  # is not checked against the controller's identity either.
  cert-manager-cloud-identity-secret-beside-bound-controller =
    let
      withKeys =
        flavorName: identity: keys: solver:
        clusterOn {
          inherit flavorName identity keys;
          solvers = [ solver ];
          issuerExtra = ref: { deps.issuerCredentials = ref.cert-manager.keys; };
        };
      route53Keys = withKeys "eks" (ci.aws { inherit roleArn; }) [ "access-key-id" "secret-access-key" ] {
        dns01.route53 = {
          region = "eu-west-1";
          accessKeyIDSecretRef.key = "access-key-id";
          secretAccessKeySecretRef.key = "secret-access-key";
        };
      };
      cloudDnsKey = withKeys "gke" (ci.gcp { }) [ "key.json" ] {
        dns01.cloudDNS = {
          project = "my-project";
          serviceAccountSecretRef.key = "key.json";
        };
      };
      azureSecret = withKeys "aks" (ci.azure { inherit clientId; }) [ "client-secret" ] {
        dns01.azureDNS = keyless.azure.dns01.azureDNS // {
          clientID = clientId;
          tenantID = clientId;
          clientSecretSecretRef.key = "client-secret";
        };
      };
      route53Auth = clusterOn {
        flavorName = "gke";
        identity = ci.gcp { };
        solvers = [
          {
            dns01.route53 = {
              region = "eu-west-1";
              role = "arn:aws:iam::111122223333:role/dns";
              auth.kubernetes.serviceAccountRef.name = "dns-solver";
            };
          }
        ];
      };
      selector =
        (builtins.head (byName "letsencrypt" (ofKind "ClusterIssuer" (manifests (mkCluster route53Keys))))
        .spec.acme.solvers).dns01.route53.secretAccessKeySecretRef;
    in
    (
      failedOf route53Keys == [ ]
      && failedOf cloudDnsKey == [ ]
      && failedOf azureSecret == [ ]
      && failedOf route53Auth == [ ]
      && !(evalFails (mkCluster cloudDnsKey))
      && !(evalFails (mkCluster azureSecret))
      &&
        selector == {
          name = "keys";
          key = "secret-access-key";
        }
    )
    || throw "Secret beside a bound controller: ${builtins.toJSON selector}";

  # A Secret in cert-manager's controllerIdentity fails the build, and so
  # does a cloud identity in cluster-issuer's issuerCredentials. The same
  # values in the other dependency build.
  cert-manager-cloud-identity-wrong-dependency =
    let
      secretAsIdentity = mkCluster [
        (flavor "eks")
        (
          { ref, ... }:
          {
            instances.cert-manager = {
              keys = {
                package = secretRefPackage;
                config.keys = [ "secret-access-key" ];
              };
              cert-manager = {
                package = certManagerPackage;
                deps.controllerIdentity = ref.cert-manager.keys;
              };
            };
          }
        )
      ];
      identityAsSecret = clusterOn {
        flavorName = "eks";
        solvers = [ keyless.aws ];
        issuerExtra = _: { deps.issuerCredentials = ci.aws { inherit roleArn; }; };
      };
      bound = clusterOn {
        flavorName = "eks";
        identity = ci.aws { inherit roleArn; };
        solvers = [ keyless.aws ];
      };
    in
    (
      evalFails secretAsIdentity
      && evalFails (mkCluster identityAsSecret)
      && !(evalFails (mkCluster bound))
    )
    || throw "expected a Secret in controllerIdentity and an identity in issuerCredentials to fail";
}
