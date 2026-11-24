# Tests for workload cloud identity: the annotation domains the cloud
# flavours declare through `kix.mkImport`, the instance's `cloudIdentity`
# attribute, the mechanisms that render it (`vocab/cloud-identity.nix`),
# `scope.cloudIdentity.bind`, the pod labels and restart stamp the workload
# builders add (`scope/builders.nix`), the refusals in `eval/instance.nix`,
# and external-dns, the first package that binds it.

{
  lib,
  k8s,
  eval,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  containerBase,
  ...
}:

let
  flavor = name: import (../../flavors + "/${name}.nix");
  externalDnsPackage = import ../../../packages/experimental/external-dns;
  secretRefPackage = import ../../../packages/stable/secret-ref;

  helpers = import ../caught.nix { inherit lib; };
  # The evaluator loaded so that a failed assertion does not stop the
  # build, which leaves `diagnostics.failedAssertions` readable.
  evalCaught = helpers.loadCaught ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };
  failedOf =
    modules:
    (evalCaught.buildCluster {
      name = "test";
      inherit modules;
    }).diagnostics.failedAssertions;
  # True when one failed assertion contains every fragment.
  failsWith =
    fragments: modules:
    builtins.any (a: builtins.all (f: lib.hasInfix f (a.message + (a.fix or ""))) fragments) (
      failedOf modules
    );

  scorecardOn = {
    scorecard = {
      enable = true;
      rules.architecture = import ../../rules/architecture.nix { inherit lib; };
    };
  };
  domainFindings =
    cluster:
    builtins.filter (f: lib.hasSuffix "annotationDomainOwnership" (f.rule or "")) (
      (cluster.scorecardReport or { findings = [ ]; }).findings
    );

  # A ConfigMap that carries one annotation under `key`.
  annotated = key: {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "annotated";
          annotations.${key} = "value";
        };
        root = self.cm;
      };
  };

  # A Deployment, a Job, and a CronJob that run as one ServiceAccount, which
  # `bind` decides whether to bind.
  container = containerBase // {
    name = "worker";
    image = "example/worker:1";
  };
  workerPackage =
    {
      bind ? true,
    }:
    {
      meta.version = "test";
      build =
        { self, scope, ... }:
        {
          serviceAccount =
            {
              apiVersion = "v1";
              kind = "ServiceAccount";
              name = "worker";
            }
            |> (if bind then scope.cloudIdentity.bind else lib.id)
            |> scope.mkResource;
          deployment = scope.mkDeployment {
            name = "worker";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec = {
                  serviceAccount = self.serviceAccount;
                  containers = [ container ];
                };
              };
            };
          };
          job = scope.mkJob {
            name = "worker-once";
            spec.template = {
              metadata.labels = scope.selectorLabels;
              spec = {
                serviceAccount = self.serviceAccount;
                restartPolicy = "Never";
                containers = [ container ];
              };
            };
          };
          cronJob = scope.mkCronJob {
            name = "worker-nightly";
            spec = {
              schedule = "0 3 * * *";
              jobTemplate.spec.template = {
                metadata.labels = scope.selectorLabels;
                spec = {
                  serviceAccount = self.serviceAccount;
                  restartPolicy = "Never";
                  containers = [ container ];
                };
              };
            };
          };
          root = self.deployment;
        };
    };

  # The worker on flavour `flavorName`, with `identity` as its cloudIdentity.
  workerOn =
    {
      flavorName,
      identity,
      bind ? true,
    }:
    [
      (flavor flavorName)
      {
        instances.work.worker = {
          package = workerPackage { inherit bind; };
          cloudIdentity = identity;
        };
      }
    ];

  # The worker's ServiceAccount metadata and the pod template metadata of
  # its Deployment, Job, and CronJob.
  rendered =
    modules:
    let
      ms = manifests (mkCluster modules);
    in
    {
      serviceAccount = (byName "worker" (ofKind "ServiceAccount" ms)).metadata;
      deployment = (byName "worker" (ofKind "Deployment" ms)).spec.template.metadata;
      job = (byName "worker-once" (ofKind "Job" ms)).spec.template.metadata;
      cronJob = (byName "worker-nightly" (ofKind "CronJob" ms)).spec.jobTemplate.spec.template.metadata;
      markers = map (m: m.metadata.name) (ofKind "PackageInstance" ms);
    };

  stampOf = r: r.deployment.annotations."checksum/cloud-identity" or null;

  roleArn = "arn:aws:iam::111122223333:role/worker";
  irsa = {
    flavorName = "eks";
    identity.aws.roleArn = roleArn;
  };

  # external-dns on `flavorName` with `extra` merged into the instance.
  externalDnsOn = flavorName: extra: [
    (flavor flavorName)
    (
      { ref, ... }:
      {
        instances.dns.keys = {
          package = secretRefPackage;
          config.keys = [
            "AWS_ACCESS_KEY_ID"
            "AWS_SECRET_ACCESS_KEY"
          ];
        };
        instances.dns.edns = lib.recursiveUpdate {
          package = externalDnsPackage;
          config = {
            provider = "aws";
            policy = "sync";
            txtOwnerId = "test";
          };
        } (extra ref);
      }
    )
  ];
