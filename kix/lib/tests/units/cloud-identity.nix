# Tests for workload cloud identity: the annotation domains the cloud
# flavours declare through `kix.mkImport`, the identity values a cluster
# author gives a credentials dependency (`kix.cloudIdentity.aws`, `gcp`,
# `azure`), `kix.cloudIdentity.use`, the mechanisms that render an identity
# (`vocab/cloud-identity.nix`), the rendering in `sealResource` and the pod
# labels and restart stamp the workload builders add (`scope/builders.nix`),
# and external-dns, the first package that takes one.

{
  lib,
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
  ci = kixlib.cloudIdentity;
  vocab = import ../../vocab/cloud-identity.nix { inherit lib; };

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

  # A scope whose `fail` returns the error record, so a test reads the
  # message `use` raises.
  recordingScope = {
    fail = e: { failed = e; };
  };
  # The message and fix `use` raises for `dep` and `cloud`, or "".
  useFailure =
    dep: cloud:
    let
      r = ci.use {
        scope = recordingScope;
        inherit dep cloud;
      };
    in
    if r ? failed then r.failed.message + " " + (r.failed.fix or "") else "";

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

  container = containerBase // {
    name = "worker";
    image = "example/worker:1";
  };

  # A Deployment, a Job, and a CronJob that run as one ServiceAccount. The
  # `credentials` dependency holds a Secret instance or a cloud identity for
  # `cloud`.
  workerPackage =
    { cloud }:
    {
      meta.version = "test";
      build =
        {
          self,
          scope,
          credentials ? null,
          ...
        }:
        let
          creds = kixlib.cloudIdentity.use {
            inherit scope cloud;
            dep = credentials;
          };
          podSpec = {
            serviceAccount = self.serviceAccount;
            containers = [ container ];
          };
        in
        {
          serviceAccount =
            {
              apiVersion = "v1";
              kind = "ServiceAccount";
              name = "worker";
            }
            |> creds.bind
            |> scope.mkResource;
          deployment = scope.mkDeployment {
            name = "worker";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec = podSpec;
              };
            };
          };
          job = scope.mkJob {
            name = "worker-once";
            spec.template = {
              metadata.labels = scope.selectorLabels;
              spec = podSpec // {
                restartPolicy = "Never";
              };
            };
          };
          cronJob = scope.mkCronJob {
            name = "worker-nightly";
            spec = {
              schedule = "0 3 * * *";
              jobTemplate.spec.template = {
                metadata.labels = scope.selectorLabels;
                spec = podSpec // {
                  restartPolicy = "Never";
                };
              };
            };
          };
          root = self.deployment;
        };
    };

  # The same worker written before cloud identity: it takes no credentials
  # dependency.
  plainWorker = {
    meta.version = "test";
    build =
      { self, scope, ... }:
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "worker";
        };
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
        root = self.deployment;
      };
  };

  # The worker on flavour `flavorName`, with `identity` (or null) as its
  # credentials. `cloud` defaults to the identity's.
  workerOn =
    {
      flavorName,
      identity,
      cloud ? identity.cloud,
      extra ? { },
    }:
    [
      (flavor flavorName)
      extra
      {
        instances.work.worker = {
          package = workerPackage { inherit cloud; };
        }
        // lib.optionalAttrs (identity != null) { deps.credentials = identity; };
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
    identity = ci.aws { inherit roleArn; };
  };

  # external-dns on `flavorName` with `extra ref` merged into the instance.
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
        cloud = "aws";
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
      r = rendered (workerOn (irsa // { extra.cluster.flavor.eks.cloudIdentity = "pod-identity"; }));
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
            identity = ci.aws { roleArn = arn; };
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
        identity = ci.gcp { };
      });
      email = "worker@my-project.iam.gserviceaccount.com";
      linked = rendered (workerOn {
        flavorName = "gke-autopilot";
        identity = ci.gcp { serviceAccount = email; };
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
        identity = ci.azure { inherit clientId tenantId; };
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
      r = rendered (
        workerOn (
          irsa
          // {
            flavorName = "kubeadm";
            extra.instances.kube-system.cloud-identity.package = eval.mkImport {
              roles = [ "cloudIdentity" ];
              annotationDomains = [ "irsa.example.com" ];
              out.cloudIdentity = ci.irsa { annotationPrefix = "irsa.example.com"; };
            };
          }
        )
      );
    in
    (r.serviceAccount.annotations."irsa.example.com/role-arn" == roleArn)
    || throw "self-managed: ${builtins.toJSON r.serviceAccount}";

  # A package with two ServiceAccounts takes two dependencies, and each
  # ServiceAccount gets its own role and each pod its own stamp.
  cloud-identity-two-service-accounts =
    let
      saAndPod = name: creds: scope: self: {
        "${name}Sa" =
          {
            apiVersion = "v1";
            kind = "ServiceAccount";
            inherit name;
          }
          |> creds.bind
          |> scope.mkResource;
        ${name} = scope.mkDeployment {
          inherit name;
          spec = {
            selector.matchLabels = scope.selectorLabels // {
              app = name;
            };
            template = {
              metadata.labels = scope.selectorLabels // {
                app = name;
              };
              spec = {
                serviceAccount = self."${name}Sa";
                containers = [ container ];
              };
            };
          };
        };
      };
      twoPackage = {
        meta.version = "test";
        build =
          {
            self,
            scope,
            dnsCredentials,
            storageCredentials,
            ...
          }:
          let
            use =
              dep:
              kixlib.cloudIdentity.use {
                inherit scope dep;
                cloud = "aws";
              };
          in
          saAndPod "dns" (use dnsCredentials) scope self
          // saAndPod "storage" (use storageCredentials) scope self
          // {
            root = self.dns;
          };
      };
      ms = manifests (mkCluster [
        (flavor "eks")
        {
          instances.work.two = {
            package = twoPackage;
            deps = {
              dnsCredentials = ci.aws { roleArn = "${roleArn}-dns"; };
              storageCredentials = ci.aws { roleArn = "${roleArn}-storage"; };
            };
          };
        }
      ]);
      arnOf =
        n: (byName n (ofKind "ServiceAccount" ms)).metadata.annotations."eks.amazonaws.com/role-arn";
      stampOfDeploy =
        n: (byName n (ofKind "Deployment" ms)).spec.template.metadata.annotations."checksum/cloud-identity";
    in
    (
      arnOf "dns" == "${roleArn}-dns"
      && arnOf "storage" == "${roleArn}-storage"
      && stampOfDeploy "dns" != stampOfDeploy "storage"
    )
    || throw "two ServiceAccounts: ${builtins.toJSON (ofKind "ServiceAccount" ms)}";

  # `annotationsFor` gives an operator-made ServiceAccount the annotations
  # and pod labels `bind` would write, read through the role's provider.
  cloud-identity-annotations-for-operator =
    let
      operatorPackage = {
        meta.version = "test";
        build =
          {
            self,
            scope,
            credentials,
            cloudIdentity,
            ...
          }:
          let
            a = kixlib.cloudIdentity.annotationsFor {
              inherit scope;
              identity = credentials;
              provider = cloudIdentity;
            };
          in
          {
            cm = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "operator-template";
              data = a.serviceAccountAnnotations // a.podLabels;
            };
            root = self.cm;
          };
      };
      data =
        (byName "operator-template" (
          ofKind "ConfigMap" (
            manifests (mkCluster [
              (flavor "aks")
              {
                instances.work.op = {
                  package = operatorPackage;
                  deps.credentials = ci.azure { clientId = "00000000-0000-0000-0000-000000000001"; };
                };
              }
            ])
          )
        )).data;
    in
    (
      data."azure.workload.identity/client-id" == "00000000-0000-0000-0000-000000000001"
      && data."azure.workload.identity/use" == "true"
      && data ? ${kixKeys.cloudIdentity}
    )
    || throw "annotationsFor: ${builtins.toJSON data}";

  # A Secret instance in the credentials dependency is handed back as
  # `secret`, and `bind` leaves the ServiceAccount unchanged.
  cloud-identity-use-passes-a-secret =
    let
      secret = {
        out.name = "keys";
      };
      r = ci.use {
        scope = recordingScope;
        dep = secret;
        cloud = "aws";
      };
    in
    (r.secret == secret && r.identity == null && r.bind { a = 1; } == { a = 1; })
    || throw "use with a Secret: ${builtins.toJSON (removeAttrs r [ "bind" ])}";

  # An identity on a cluster without a provider is refused; the same
  # instance builds on eks.
  cloud-identity-refuses-no-provider =
    let
      problem =
        (vocab.render {
          identity = ci.aws { inherit roleArn; };
          provider = null;
        }).problem;
    in
    (
      evalFails (mkCluster (workerOn (irsa // { flavorName = "kubeadm"; })))
      && !(evalFails (mkCluster (workerOn irsa)))
      && lib.hasInfix "has no `cloudIdentity` provider" problem.message
      && lib.hasInfix "kix.flavors.eks" problem.fix
    )
    || throw "no provider: ${builtins.toJSON problem}";

  # An identity for another cloud than the provider's is refused, with one
  # message that names the provider's mechanism.
  cloud-identity-refuses-wrong-cloud-for-cluster =
    let
      problem =
        (vocab.render {
          identity = ci.gcp { };
          provider = {
            ns = "kube-system";
            inst = "cloud-identity";
            out.cloudIdentity = ci.irsa { };
          };
        }).problem;
    in
    (
      evalFails (
        mkCluster (workerOn {
          flavorName = "eks";
          identity = ci.gcp { };
        })
      )
      && !(evalFails (mkCluster (workerOn irsa)))
      && lib.hasInfix "IAM roles for service accounts" problem.message
    )
    || throw "wrong cloud for the cluster: ${builtins.toJSON problem}";

  # An identity for another cloud than the package's software calls is
  # refused by `use`, before the cluster's provider is read, so the user
  # sees one error. A package that takes no cloud identity refuses any.
  cloud-identity-refuses-wrong-cloud-for-package =
    let
      other = useFailure (ci.gcp { }) "aws";
      none = useFailure (ci.aws { inherit roleArn; }) null;
    in
    (
      lib.hasInfix "call the AWS API" other
      && lib.hasInfix "does not accept for its current configuration" none
      && useFailure (ci.aws { inherit roleArn; }) "aws" == ""
      && evalFails (
        mkCluster (workerOn {
          flavorName = "gke";
          identity = ci.gcp { };
          cloud = "aws";
        })
      )
    )
    || throw "wrong cloud for the package: ${other}; ${none}";

  # Malformed values and mistyped fields are refused, each naming the
  # field. A well-formed value of each cloud passes.
  cloud-identity-refuses-malformed-values =
    let
      cases = {
        arn = useFailure (ci.aws { roleArn = "external-dns"; }) "aws";
        email = useFailure (ci.gcp { serviceAccount = "external-dns"; }) "gcp";
        client = useFailure (ci.azure { clientId = "external-dns"; }) "azure";
        tenant = useFailure (ci.azure {
          clientId = "00000000-0000-0000-0000-000000000001";
          tenantId = "contoso";
        }) "azure";
        typo = useFailure (ci.aws { rolearn = roleArn; }) "aws";
        missing = useFailure (ci.azure { }) "azure";
        notText = useFailure (ci.aws { roleArn = 1; }) "aws";
      };
      good = [
        (useFailure (ci.aws { inherit roleArn; }) "aws")
        (useFailure (ci.gcp { }) "gcp")
        (useFailure (ci.azure { clientId = "00000000-0000-0000-0000-000000000001"; }) "azure")
      ];
    in
    (
      lib.hasInfix "field `roleArn`" cases.arn
      && lib.hasInfix "not a valid AWS IAM role ARN" cases.arn
      && lib.hasInfix "field `serviceAccount`" cases.email
      && lib.hasInfix "field `clientId`" cases.client
      && lib.hasInfix "field `tenantId`" cases.tenant
      && lib.hasInfix "no field `rolearn`" cases.typo
      && lib.hasInfix "missing required field `clientId`" cases.missing
      && lib.hasInfix "must be a string" cases.notText
      &&
        good == [
          ""
          ""
          ""
        ]
      && evalFails (
        mkCluster (workerOn {
          flavorName = "eks";
          identity = ci.aws { rolearn = roleArn; };
          cloud = "aws";
        })
      )
    )
    || throw "malformed: ${builtins.toJSON cases}";

  # A package that takes no credentials dependency refuses one with the
  # existing unknown-dependency error. The raw annotation in a parts
  # overlay still works for it, and the scorecard accepts the annotation.
  cloud-identity-unadopted-package =
    let
      unadopted = mkCluster [
        (flavor "eks")
        {
          instances.work.worker = {
            package = plainWorker;
            deps.credentials = ci.aws { inherit roleArn; };
          };
        }
      ];
      overlaid = mkCluster [
        (flavor "eks")
        scorecardOn
        {
          instances.work.worker = {
            package = plainWorker;
            partsOverlays = [
              (scope: _self: base: {
                serviceAccount = scope.mkResource {
                  apiVersion = "v1";
                  kind = "ServiceAccount";
                  name = base.serviceAccount.name;
                  annotations."eks.amazonaws.com/role-arn" = roleArn;
                };
              })
            ];
          };
        }
      ];
      sa = byName "worker" (ofKind "ServiceAccount" (manifests overlaid));
    in
    (
      evalFails unadopted
      && sa.metadata.annotations."eks.amazonaws.com/role-arn" == roleArn
      && domainFindings overlaid == [ ]
    )
    || throw "unadopted: ${builtins.toJSON sa}";

  # external-dns takes an identity or a Secret in providerCredentials, and
  # refuses neither on a provider that calls a cloud. An identity for
  # another cloud, or on a provider that takes none, fails evaluation.
  cloud-identity-external-dns-identity-or-secret =
    let
      identity = _: { deps.providerCredentials = ci.aws { inherit roleArn; }; };
      secret = ref: { deps.providerCredentials = ref.dns.keys; };
      neither = failedOf (externalDnsOn "eks" (_: { }));
      sa =
        (byName "edns" (ofKind "ServiceAccount" (manifests (mkCluster (externalDnsOn "eks" identity)))))
        .metadata.annotations;
      secretDeploy = byName "edns" (
        ofKind "Deployment" (manifests (mkCluster (externalDnsOn "eks" secret)))
      );
      container0 = builtins.head secretDeploy.spec.template.spec.containers;
    in
    (
      failedOf (externalDnsOn "eks" identity) == [ ]
      && failedOf (externalDnsOn "eks" secret) == [ ]
      && builtins.any (a: (a.id or null) == "K1798") neither
      && sa."eks.amazonaws.com/role-arn" == roleArn
      && container0 ? envFrom
      && !(secretDeploy.spec.template.metadata.annotations or { } ? "checksum/cloud-identity")
      && evalFails (
        mkCluster (
          externalDnsOn "eks" (_: {
            deps.providerCredentials = ci.aws { inherit roleArn; };
            config.provider = "google";
          })
        )
      )
      && evalFails (
        mkCluster (
          externalDnsOn "eks" (_: {
            deps.providerCredentials = ci.aws { inherit roleArn; };
            config.provider = "inmemory";
          })
        )
      )
    )
    || throw "external-dns: neither ${builtins.toJSON neither}";

  # The removed serviceAccountAnnotations option is refused with its change
  # id and the new setting.
  cloud-identity-external-dns-removed-option =
    let
      failed = failedOf (
        externalDnsOn "eks" (_: {
          deps.providerCredentials = ci.aws { inherit roleArn; };
          config.serviceAccountAnnotations."eks.amazonaws.com/role-arn" = roleArn;
        })
      );
    in
    builtins.any (
      a: (a.id or null) == "K0771" && lib.hasInfix "kix.cloudIdentity.aws" (a.message + (a.fix or ""))
    ) failed
    || throw "removed option: ${builtins.toJSON failed}";
}
