# cdi: the Containerized Data Importer operator, which imports, uploads, and
# clones disk images into PersistentVolumeClaims.
#
# The package renders cdi-operator, its roles (rbac/*.json, vendored from
# upstream's operator bundle), the CDI custom resource definition, and a CDI
# resource. cdi-operator then runs cdi-apiserver, cdi-deployment (the
# controller), and cdi-uploadproxy in this namespace and installs the CRDs of
# its own kinds (DataVolume, DataImportCron, StorageProfile, and the rest).
# The deploy waits for the CDI resource to reach phase Deployed.
#
# A cluster runs one instance: the CDI resource, its CRD, and the CRDs and
# webhooks cdi-operator installs are cluster-wide, so `conflictsWith`
# refuses a second instance.
#
# Minimal instance:
#
#   instances.cdi.cdi.package = packages.cdi;
#
# A consumer takes `cdi` as a dependency and builds DataVolumes with
# out.mkDataVolume. A disk a virtual machine boots from belongs in the
# VirtualMachine's `dataVolumeTemplates` (kubevirt's out.mkVirtualMachine);
# clusters/test-virtualization.nix shows both.
#
#   blank = cdi.out.mkDataVolume scope {
#     name = "scratch";
#     spec = {
#       source.blank = { };
#       storage = {
#         accessModes = [ "ReadWriteOnce" ];
#         resources.requests.storage = "64Mi";
#       };
#     };
#   };
#
# A DataVolume's `storage` form takes the access and volume modes it omits
# from the StorageClass's StorageProfile. CDI fills a StorageProfile only for
# provisioners it recognises; for others, such as kind's
# rancher.io/local-path, the DataVolume stays unbound with ErrClaimNotValid
# unless it sets `storage.accessModes` or the StorageProfile's
# `spec.claimPropertySets` is set.
#
# Network policy: with an enforcer, the API server reaches cdi-apiserver (an
# aggregated API and the admission webhooks) and the operands reach DNS and
# the API server. cdi-deployment polls importer pods for progress on 8443,
# and cdi-uploadproxy forwards uploads to upload server pods on 8443. Those
# pods run in the DataVolume's namespace and are the consumer's to allow: an
# HTTP or registry import that pulls in a pod needs DNS, egress to its
# source, and ingress from cdi-deployment, which out.mkImporterPolicy builds.
# Imports with `pullMethod = "node"` and blank DataVolumes need neither. An
# upload, or a host-assisted clone, runs an upload server pod in the target
# namespace (out.mkUploadServerPolicy). A host-assisted clone also runs a
# cloner pod in the source namespace, which sends to the upload server and
# which cdi-deployment polls (out.mkClonerPolicy). A clone the storage
# provider performs (a CSI or snapshot clone) runs neither pod.
#
# Priority: cdi-operator gives its operands the PriorityClass named in the
# CDI resource, and without one `kubevirt-cluster-critical` (which the
# kubevirt package creates) if that class exists when it reconciles, else
# none. A `priorityClass` dependency (packages.priority-class) names the
# class and orders the CDI resource after it.
#
# Monitoring: cdi-operator creates its own ServiceMonitor and PrometheusRule
# in this namespace when the prometheus-operator CRDs exist.
#
# Escape hatches: `extraSpec`, deep-merged into the CDI resource's spec;
# `partsOverlays`; `scope.mkCR cdi.out.crds.DataVolume` for a DataVolume the
# deploy should not wait for.
#
# `out`:
#   out.crds.DataVolume
#   out.mkDataVolume scope { name; spec; annotations ? { }; ... }
#       A DataVolume that binds its claim at once, so it completes on a
#       WaitForFirstConsumer StorageClass without a consumer pod, and that
#       the deploy waits on until its phase is Succeeded.
#   out.mkImporterPolicy scope { name ? "<instance>-cdi-importer"; egress; }
#       A policy in the caller's namespace for the importer pods CDI starts
#       there: DNS, the `egress` intent rules (for example
#       `[ { to = "world"; ports = [ { port = 443; protocol = "TCP"; } ]; } ]`
#       for a public registry), and ingress from cdi-deployment on 8443. The
#       default name carries the calling instance's name. Null when the
#       namespace has no enforcer.
#   out.mkUploadServerPolicy scope { name ? "<instance>-cdi-upload-server";
#                                    cloneSourceNamespaces ? [ ]; }
#       A policy in the caller's namespace for the upload server pods CDI
#       starts there: ingress on 8443 from cdi-uploadproxy and from the
#       cloner pods in each of `cloneSourceNamespaces`. Null without an
#       enforcer.
#   out.mkClonerPolicy scope { name ? "<instance>-cdi-cloner";
#                              targetNamespaces ? [ <caller's namespace> ]; }
#       A policy in the caller's namespace, the clone source's, for the
#       cloner pods CDI starts there: DNS, egress on 8443 to the upload
#       server pods in each of `targetNamespaces`, and ingress on 8443 from
#       cdi-deployment. Null without an enforcer.
#   out.operandSelectors.{importer, uploadServer, cloner, deployment, uploadProxy}
#       Pod labels of the importer, upload server, and cloner pods, and of
#       the cdi-deployment and cdi-uploadproxy pods.
#   out.extraImages
#       Every image cdi-operator runs, digest-pinned.
#
# root = the cdi-operator Deployment.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # The upstream release: meta.version, the default image.tag, and the tag
  # in crds/sources.txt and rbac/sources.txt (kix-lib test
  # kubevirt-cdi-sources-match-release).
  release = "v1.62.0";

  # "v1.62.0" -> "v1.62"; null for a tag that is not a vX.Y release.
  # Upstream tags every release with the leading v.
  minorOf =
    tag: lib.mapNullable (m: "v${builtins.head m}") (builtins.match "v([0-9]+\\.[0-9]+)(\\..*)?" tag);

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "cdi ${ns}/${name}";

  readJSON = file: builtins.fromJSON (builtins.readFile file);

  # Each operand image: the index digest of its release tag (a digest
  # applies while the image keeps that tag) and the cdi-operator variables
  # it is passed in. The oVirt populator runs the importer image, as
  # upstream's bundle sets it.
  operands = {
    cdi-apiserver = {
      digest = "sha256:aa5c2e16c67545f449086b4e49a25f9b304a17174985b841d82e8ff618fb809e";
      env = [ "APISERVER_IMAGE" ];
    };
    cdi-cloner = {
      digest = "sha256:ece16cb37976eb1a075b9b276b9d42d9a5c349dc9f29d1b7d08f0b985e119f07";
      env = [ "CLONER_IMAGE" ];
    };
    cdi-controller = {
      digest = "sha256:c4c35dce67ecbca97d3eb854d5468b6e60b06cd90e140fec83bb58ec566abb43";
      env = [ "CONTROLLER_IMAGE" ];
    };
    cdi-importer = {
      digest = "sha256:df76770eef8bfc218a6423dea41a0d597b80821cd0434528aaa84951d2242abc";
      env = [
        "IMPORTER_IMAGE"
        "OVIRT_POPULATOR_IMAGE"
      ];
    };
    cdi-uploadproxy = {
      digest = "sha256:28d70e20ca6b1435470a7c7dd2bc28d394705b730c7d760ef827addb768ab5b1";
      env = [ "UPLOAD_PROXY_IMAGE" ];
    };
    cdi-uploadserver = {
      digest = "sha256:de0e6e49f7086c1fc526e339d435dc92c51d51e416e90ae4b988271bf5fafe42";
      env = [ "UPLOAD_SERVER_IMAGE" ];
    };
  };

  # Labels cdi-operator and cdi-deployment put on the pods they create
  # (pkg/operator/resources/namespaced, pkg/controller/import-controller.go,
  # upload-controller.go, and clone-controller.go at the release).
  # cdi-operator labels each operand pod with `cdi.kubevirt.io=<deployment
  # name>`, read from a running v1.62.0 install.
  operandSelectors = {
    importer = {
      app = "containerized-data-importer";
      "cdi.kubevirt.io" = "importer";
    };
    uploadServer = {
      app = "containerized-data-importer";
      "cdi.kubevirt.io" = "cdi-upload-server";
    };
    cloner = {
      app = "containerized-data-importer";
      "cdi.kubevirt.io" = "cdi-clone-source";
    };
    deployment = {
      app = "containerized-data-importer";
      "cdi.kubevirt.io" = "cdi-deployment";
    };
    uploadProxy."cdi.kubevirt.io" = "cdi-uploadproxy";
    apiServer."cdi.kubevirt.io" = "cdi-apiserver";
  };

  tcp = port: {
    inherit port;
    protocol = "TCP";
  };
