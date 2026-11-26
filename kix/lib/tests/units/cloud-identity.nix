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
  publicKix,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  containerBase,
  netpolOn,
  ...
}:

let
  flavor = name: import (../../flavors + "/${name}.nix");
  externalDnsPackage = import ../../../packages/experimental/external-dns;
  secretRefPackage = import ../../../packages/stable/secret-ref;
  ci = kixlib.cloudIdentity;
  vocab = import ../../vocab/cloud-identity.nix { inherit lib; };
  mechanisms = import ../../vocab/cloud-identity-mechanisms.nix { inherit lib; };

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

  # The result of `useIdentity` for `args`, with `bind` applied to an empty
  # set, or the message and fix it raises as `failure`.
  useIdentityResult =
    args:
    let
      r = ci.useIdentity (
        {
          scope = recordingScope;
          secretGoesTo = "`deps.storageCredentials` of the storage instance";
        }
        // args
      );
    in
    if r ? failed then
      { failure = r.failed.message + " " + (r.failed.fix or ""); }
    else
      {
        inherit (r) identity cloud;
        bound = r.bind { };
      };

  # A dependency on another instance, as a package reads it.
  instanceDep = ns: inst: out: {
    _meta = {
      namespaceName = ns;
      instanceName = inst;
    };
    inherit out;
  };

  # A ServiceAccount and a Deployment whose cloud identity another package
  # configures. It takes the identity in `identity` and publishes its cloud
  # as `out.identityCloud`.
  holderPackage = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        identity ? null,
        ...
      }:
      let
        credentials = kixlib.cloudIdentity.useIdentity {
          inherit scope;
          dep = identity;
          secretGoesTo = "`deps.credentials` of a caller instance";
        };
      in
      {
        serviceAccount =
          {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "holder";
          }
          |> credentials.bind
          |> scope.mkResource;
        deployment = scope.mkDeployment {
          name = "holder";
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
        root = {
          resource = self.deployment;
          out.identityCloud = credentials.cloud;
        };
      };
  };

  # A ConfigMap that tells the holder's pods to call `config.cloud` with
  # their own credentials, and refuses a holder whose identity is for
  # another cloud.
  callerPackage = {
    meta.version = "test";
    options.cloud = lib.mkOption {
      type = lib.types.enum [
        "aws"
        "gcp"
        "azure"
      ];
    };
    assertions =
      { config, deps, ... }:
      let
        problem = kixlib.cloudIdentity.ambientProblem {
          inherit (config) cloud;
          holder = deps.holder;
        };
      in
      lib.optional (problem != null) (problem // { assertion = false; });
    # `holder` is read by the assertions only, and is named here so the
    # package takes it.
    build =
      {
        self,
        scope,
        holder,
        ...
      }:
      assert holder != null;
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "caller";
        };
        root = self.cm;
      };
  };

  # The holder with `identity` (or null) and a caller for `cloud`, on EKS.
  holderAndCaller =
    { identity, cloud }:
    [
      (flavor "eks")
      (
        { ref, ... }:
        {
          instances.platform.holder = {
            package = holderPackage;
          }
          // lib.optionalAttrs (identity != null) { deps.identity = identity; };
          instances.platform.caller = {
            package = callerPackage;
            deps.holder = ref.platform.holder;
            config = { inherit cloud; };
          };
        }
      )
    ];

  # Storage that the pods reach with their own credentials for
  # `config.ambientCloud`, or with a Secret when it is null. It publishes
  # that as `out.ambientCloud`.
  storagePackage = {
    meta.version = "test";
    options.ambientCloud = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    build =
      {
        self,
        scope,
        config,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "storage";
        };
        root = {
          resource = self.cm;
          out.ambientCloud = config.ambientCloud;
        };
      };
  };

  # A custom resource from which an operator creates the ServiceAccount, as
  # a ConfigMap whose data holds the annotations and pod labels. The
  # identity goes in `backupIdentity`, and the cloud comes from `storage`.
  databasePackage = {
    meta.version = "test";
    build =
      {
        self,
        scope,
        storage,
        cloudIdentity ? null,
        backupIdentity ? null,
        ...
      }:
      let
        credentials = kixlib.cloudIdentity.useIdentity {
          inherit scope;
          dep = backupIdentity;
          cloud = storage.out.ambientCloud;
          secretGoesTo = "`deps.storageCredentials` of the storage instance";
        };
        rendered = kixlib.cloudIdentity.annotationsFor {
          inherit scope;
          inherit (credentials) identity;
          provider = cloudIdentity;
        };
      in
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "database";
          data = rendered.serviceAccountAnnotations // rendered.podLabels;
        };
        root = self.cm;
      };
  };

  # Storage for `ambientCloud` and a database with `identity` (or null), on
  # EKS.
  storageAndDatabase =
    { ambientCloud, identity }:
    [
      (flavor "eks")
      (
        { ref, ... }:
        {
          instances.data.storage = {
            package = storagePackage;
            config = { inherit ambientCloud; };
          };
          instances.data.db = {
            package = databasePackage;
            deps = {
              storage = ref.data.storage;
            }
            // lib.optionalAttrs (identity != null) { backupIdentity = identity; };
          };
        }
      )
    ];

  # The evaluator loaded so that `scope.fail` returns `{ thrown = ...; }`
  # with the full text of the error, so a test reads its fields.
  evalCaughtFull = helpers.loadCaughtFull ../../eval {
    inherit lib k8s;
    self = ../../../..;
  };

  # A package with two credentials dependencies, `primary` and `backup`,
  # that reads both with `config.helper` (`use` or `useIdentity`) for AWS.
  # Its ConfigMap holds, for each dependency, the text of the refusal or
  # "ok".
  twoCredentialsPackage = {
    meta.version = "test";
    options.helper = lib.mkOption {
      type = lib.types.enum [
        "use"
        "useIdentity"
      ];
    };
    build =
      {
        self,
        scope,
        config,
        primary ? null,
        backup ? null,
        ...
      }:
      let
        read =
          arg: dep:
          (
            if config.helper == "use" then
              ci.use {
                inherit scope dep arg;
                cloud = "aws";
              }
            else
              ci.useIdentity {
                inherit scope dep arg;
                cloud = "aws";
                secretGoesTo = "`deps.credentials` of a caller instance";
              }
          ).thrown or "ok";
      in
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "two-credentials";
          data = {
            primary = read "primary" primary;
            backup = read "backup" backup;
          };
        };
        root = self.cm;
      };
  };

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
    {
      cloud,
      hostNetwork ? false,
    }:
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
            arg = "credentials";
          };
          podSpec = {
            serviceAccount = self.serviceAccount;
            containers = [ container ];
          }
          // lib.optionalAttrs hostNetwork { hostNetwork = true; };
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
      hostNetwork ? false,
      extra ? { },
    }:
    [
      (flavor flavorName)
      extra
      {
        instances.work.worker = {
          package = workerPackage { inherit cloud hostNetwork; };
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

  # The parsed `kix.run/cloud-identity-env` annotation on the worker's
  # Deployment and Job objects, or null where there is none.
  podEnvOf =
    modules:
    let
      ms = manifests (mkCluster modules);
      read =
        m:
        let
          v = m.metadata.annotations.${kixKeys.cloudIdentityEnv} or null;
        in
        if v == null then null else builtins.fromJSON v;
    in
    {
      deployment = read (byName "worker" (ofKind "Deployment" ms));
      job = read (byName "worker-once" (ofKind "Job" ms));
    };

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
            "AWS_REGION"
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

  # Each mechanism that adds environment variables to the pods names them
  # on the workload, with the values it knows, so the deploy can check the
  # new pods. GKE adds none, so its workload carries no annotation, and
  # neither does a Job or a workload without an identity.
  cloud-identity-pod-env-annotation =
    let
      clientId = "00000000-0000-0000-0000-000000000001";
      irsaEnv = podEnvOf (workerOn irsa);
      podIdentityEnv = podEnvOf (
        workerOn (irsa // { extra.cluster.flavor.eks.cloudIdentity = "pod-identity"; })
      );
      gkeEnv = podEnvOf (workerOn {
        flavorName = "gke";
        identity = ci.gcp { };
      });
      aksEnv = podEnvOf (workerOn {
        flavorName = "aks";
        identity = ci.azure { inherit clientId; };
      });
      noneEnv = podEnvOf (workerOn {
        flavorName = "eks";
        identity = null;
        cloud = "aws";
      });
    in
    (
      irsaEnv.deployment.env == {
        AWS_ROLE_ARN = roleArn;
        AWS_WEB_IDENTITY_TOKEN_FILE = null;
      }
      && lib.hasInfix "IRSA" irsaEnv.deployment.description
      && lib.hasInfix "EKS Pod Identity association" irsaEnv.deployment.fix
      &&
        irsaEnv.deployment.skip == {
          annotation = "eks.amazonaws.com/skip-containers";
          separator = ",";
        }
      && map (a: a.description) irsaEnv.deployment.alternatives == [ "EKS Pod Identity" ]
      &&
        (builtins.head irsaEnv.deployment.alternatives).env == [
          "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"
          "AWS_CONTAINER_CREDENTIALS_FULL_URI"
        ]
      &&
        map (a: a.description) podIdentityEnv.deployment.alternatives == [
          "IAM roles for service accounts (IRSA)"
        ]
      && irsaEnv.job == null
      &&
        podIdentityEnv.deployment.env == {
          AWS_CONTAINER_CREDENTIALS_FULL_URI = null;
          AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = null;
        }
      && lib.hasInfix "Kix does not create it" podIdentityEnv.deployment.fix
      && gkeEnv.deployment == null
      &&
        aksEnv.deployment.env == {
          AZURE_CLIENT_ID = clientId;
          AZURE_TENANT_ID = null;
          AZURE_FEDERATED_TOKEN_FILE = null;
        }
      && aksEnv.deployment.skip.separator == ";"
      && aksEnv.deployment.alternatives == [ ]
      && noneEnv.deployment == null
    )
    || throw "pod env: irsa ${builtins.toJSON irsaEnv}, pod identity ${builtins.toJSON podIdentityEnv}, gke ${builtins.toJSON gkeEnv}, aks ${builtins.toJSON aksEnv}, none ${builtins.toJSON noneEnv}";

  # GKE gives no identity to a pod on the host network, which would run as
  # the node's service account, so such a pod template is refused. IRSA
  # serves host-network pods, and a host-network pod without an identity
  # is fine on GKE.
  cloud-identity-host-network =
    let
      gkeHost = mkCluster (workerOn {
        flavorName = "gke";
        identity = ci.gcp { };
        hostNetwork = true;
      });
      gkePod = mkCluster (workerOn {
        flavorName = "gke";
        identity = ci.gcp { };
      });
      eksHost = mkCluster (workerOn (irsa // { hostNetwork = true; }));
      gkeHostNone = mkCluster (workerOn {
        flavorName = "gke";
        identity = null;
        cloud = "gcp";
        hostNetwork = true;
      });
    in
    (evalFails gkeHost && !(evalFails gkePod) && !(evalFails eksHost) && !(evalFails gkeHostNone))
    || throw "host network: gke ${builtins.toJSON (evalFails gkeHost)}, gke pod ${builtins.toJSON (evalFails gkePod)}, eks ${builtins.toJSON (evalFails eksHost)}, gke without identity ${builtins.toJSON (evalFails gkeHostNone)}";

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

  # On a self-managed cluster, the webhook modules choose the mechanism
  # beside the flavor: the IRSA module writes the role ARN under its default
  # prefix or the one the cluster sets, and the Azure module writes the
  # client ID and the pod label.
  cloud-identity-self-managed-modules =
    let
      irsaModule = ../../../modules/experimental/irsa-webhook.nix;
      azureModule = ../../../modules/experimental/azure-workload-identity-webhook.nix;
      onKubeadm =
        extra: identity:
        rendered (workerOn {
          flavorName = "kubeadm";
          inherit identity extra;
        });
      defaultPrefix = onKubeadm { imports = [ irsaModule ]; } (ci.aws { inherit roleArn; });
      ownPrefix = onKubeadm {
        imports = [ irsaModule ];
        irsaWebhook.annotationPrefix = "irsa.example.com";
      } (ci.aws { inherit roleArn; });
      azure = onKubeadm { imports = [ azureModule ]; } (
        ci.azure { clientId = "00000000-0000-0000-0000-000000000001"; }
      );
    in
    (
      defaultPrefix.serviceAccount.annotations."eks.amazonaws.com/role-arn" == roleArn
      && ownPrefix.serviceAccount.annotations."irsa.example.com/role-arn" == roleArn
      && azure.deployment.labels."azure.workload.identity/use" == "true"
    )
    || throw "self-managed: ${builtins.toJSON ownPrefix.serviceAccount}";

  # `kix.cloudIdentity` holds only what a cluster author gives a workload
  # and what a package reads. The mechanisms stay inside the library.
  cloud-identity-public-names =
    builtins.attrNames ci == [
      "ambientProblem"
      "annotationsFor"
      "aws"
      "azure"
      "gcp"
      "use"
      "useIdentity"
    ]
    || throw "kix.cloudIdentity: ${builtins.toJSON (builtins.attrNames ci)}";

  # The layout the docs show: one external-dns definition shared by two
  # cluster files. The EKS cluster gives it an IAM role and the kind cluster
  # a Secret instance; the shared file names neither.
  cloud-identity-shared-layout =
    let
      packages = import ../../../packages { inherit lib; };
      build =
        file:
        manifests (
          import (../../../../clusters/test-cloud-identity-layout + "/${file}") {
            kix = publicKix;
            inherit packages;
          }
        );
      eks = build "eks.nix";
      kind = build "kind.nix";
      sa = ms: (byName "route53" (ofKind "ServiceAccount" ms)).metadata.annotations or { };
      pod = ms: (byName "route53" (ofKind "Deployment" ms)).spec.template;
      shared = builtins.readFile ../../../../clusters/test-cloud-identity-layout/external-dns.nix;
    in
    (
      (sa eks)."eks.amazonaws.com/role-arn" == "arn:aws:iam::111122223333:role/external-dns"
      && (pod eks).metadata.annotations ? "checksum/cloud-identity"
      && !(sa kind ? "eks.amazonaws.com/role-arn")
      && (builtins.head (pod kind).spec.containers) ? envFrom
      && !(lib.hasInfix "providerCredentials =" shared)
      && !(lib.hasInfix "cloudIdentity" shared)
    )
    || throw "shared layout: eks ${builtins.toJSON (sa eks)}, kind ${builtins.toJSON (sa kind)}";

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
      && lib.hasInfix "not configured for cloud identities" problem.message
      && lib.hasInfix "kix.flavors.eks" problem.fix
      && lib.hasInfix "kix.modules.experimental.irsa-webhook" problem.fix
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
            out.cloudIdentity = mechanisms.irsa { };
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
      onlyAws =
        let
          r = ci.use {
            scope = recordingScope;
            dep = ci.gcp { };
            cloud = "aws";
            supportedClouds = [ "aws" ];
          };
        in
        r.failed.message + " " + r.failed.fix;
      supported = ci.use {
        scope = recordingScope;
        dep = ci.aws { inherit roleArn; };
        cloud = "aws";
        supportedClouds = [ "aws" ];
      };
      none = useFailure (ci.aws { inherit roleArn; }) null;
    in
    (
      lib.hasInfix "configured to call AWS" other
      && lib.hasInfix "change this instance's `config`" other
      && lib.hasInfix "works only with AWS" onlyAws
      && lib.hasInfix "Google Cloud is not supported yet" onlyAws
      && !(lib.hasInfix "`config`" onlyAws)
      && supported.identity != null
      && lib.hasInfix "does not authenticate with a cloud identity" none
      && useFailure (ci.aws { inherit roleArn; }) "aws" == ""
      && evalFails (
        mkCluster (workerOn {
          flavorName = "gke";
          identity = ci.gcp { };
          cloud = "aws";
        })
      )
    )
    || throw "wrong cloud for the package: ${other}; ${onlyAws}; ${none}";

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

  # `useIdentity` takes a cloud identity or nothing. Without `cloud` it
  # checks the identity's own fields only, and returns the identity's cloud.
  cloud-identity-use-identity-reads-dep =
    let
      none = useIdentityResult { dep = null; };
      aws = useIdentityResult { dep = ci.aws { inherit roleArn; }; };
      gcp = useIdentityResult { dep = ci.gcp { }; };
      malformed = useIdentityResult { dep = ci.aws { rolearn = roleArn; }; };
    in
    (
      none == {
        identity = null;
        cloud = null;
        bound = { };
      }
      && aws.cloud == "aws"
      && aws.identity.cloud == "aws"
      && aws.bound._cloudIdentity.cloud == "aws"
      && gcp.cloud == "gcp"
      && lib.hasInfix "no field `rolearn`" malformed.failure
    )
    || throw "useIdentity: ${
      builtins.toJSON [
        none
        aws.cloud
        gcp.cloud
        malformed
      ]
    }";

  # A Secret instance in the dependency is refused, naming the instance and
  # where a Secret goes, with `cloud` set or not. The same call with a cloud
  # identity passes.
  cloud-identity-use-identity-refuses-a-secret =
    let
      secret = instanceDep "data" "keys" { name = "keys"; };
      omitted = useIdentityResult { dep = secret; };
      withCloud = useIdentityResult {
        dep = secret;
        cloud = "aws";
      };
      good = useIdentityResult {
        dep = ci.aws { inherit roleArn; };
        cloud = "aws";
      };
    in
    (
      lib.hasInfix "but got `data/keys`" omitted.failure
      && lib.hasInfix "`deps.storageCredentials` of the storage instance" omitted.failure
      && withCloud ? failure
      && !(good ? failure)
      && good.cloud == "aws"
    )
    || throw "useIdentity with a Secret: ${
      builtins.toJSON [
        omitted
        withCloud
      ]
    }";

  # With `cloud` set, an identity for another cloud is refused and one for
  # the same cloud passes. With `cloud = null` any identity is refused, and
  # no identity passes.
  cloud-identity-use-identity-checks-cloud =
    let
      mismatched = useIdentityResult {
        dep = ci.gcp { };
        cloud = "aws";
      };
      matching = useIdentityResult {
        dep = ci.gcp { };
        cloud = "gcp";
      };
      unused = useIdentityResult {
        dep = ci.aws { inherit roleArn; };
        cloud = null;
      };
      nothing = useIdentityResult {
        dep = null;
        cloud = null;
      };
    in
    (
      lib.hasInfix "but this instance's pods call AWS" mismatched.failure
      && lib.hasInfix "`kix.cloudIdentity.aws { ... }`" mismatched.failure
      && matching.cloud == "gcp"
      && lib.hasInfix "read their cloud credentials from a Secret" unused.failure
      && lib.hasInfix "`deps.storageCredentials` of the storage instance" unused.failure
      && nothing.identity == null
    )
    || throw "useIdentity cloud: ${
      builtins.toJSON [
        mismatched
        unused
      ]
    }";

  # `ambientProblem` refuses a holder whose identity is for another cloud
  # than the one reached, naming the holder and both clouds. A holder with
  # no identity, or with no `out.identityCloud`, and a matching one pass.
  cloud-identity-ambient-problem =
    let
      holder = instanceDep "platform" "cert-manager";
      check =
        cloud: out:
        ci.ambientProblem {
          inherit cloud;
          holder = holder out;
        };
      mismatched = check "gcp" { identityCloud = "aws"; };
    in
    (
      check "aws" { identityCloud = null; } == null
      && check "aws" { } == null
      && check "aws" { identityCloud = "aws"; } == null
      && lib.hasInfix "`platform/cert-manager`" mismatched.message
      && lib.hasInfix "to call Google Cloud" mismatched.message
      && lib.hasInfix "identity for AWS" mismatched.message
      && lib.hasInfix "`kix.cloudIdentity.gcp { ... }`" mismatched.fix
    )
    || throw "ambientProblem: ${builtins.toJSON mismatched}";

  # The direct form of `ambientProblem` (`holderName`, `identityCloud`)
  # gives the same result and text as the `holder` form. Both forms at once,
  # neither, or half of the direct form stop evaluation.
  cloud-identity-ambient-problem-direct =
    let
      direct =
        cloud: identityCloud:
        ci.ambientProblem {
          inherit cloud identityCloud;
          holderName = "platform/cert-manager";
        };
      viaHolder =
        cloud: identityCloud:
        ci.ambientProblem {
          inherit cloud;
          holder = instanceDep "platform" "cert-manager" { inherit identityCloud; };
        };
      mismatched = direct "gcp" "aws";
      fails = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
      holder = instanceDep "platform" "cert-manager" { identityCloud = "aws"; };
    in
    (
      mismatched == viaHolder "gcp" "aws"
      && lib.hasInfix "`platform/cert-manager`" mismatched.message
      && direct "aws" "aws" == null
      && direct "aws" null == null
      && direct null "aws" == null
      && fails (
        ci.ambientProblem {
          cloud = "aws";
          inherit holder;
          holderName = "platform/cert-manager";
          identityCloud = "aws";
        }
      )
      && fails (ci.ambientProblem { cloud = "aws"; })
      && fails (
        ci.ambientProblem {
          cloud = "aws";
          holderName = "platform/cert-manager";
        }
      )
    )
    || throw "ambientProblem direct: ${builtins.toJSON mismatched}";

  # `use` adds `identityGoesTo` to the fix when it refuses an identity on a
  # package that takes none, and leaves it out when not given.
  cloud-identity-use-identity-goes-to =
    let
      failureWith =
        extra:
        let
          r = ci.use (
            {
              scope = recordingScope;
              dep = ci.aws { inherit roleArn; };
              cloud = null;
            }
            // extra
          );
        in
        r.failed.fix;
      named = failureWith { identityGoesTo = "`deps.controllerIdentity` of the cert-manager instance"; };
      plain = failureWith { };
    in
    (
      lib.hasInfix "move it to `deps.controllerIdentity` of the cert-manager instance" named
      && !(lib.hasInfix "controllerIdentity" plain)
      && useFailure (ci.aws { inherit roleArn; }) "aws" == ""
    )
    || throw "identityGoesTo: ${named}; ${plain}";

  # `annotationsFor` with no identity returns empty sets without reading
  # the provider. An identity with no provider is still refused.
  cloud-identity-annotations-for-no-identity =
    let
      empty = ci.annotationsFor {
        scope = recordingScope;
        identity = null;
        provider = null;
      };
      refused = ci.annotationsFor {
        scope = recordingScope;
        identity = ci.aws { inherit roleArn; };
        provider = null;
      };
    in
    (
      empty == {
        serviceAccountAnnotations = { };
        podLabels = { };
        networkIntents.egress = [ ];
      }
      && lib.hasInfix "not configured for cloud identities" refused.failed.message
    )
    || throw "annotationsFor without identity: ${builtins.toJSON empty}";

  # The package that owns the ServiceAccount binds the identity and
  # publishes its cloud. A dependent that calls the same cloud with the
  # pod's credentials builds, one that calls another cloud fails with the
  # holder named, and a holder without an identity passes any cloud. A
  # Secret on the holder fails evaluation.
  cloud-identity-ambient-across-packages =
    let
      awsIdentity = ci.aws { inherit roleArn; };
      ms = manifests (
        mkCluster (holderAndCaller {
          identity = awsIdentity;
          cloud = "aws";
        })
      );
      sa = (byName "holder" (ofKind "ServiceAccount" ms)).metadata.annotations;
      pod = (byName "holder" (ofKind "Deployment" ms)).spec.template.metadata;
      mismatched = failedOf (holderAndCaller {
        identity = awsIdentity;
        cloud = "gcp";
      });
      nodeCredentials = failedOf (holderAndCaller {
        identity = null;
        cloud = "gcp";
      });
      withSecret = mkCluster [
        (flavor "eks")
        (
          { ref, ... }:
          {
            instances.platform.keys = {
              package = secretRefPackage;
              config.keys = [ "AWS_ACCESS_KEY_ID" ];
            };
            instances.platform.holder = {
              package = holderPackage;
              deps.identity = ref.platform.keys;
            };
          }
        )
      ];
    in
    (
      sa."eks.amazonaws.com/role-arn" == roleArn
      && pod.annotations ? "checksum/cloud-identity"
      && builtins.any (a: lib.hasInfix "`platform/holder`" a.message) mismatched
      && nodeCredentials == [ ]
      && evalFails withSecret
    )
    || throw "across packages: mismatched ${builtins.toJSON mismatched}, node ${builtins.toJSON nodeCredentials}";

  # The package that owns an operator's ServiceAccount reads the cloud from
  # the storage package's `out.ambientCloud` and renders the identity with
  # `annotationsFor`. Storage that reads a Secret refuses an identity, and
  # builds without one.
  cloud-identity-use-identity-from-ambient-cloud =
    let
      dataOf =
        args:
        (byName "database" (ofKind "ConfigMap" (manifests (mkCluster (storageAndDatabase args))))).data
          or { };
      awsIdentity = ci.aws { inherit roleArn; };
      bound = dataOf {
        ambientCloud = "aws";
        identity = awsIdentity;
      };
      secretOnly = dataOf {
        ambientCloud = null;
        identity = null;
      };
    in
    (
      bound."eks.amazonaws.com/role-arn" == roleArn
      && bound ? ${kixKeys.cloudIdentity}
      && secretOnly == { }
      && evalFails (
        mkCluster (storageAndDatabase {
          ambientCloud = null;
          identity = awsIdentity;
        })
      )
      && evalFails (
        mkCluster (storageAndDatabase {
          ambientCloud = "aws";
          identity = ci.gcp { };
        })
      )
    )
    || throw "from ambientCloud: ${builtins.toJSON bound}";

  # On a package with two credentials dependencies, a refusal from `use`
  # and from `useIdentity` names the dependency that holds the bad value,
  # in the message and in the error's `dependency` field.
  cloud-identity-refusal-names-dependency =
    let
      dataOf =
        helper:
        (byName "two-credentials" (
          ofKind "ConfigMap" (
            manifests (
              evalCaughtFull.buildCluster {
                name = "test";
                modules = [
                  (flavor "eks")
                  {
                    instances.platform.two = {
                      package = twoCredentialsPackage;
                      config = { inherit helper; };
                      deps = {
                        primary = ci.aws { inherit roleArn; };
                        backup = ci.gcp { };
                      };
                    };
                  }
                ];
              }
            )
          )
        )).data;
      refusalOf =
        helper:
        let
          data = dataOf helper;
        in
        {
          inherit (data) primary;
          record = builtins.head (helpers.records data.backup);
        };
      use = refusalOf "use";
      useIdentity = refusalOf "useIdentity";
      namesBackup =
        r:
        r.primary == "ok"
        && r.record.dependency == "backup"
        && r.record.instance == "platform/two"
        && lib.hasInfix "`deps.backup` is set to `kix.cloudIdentity.gcp { ... }` (Google Cloud)" r.record.message
        && lib.hasInfix "Set `deps.backup` to" r.record.fix;
      # Without `arg`, the message keeps its general wording.
      unnamed = useFailure (ci.gcp { }) "aws";
    in
    (
      namesBackup use
      && namesBackup useIdentity
      && !(lib.hasInfix "deps." unnamed)
      && lib.hasInfix "This dependency is set to" unnamed
      && lib.hasInfix "Set this dependency to" unnamed
    )
    || throw "refusal names dependency: use ${builtins.toJSON use}, useIdentity ${builtins.toJSON useIdentity}";

  # Binding a cloud identity adds the mechanism's credential egress to the
  # egress policy of every workload that runs as the ServiceAccount, on
  # each cloud: STS on 443 for IRSA, the Pod Identity agent's addresses on
  # port 80, the GKE metadata server on 80 and 8080, and Entra ID on 443
  # for AKS. Without an identity no such rule is added.
  cloud-identity-credential-egress =
    let
      tcp = port: {
        inherit port;
        protocol = "TCP";
      };
      # The test enforcer takes the role from the platform's own enforcer,
      # which the gke flavours and the eks flavour with the VPC CNI declare.
      testEnforcerWins =
        { options, ... }:
        {
          config = lib.mkMerge [
            { cluster.roles.network-policy-enforcer.binding = lib.mkForce "shadowable"; }
            (lib.optionalAttrs (lib.hasAttrByPath [ "cluster" "flavor" "eks" "networkPolicy" ] options) {
              cluster.flavor.eks.networkPolicy = "vpc-cni";
            })
          ];
        };
      # The intent rules the test enforcer echoes on the worker's three
      # egress policies.
      intentRulesOf =
        modules:
        let
          ms = manifests (
            mkCluster (
              modules
              ++ [
                netpolOn
                testEnforcerWins
              ]
            )
          );
          rulesOf =
            name:
            map (r: removeAttrs r [ "stubRule" ]) (
              builtins.filter (r: (r.stubRule or null) == "intent-egress") (byName name ms).spec.egress
            );
        in
        {
          deployment = rulesOf "worker-deployment-worker-egress";
          job = rulesOf "worker-job-worker-once-egress";
          cronJob = rulesOf "worker-cronjob-worker-nightly-egress";
        };
      onEvery = rules: {
        deployment = rules;
        job = rules;
        cronJob = rules;
      };
      world443 = [
        {
          to = "world";
          ports = [ (tcp 443) ];
        }
      ];
      cases = {
        irsa = {
          got = intentRulesOf (workerOn irsa);
          want = onEvery world443;
        };
        eksPodIdentity = {
          got = intentRulesOf (
            workerOn (irsa // { extra.cluster.flavor.eks.cloudIdentity = "pod-identity"; })
          );
          want = onEvery [
            {
              to = "node-local";
              cidr = "169.254.170.23/32";
              ports = [ (tcp 80) ];
            }
            {
              to = "node-local";
              cidr = "fd00:ec2::23/128";
              ports = [ (tcp 80) ];
            }
          ];
        };
        gke = {
          got = intentRulesOf (workerOn {
            flavorName = "gke";
            identity = ci.gcp { };
          });
          want = onEvery [
            {
              to = "node-local";
              cidr = "169.254.169.254/32";
              ports = [
                (tcp 80)
                (tcp 8080)
              ];
            }
          ];
        };
        aks = {
          got = intentRulesOf (workerOn {
            flavorName = "aks";
            identity = ci.azure { clientId = "00000000-0000-0000-0000-000000000000"; };
          });
          want = onEvery world443;
        };
        withoutIdentity = {
          got = intentRulesOf (workerOn {
            flavorName = "gke";
            identity = null;
            cloud = "gcp";
          });
          want = onEvery [ ];
        };
      };
      wrong = lib.filterAttrs (_: c: c.got != c.want) cases;
    in
    wrong == { } || throw "credential egress: ${builtins.toJSON wrong}";

  # The cilium enforcer writes a node-local rule twice: once as the address
  # and once as the `host` entity, because Cilium 1.16 and 1.17 match a
  # node-bound link-local address differently.
  cloud-identity-cilium-node-local =
    let
      cilium = import ../../../packages/experimental/cilium/netpol-rules.nix { inherit lib; };
      ports = [
        {
          ports = [
            {
              port = "80";
              protocol = "TCP";
            }
          ];
        }
      ];
      got =
        (cilium.translateIntentRules {
          intents.identity.egress = (mechanisms.eksPodIdentity { }).egress;
        }).egressRules;
    in
    got == [
      {
        toCIDR = [ "169.254.170.23/32" ];
        toPorts = ports;
      }
      {
        toEntities = [ "host" ];
        toPorts = ports;
      }
      {
        toCIDR = [ "fd00:ec2::23/128" ];
        toPorts = ports;
      }
      {
        toEntities = [ "host" ];
        toPorts = ports;
      }
    ]
    || throw "cilium node-local: ${builtins.toJSON got}";

  # For pods an operator creates, `annotationsFor` returns the credential
  # egress as intent rules, and empty rules without an identity.
  cloud-identity-annotations-for-network-intents =
    let
      provider = {
        _meta = {
          namespaceName = "kube-system";
          instanceName = "cloud-identity";
        };
        out.cloudIdentity = mechanisms.gke { };
      };
      withIdentity = ci.annotationsFor {
        scope = recordingScope;
        identity = ci.gcp { };
        inherit provider;
      };
      without = ci.annotationsFor {
        scope = recordingScope;
        identity = null;
        inherit provider;
      };
    in
    (
      withIdentity.networkIntents.egress == (mechanisms.gke { }).egress
      && without.networkIntents.egress == [ ]
    )
    || throw "annotationsFor networkIntents: ${builtins.toJSON withIdentity.networkIntents}";
}