in
{
  # Each cloud flavour declares the annotation domain its webhook reads, so
  # an annotation under it gives no finding. A flavour without one still
  # reports it.
  cloud-identity-flavors-declare-annotation-domains =
    let
      findingsOn =
        name: key:
        domainFindings (mkCluster [
          (flavor name)
          scorecardOn
          { instances.app.writer.package = annotated key; }
        ]);
      cases = {
        eks = "eks.amazonaws.com/role-arn";
        gke = "iam.gke.io/gcp-service-account";
        gke-autopilot = "iam.gke.io/gcp-service-account";
        aks = "azure.workload.identity/client-id";
      };
      silent = lib.mapAttrs findingsOn cases;
      kubeadm = findingsOn "kubeadm" "eks.amazonaws.com/role-arn";
    in
    (lib.all (f: f == [ ]) (builtins.attrValues silent) && builtins.length kubeadm == 1)
    || throw "annotation domains: flavours ${builtins.toJSON silent}, kubeadm ${builtins.toJSON kubeadm}";

  # An import's annotationDomains need no dependency from the consumer. A
  # managed instance that declares the same domain takes precedence over the
  # import, and two imports that declare one domain are refused.
  cloud-identity-import-annotation-domains =
    let
      declaring = eval.mkImport { annotationDomains = [ "webhook.example.com" ]; };
      importOnly = mkCluster [
        scorecardOn
        {
          instances.platform.webhook.package = declaring;
          instances.app.writer.package = annotated "webhook.example.com/role";
        }
      ];
      managedToo = mkCluster [
        scorecardOn
        {
          instances.platform.webhook.package = declaring;
          instances.platform.operator.package = {
            meta = {
              version = "test";
              annotationDomains = [ "webhook.example.com" ];
              scope = "cluster";
            };
            build =
              { self, scope, ... }:
              {
                cm = scope.mkResource {
                  apiVersion = "v1";
                  kind = "ConfigMap";
                  name = "operator";
                };
                root = self.cm;
              };
          };
          instances.app.writer.package = annotated "webhook.example.com/role";
        }
      ];
      twoImports = mkCluster [
        {
          instances.platform.webhook.package = declaring;
          instances.platform.other.package = declaring;
        }
      ];
      managedFindings = domainFindings managedToo;
    in
    (
      domainFindings importOnly == [ ]
      && builtins.length managedFindings == 1
      && lib.hasInfix "platform/operator" (builtins.head managedFindings).message
      && evalFails twoImports
    )
    || throw "import domains: import only ${builtins.toJSON (domainFindings importOnly)}, managed ${builtins.toJSON managedFindings}, two imports fail ${builtins.toJSON (evalFails twoImports)}";

  # IRSA puts the role ARN and kix.run/cloud-identity on the bound
  # ServiceAccount, makes it depend on the provider's marker, and stamps the
  # pod template of the Deployment, the Job, and the CronJob. Without an
  # identity the ServiceAccount and the pods carry none of it.
  cloud-identity-irsa-renders =
    let
      r = rendered (workerOn irsa);
      none = rendered (workerOn {
        flavorName = "eks";
        identity = null;
      });
      ann = r.serviceAccount.annotations;
    in
    (
      ann."eks.amazonaws.com/role-arn" == roleArn
      &&
        builtins.fromJSON ann.${kixKeys.cloudIdentity} == {
          mechanism = "irsa";
          aws.roleArn = roleArn;
        }
      && lib.hasInfix "requires:" ann.${kixKeys.dependsOn}
      && builtins.elem "cloud-identity" r.markers
      && stampOf r != null
      && r.job.annotations."checksum/cloud-identity" == stampOf r
      && r.cronJob.annotations."checksum/cloud-identity" == stampOf r
      && !(none.serviceAccount.annotations or { } ? "eks.amazonaws.com/role-arn")
      && !(none.serviceAccount.annotations or { } ? ${kixKeys.cloudIdentity})
      && stampOf none == null
    )
    || throw "irsa: ${builtins.toJSON r}; without identity: ${builtins.toJSON none}";

  # With `cluster.flavor.eks.cloudIdentity = "pod-identity"` the
  # ServiceAccount carries only the record, the pods still carry the stamp,
  # and the stamp differs from IRSA's for the same role. The flavour still
  # declares eks.amazonaws.com.
  cloud-identity-eks-pod-identity =
    let
      r = rendered (workerOn irsa ++ [ { cluster.flavor.eks.cloudIdentity = "pod-identity"; } ]);
      findings = domainFindings (mkCluster [
        (flavor "eks")
        scorecardOn
        { cluster.flavor.eks.cloudIdentity = "pod-identity"; }
        { instances.app.writer.package = annotated "eks.amazonaws.com/role-arn"; }
      ]);
    in
    (
      !(r.serviceAccount.annotations ? "eks.amazonaws.com/role-arn")
      &&
        builtins.fromJSON r.serviceAccount.annotations.${kixKeys.cloudIdentity} == {
          mechanism = "eks-pod-identity";
          aws.roleArn = roleArn;
        }
      && stampOf r != null
      && stampOf r != stampOf (rendered (workerOn irsa))
      && findings == [ ]
    )
    || throw "pod identity: ${builtins.toJSON r}; findings ${builtins.toJSON findings}";

  # The stamp follows the declared identity, so a changed role rolls the
  # pods and an unchanged one does not.
  cloud-identity-stamp-follows-identity =
    let
      stampFor =
        arn:
        stampOf (
          rendered (workerOn {
            flavorName = "eks";
            identity.aws.roleArn = arn;
          })
        );
    in
    (stampFor roleArn == stampFor roleArn && stampFor roleArn != stampFor "${roleArn}-2")
    || throw "stamp: ${stampFor roleArn} and ${stampFor "${roleArn}-2"}";

  # GKE direct access renders no Google annotation; a linked Google service
  # account renders iam.gke.io/gcp-service-account. Both stamp the pods.
  cloud-identity-gke-renders =
    let
      direct = rendered (workerOn {
        flavorName = "gke";
        identity.gcp = { };
      });
      email = "worker@my-project.iam.gserviceaccount.com";
      linked = rendered (workerOn {
        flavorName = "gke-autopilot";
        identity.gcp.serviceAccount = email;
      });
    in
    (
      !(direct.serviceAccount.annotations ? "iam.gke.io/gcp-service-account")
      &&
        builtins.fromJSON direct.serviceAccount.annotations.${kixKeys.cloudIdentity} == {
          mechanism = "gke";
          gcp = { };
        }
      && stampOf direct != null
      && linked.serviceAccount.annotations."iam.gke.io/gcp-service-account" == email
      && stampOf linked != stampOf direct
    )
    || throw "gke: direct ${builtins.toJSON direct}; linked ${builtins.toJSON linked}";

  # Entra Workload ID renders the client and tenant on the ServiceAccount
  # and the azure.workload.identity/use label on every pod template.
  cloud-identity-aks-renders =
    let
      clientId = "00000000-0000-0000-0000-000000000001";
      tenantId = "00000000-0000-0000-0000-000000000002";
      r = rendered (workerOn {
        flavorName = "aks";
        identity.azure = { inherit clientId tenantId; };
      });
      labelled = m: (m.labels."azure.workload.identity/use" or null) == "true";
    in
    (
      r.serviceAccount.annotations."azure.workload.identity/client-id" == clientId
      && r.serviceAccount.annotations."azure.workload.identity/tenant-id" == tenantId
      && labelled r.deployment
      && labelled r.job
      && labelled r.cronJob
    )
    || throw "aks: ${builtins.toJSON r}";

  # A self-managed cluster declares its webhook's prefix, and the role ARN
  # lands under it.
  cloud-identity-self-managed-prefix =
    let
      r = rendered [
        (flavor "kubeadm")
        {
          instances.kube-system.cloud-identity.package = eval.mkImport {
            roles = [ "cloudIdentity" ];
            annotationDomains = [ "irsa.example.com" ];
            out.cloudIdentity = kixlib.cloudIdentity.irsa { annotationPrefix = "irsa.example.com"; };
          };
          instances.work.worker = {
            package = workerPackage { };
            cloudIdentity.aws.roleArn = roleArn;
          };
        }
      ];
    in
    (r.serviceAccount.annotations."irsa.example.com/role-arn" == roleArn)
    || throw "self-managed: ${builtins.toJSON r.serviceAccount}";

  # An identity on a cluster without a provider is refused; the same
  # instance builds on eks.
  cloud-identity-refuses-no-provider =
    (
      failsWith [ "this cluster does not configure a cloud identity provider" "kix.flavors.eks" ] (
        workerOn (irsa // { flavorName = "kubeadm"; })
      )
      && failedOf (workerOn irsa) == [ ]
    )
    || throw "no provider: ${
      builtins.toJSON (failedOf (workerOn (irsa // { flavorName = "kubeadm"; })))
    }";

  # An identity for another cloud than the provider's is refused.
  cloud-identity-refuses-wrong-cloud =
    (failsWith [ "cloudIdentity.gcp" "IAM roles for service accounts" ] (workerOn {
      flavorName = "eks";
      identity.gcp = { };
    }))
    || throw "wrong cloud: ${builtins.toJSON (failedOf (workerOn (irsa // { identity.gcp = { }; })))}";

  # Malformed values and two clouds are refused, each naming what is wrong.
  cloud-identity-refuses-malformed-values =
    let
      on =
        flavorName: identity:
        failedOf (workerOn {
          inherit flavorName identity;
        });
      cases = {
        arn = on "eks" { aws.roleArn = "external-dns"; };
        email = on "gke" { gcp.serviceAccount = "external-dns"; };
        client = on "aks" { azure.clientId = "external-dns"; };
        tenant = on "aks" {
          azure = {
            clientId = "00000000-0000-0000-0000-000000000001";
            tenantId = "contoso";
          };
        };
        two = on "eks" {
          aws.roleArn = roleArn;
          gcp = { };
        };
      };
      mentions =
        fragment: failed:
        builtins.length failed == 1 && lib.hasInfix fragment (builtins.head failed).message;
    in
    (
      mentions "not a valid AWS IAM role ARN" cases.arn
      && mentions "not a valid Google service account email address" cases.email
      && mentions "not a valid client ID GUID" cases.client
      && mentions "not a valid tenant ID GUID" cases.tenant
      && mentions "sets more than one cloud (aws and gcp)" cases.two
    )
    || throw "malformed: ${builtins.toJSON cases}";

  # A package that does not bind the identity is refused, and the fix
  # names its ServiceAccount part. The same package with bind builds.
  cloud-identity-refuses-unbound =
    (
      failsWith [
        "does not bind `scope.cloudIdentity` to a ServiceAccount"
        "serviceAccount = scope.mkResource (scope.cloudIdentity.bind"
      ] (workerOn (irsa // { bind = false; }))
      && failedOf (workerOn irsa) == [ ]
    )
    || throw "unbound: ${builtins.toJSON (failedOf (workerOn (irsa // { bind = false; })))}";

  # The escape hatch in the unbound error works: a parts overlay that
  # rebuilds the ServiceAccount with bind satisfies the check and stamps
  # the pods.
  cloud-identity-overlay-binds =
    let
      modules = [
        (flavor "eks")
        {
          instances.work.worker = {
            package = workerPackage { bind = false; };
            cloudIdentity.aws.roleArn = roleArn;
            partsOverlays = [
              (scope: _self: base: {
                serviceAccount = scope.mkResource (
                  scope.cloudIdentity.bind {
                    apiVersion = "v1";
                    kind = "ServiceAccount";
                    name = base.serviceAccount.name;
                  }
                );
              })
            ];
          };
        }
      ];
    in
    (failedOf modules == [ ] && stampOf (rendered modules) != null)
    || throw "overlay: ${builtins.toJSON (failedOf modules)}";

  # external-dns binds the identity on a cloud provider and takes either an
  # identity or the providerCredentials Secret, never neither or both.
  cloud-identity-external-dns-identity-or-secret =
    let
      identity = _: { cloudIdentity.aws.roleArn = roleArn; };
      secret = ref: { deps.providerCredentials = ref.dns.keys; };
      cases = {
        identity = failedOf (externalDnsOn "eks" identity);
        secret = failedOf (externalDnsOn "eks" secret);
        neither = failedOf (externalDnsOn "eks" (_: { }));
        both = failedOf (externalDnsOn "eks" (ref: identity ref // secret ref));
        otherCloud = failedOf (
          externalDnsOn "eks" (_: {
            cloudIdentity.aws.roleArn = roleArn;
            config.provider = "google";
          })
        );
        notCloud = failedOf (
          externalDnsOn "eks" (_: {
            cloudIdentity.aws.roleArn = roleArn;
            config.provider = "inmemory";
          })
        );
      };
      mentions =
        fragment: failed: failed != [ ] && builtins.any (a: lib.hasInfix fragment a.message) failed;
      sa =
        (byName "edns" (ofKind "ServiceAccount" (manifests (mkCluster (externalDnsOn "eks" identity)))))
        .metadata.annotations;
    in
    (
      cases.identity == [ ]
      && cases.secret == [ ]
      && mentions "sets neither `cloudIdentity.aws` nor" cases.neither
      && mentions "Both `cloudIdentity` and" cases.both
      && mentions "calls the Google Cloud API" cases.otherCloud
      && mentions "does not use a cloud identity" cases.notCloud
      && sa."eks.amazonaws.com/role-arn" == roleArn
    )
    || throw "external-dns: ${builtins.toJSON cases}";

  # The removed serviceAccountAnnotations option is refused with its change
  # id and the new setting.
  cloud-identity-external-dns-removed-option =
    let
      failed = failedOf (
        externalDnsOn "eks" (_: {
          cloudIdentity.aws.roleArn = roleArn;
          config.serviceAccountAnnotations."eks.amazonaws.com/role-arn" = roleArn;
        })
      );
    in
    builtins.any (
      a: (a.id or null) == "K0771" && lib.hasInfix "cloudIdentity" (a.message + (a.fix or ""))
    ) failed
    || throw "removed option: ${builtins.toJSON failed}";
}