in
{
  meta = {
    version = release;
    description = "KubeVirt Containerized Data Importer: the cdi-operator and a CDI resource; CDI imports disk images into PVCs";
    owner = "platform";
    defaultAliases = [ "cdi" ];
    # One instance per cluster; see the header.
    conflictsWith = [ "cluster:cdi" ];
  };

  assertions =
    { config, ... }:
    let
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
    in
    [
      {
        assertion = minorOf imageTag == minorOf release;
        message = "image.tag \"${imageTag}\" is not a ${minorOf release} release (upstream tags look like ${release}), and the CRD and roles under kix/packages/cdi/{crds,rbac} are vendored from ${release}. Remove image.tag or set a ${minorOf release} tag. To move to another release, change release in kix/packages/cdi/default.nix and the tag in crds/sources.txt and rbac/sources.txt, then run uv run scripts/vendor-crds.py cdi.";
      }
    ]
    ++ map (n: {
      assertion = config.operandImages.${n}.pullPolicy == null;
      message = "operandImages.${n}.pullPolicy = \"${
        toString config.operandImages.${n}.pullPolicy
      }\" has no effect: cdi-operator gives every operand the CDI resource's imagePullPolicy, which is image.pullPolicy. Remove it.";
    }) (builtins.attrNames operands);

  options = {
    image = kix.options.image {
      repository = "quay.io/kubevirt/cdi-operator";
      tag = release;
      digest = "sha256:21fe82706f57bc5378ba17be79d6831b223605ecf1ea6f43f533b1bccae68c50";
      description = "Image of cdi-operator. Its major.minor must match the vendored CRD and roles. Each operand image defaults to this repository's registry and path with its own name (quay.io/kubevirt/<name>) and to this tag, and every operand uses this image's pullPolicy.";
    };

    operandImages = lib.mapAttrs (
      n: operand:
      kix.options.image {
        repository = "quay.io/kubevirt/${n}";
        tag = release;
        inherit (operand) digest;
        tagText = "config.image.tag";
        pullPolicy = null;
        description = "Image cdi-operator runs as ${n} (${lib.concatStringsSep ", " operand.env}). Listed in out.extraImages. Its repository follows image.repository and its tag image.tag; the CDI resource's imagePullPolicy applies, so pullPolicy must stay null.";
      }
    ) operands;

    # Requests from cdi-operator.yaml at the release. Upstream sets no
    # limits; these are the package's.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "150Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Fields deep-merged into the CDI resource's spec, such as `config.featureGates`, `cloneStrategyOverride`, `workload`, or `infra.nodeSelector`. The package refuses `infra.apiServerReplicas`, `infra.deploymentReplicas`, and `infra.uploadProxyReplicas`, which follow the instance's availability, `imagePullPolicy`, which is image.pullPolicy, and, when the instance has a `priorityClass` dependency, `priorityClass`.";
    };
  };

  config =
    { config, ... }:
    {
      operandImages = lib.genAttrs (builtins.attrNames operands) (n: {
        repository = lib.mkDefault "${dirOf config.image.repository}/${n}";
        tag = lib.mkDefault config.image.tag;
      });
    };

  build =
    {
      self,
      config,
      priorityClass ? null,
      ...
    }:
    let
      pick = kix.availability.pick availability;
      operandRefs = lib.mapAttrs (_: kix.image.ref) config.operandImages;

      # cdi-operator runs one replica of each operand unless the CDI
      # resource asks for more.
      operandReplicas = pick {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };

      baseSpec = {
        infra = {
          apiServerReplicas = operandReplicas;
          deploymentReplicas = operandReplicas;
          uploadProxyReplicas = operandReplicas;
        };
      }
      // lib.optionalAttrs (config.image.pullPolicy != null) {
        imagePullPolicy = config.image.pullPolicy;
      }
      // lib.optionalAttrs (priorityClass != null) {
        priorityClass = priorityClass.out.name;
      };

      operandEnvVars = lib.concatLists (
        lib.mapAttrsToList (
          n: operand:
          map (v: {
            name = v;
            value = operandRefs.${n};
          }) operand.env
        ) operands
      );

      # Policies for the pods cdi-operator runs in this namespace. The spec
      # is read only when an enforcer exists.
      operandPolicy =
        suffix: selector: intents:
        kix.operandPolicy {
          inherit scope;
          name = "${name}-${suffix}";
          spec =
            let
              netpol = scope.networkPolicyEnforcer.netpol;
              translated = netpol.translateIntentRules { intents.operand = intents; };
            in
            netpol.mkEndpointSelector selector
            // lib.optionalAttrs (translated.egressRules != [ ]) { egress = translated.egressRules; }
            // lib.optionalAttrs (translated.ingressRules != [ ]) { ingress = translated.ingressRules; };
        };

      mkImporterPolicy =
        consumerScope:
        {
          name ? "${consumerScope.instanceName}-cdi-importer",
          egress,
        }:
        kix.operandPolicy {
          scope = consumerScope;
          inherit name;
          spec =
            let
              netpol = consumerScope.networkPolicyEnforcer.netpol;
              translated = netpol.translateIntentRules {
                intents.importer.egress = [ { to = "dns"; } ] ++ egress;
              };
            in
            netpol.mkEndpointSelector operandSelectors.importer
            // {
              egress = translated.egressRules;
              ingress = [
                (netpol.mkCallerIngressRule {
                  callerSelector = operandSelectors.deployment;
                  callerNamespace = ns;
                  ports = [ (tcp 8443) ];
                })
              ];
            };
        };

      # Upload server pods receive an upload from cdi-uploadproxy, or a
      # host-assisted clone from a cloner pod in each source namespace.
      mkUploadServerPolicy =
        consumerScope:
        {
          name ? "${consumerScope.instanceName}-cdi-upload-server",
          cloneSourceNamespaces ? [ ],
        }:
        kix.operandPolicy {
          scope = consumerScope;
          inherit name;
          spec =
            let
              netpol = consumerScope.networkPolicyEnforcer.netpol;
              from =
                callerSelector: callerNamespace:
                netpol.mkCallerIngressRule {
                  inherit callerSelector callerNamespace;
                  ports = [ (tcp 8443) ];
                };
            in
            netpol.mkEndpointSelector operandSelectors.uploadServer
            // {
              ingress = [
                (from operandSelectors.uploadProxy ns)
              ]
              ++ map (from operandSelectors.cloner) cloneSourceNamespaces;
            };
        };

      # A cloner pod streams the source volume to the upload server pod in
      # each target namespace, and cdi-deployment polls it for progress.
      mkClonerPolicy =
        consumerScope:
        {
          name ? "${consumerScope.instanceName}-cdi-cloner",
          targetNamespaces ? [ consumerScope.namespaceName ],
        }:
        kix.operandPolicy {
          scope = consumerScope;
          inherit name;
          spec =
            let
              netpol = consumerScope.networkPolicyEnforcer.netpol;
            in
            netpol.mkEndpointSelector operandSelectors.cloner
            // {
              egress = [
                netpol.dnsEgressRule
              ]
              ++ map (
                namespace:
                netpol.mkServiceEgressRule {
                  selector = operandSelectors.uploadServer;
                  inherit namespace;
                  sourceNamespace = consumerScope.namespaceName;
                  ports = [ (tcp 8443) ];
                }
              ) targetNamespaces;
              ingress = [
                (netpol.mkCallerIngressRule {
                  callerSelector = operandSelectors.deployment;
                  callerNamespace = ns;
                  ports = [ (tcp 8443) ];
                })
              ];
            };
        };

      # A DataVolume binds its claim once a pod consumes it when the
      # StorageClass is WaitForFirstConsumer. CDI binds at once when the
      # annotation is present, whatever its value
      # (pkg/controller/common/util.go ImmediateBindingRequested).
      mkDataVolume =
        consumerScope: args:
        self.crds.dataVolumes.out.mkCR consumerScope (
          args
          // {
            annotations = (args.annotations or { }) // {
              "cdi.kubevirt.io/storage.bind.immediate.requested" = "true";
              ${kix.keys.readiness} = builtins.toJSON {
                path = "/status/phase";
                equals = "Succeeded";
              };
            };
          }
        );
    in
    {
      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        name = "${name}-operator";
      };

      clusterRbac = scope.rbac.mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        roles."${name}-operator-cluster" = (readJSON ./rbac/clusterrole-cdi-operator-cluster.json).rules;
      };

      operatorRbac = scope.rbac.mkRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        roles."${name}-operator" = (readJSON ./rbac/role-cdi-operator.json).rules;
      };

      deployment = scope.mkDeployment {
        name = "${name}-operator";
        requires = builtins.attrValues self.clusterRbac ++ builtins.attrValues self.operatorRbac;
        spec = {
          # cdi-operator holds a leader election lease, so a replacement pod
          # covers "pod" and a standby on another node covers "node".
          replicas = pick {
            none = 1;
            pod = 1;
            node = 2;
            zone = 2;
          };
          selector.matchLabels = scope.selectorLabels;
          template = {
            # Upstream's pod labels. The metrics Service cdi-operator creates
            # selects prometheus.cdi.kubevirt.io.
            metadata.labels = scope.selectorLabels // {
              name = "cdi-operator";
              "operator.cdi.kubevirt.io" = "";
              "cdi.kubevirt.io" = "cdi-operator";
              "prometheus.cdi.kubevirt.io" = "true";
            };
            spec = {
              serviceAccount = self.serviceAccount;
              terminationGracePeriodSeconds = 30;
              securityContext.runAsNonRoot = true;
              nodeSelector."kubernetes.io/os" = "linux";
              tolerations = [
                {
                  key = "CriticalAddonsOnly";
                  operator = "Exists";
                }
              ];
              containers = [
                {
                  name = "cdi-operator";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  env = [
                    {
                      name = "DEPLOY_CLUSTER_RESOURCES";
                      value = "true";
                    }
                    {
                      name = "OPERATOR_VERSION";
                      value = builtins.unsafeDiscardStringContext config.image.tag;
                    }
                    {
                      name = "VERBOSITY";
                      value = "1";
                    }
                  ]
                  ++ operandEnvVars
                  ++ lib.optional (config.image.pullPolicy != null) {
                    name = "PULL_POLICY";
                    value = config.image.pullPolicy;
                  };
                  ports = [ (kix.port "metrics" 8080) ];
                  # cdi-operator.yaml sets no probes and the operator serves
                  # no health endpoint, so both probes read its metrics.
                  readinessProbe = {
                    httpGet = {
                      path = "/metrics";
                      port = "metrics";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                    timeoutSeconds = 10;
                  };
                  livenessProbe = {
                    httpGet = {
                      path = "/metrics";
                      port = "metrics";
                    };
                    initialDelaySeconds = 15;
                    periodSeconds = 10;
                    timeoutSeconds = 10;
                  };
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                    runAsNonRoot = true;
                    seccompProfile.type = "RuntimeDefault";
                  };
                }
              ];
            };
          };
        };
      };

      cdiCR = scope.mkCR self.crds.cdis {
        inherit name;
        spec = kix.mergeGuarded {
          inherit who;
          locked = [
            [
              "infra"
              "apiServerReplicas"
            ]
            [
              "infra"
              "deploymentReplicas"
            ]
            [
              "infra"
              "uploadProxyReplicas"
            ]
            [ "imagePullPolicy" ]
          ]
          ++ lib.optional (priorityClass != null) [ "priorityClass" ];
        } baseSpec config.extraSpec;
        requires = [ self.deployment ];
      };

      crds = {
        # cdi-operator rewrites this CRD once it runs and drops the
        # deprecated v1alpha1 version. The package cedes `spec.versions`, so
        # Kix ships upstream's list at creation and later deploys apply
        # without the field.
        cdis = scope.mkCRD {
          spec = (readJSON ./crds/cdis.cdi.kubevirt.io.json).spec;
          ownership.cede = [ "spec.versions" ];
          readiness = {
            path = "/status/phase";
            equals = "Deployed";
          };
        };

        # cdi-operator installs the DataVolume CRD once the CDI resource
        # exists. Readiness is stamped per DataVolume by out.mkDataVolume.
        dataVolumes = scope.mkCRDRef {
          group = "cdi.kubevirt.io";
          kind = "DataVolume";
          plural = "datavolumes";
          version = "v1beta1";
          installedBy = self.cdiCR;
        };
      };

      # Null without an enforcer. The API server reaches cdi-apiserver as an
      # aggregated API and an admission webhook; cdi-deployment polls
      # importer pods and cdi-uploadproxy forwards to upload server pods, in
      # other namespaces, on 8443.
      operandPolicies = {
        apiServer = operandPolicy "cdi-apiserver" operandSelectors.apiServer {
          ingress = [
            {
              from = "apiserver";
              ports = [ (tcp 8443) ];
            }
          ];
          egress = [
            { to = "dns"; }
            { to = "apiserver"; }
          ];
        };
        deployment = operandPolicy "cdi-deployment" operandSelectors.deployment {
          egress = [
            { to = "dns"; }
            { to = "apiserver"; }
            {
              to = "all-pods";
              ports = [ (tcp 8443) ];
            }
          ];
        };
        uploadProxy = operandPolicy "cdi-uploadproxy" operandSelectors.uploadProxy {
          ingress = [
            {
              from = "all-pods";
              ports = [ (tcp 8443) ];
            }
          ];
          egress = [
            { to = "dns"; }
            { to = "apiserver"; }
            {
              to = "all-pods";
              ports = [ (tcp 8443) ];
            }
          ];
        };
      };

      root = {
        resource = self.deployment;
        requires = [
          self.cdiCR
          self.crds.dataVolumes
        ]
        ++ builtins.filter (p: p != null) (builtins.attrValues self.operandPolicies);

        out = {
          crds.DataVolume = self.crds.dataVolumes;
          inherit
            mkDataVolume
            mkImporterPolicy
            mkUploadServerPolicy
            mkClonerPolicy
            ;
          operandSelectors = {
            inherit (operandSelectors)
              importer
              uploadServer
              cloner
              deployment
              uploadProxy
              ;
          };
          extraImages = builtins.attrValues operandRefs;
        };
      };
    };
}
