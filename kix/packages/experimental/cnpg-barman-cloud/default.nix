# cnpg-barman-cloud: the Barman Cloud plugin for CloudNativePG
# (plugin-barman-cloud), which archives WAL and takes base backups of
# CloudNativePG clusters to object storage.
#
# The package applies the barmancloud.cnpg.io ObjectStore definition
# (crds/, vendored from the release manifest), the plugin's ClusterRole and
# leader-election Role (rbac/, from the same manifest), a self-signed
# cert-manager Issuer with a server and a client Certificate, the plugin
# Deployment, and its Service.
#
# The CloudNativePG operator finds the plugin by the Service: it reads
# Services in its own namespace that carry the label cnpg.io/pluginName and
# the annotations naming the two certificate Secrets and the port
# (internal/controller/plugin_controller.go upstream), and dials the
# Service over mutual TLS, verifying the server certificate for the
# Service's name. The plugin therefore runs in the operator's namespace; an
# instance in another namespace is refused. When a Cluster enables the
# plugin, the operator asks it to add a sidecar to each instance pod, and
# that sidecar archives WAL, takes base backups, and applies retention. The
# plugin also creates a Role and RoleBinding in each such Cluster's
# namespace so the sidecar can read the ObjectStore and its Secrets.
#
# A cluster runs one instance (`conflictsWith`): the plugin's name
# (barman-cloud.cloudnative-pg.io) and its leader-election lease are fixed
# in the binary, and the definition and ClusterRole are cluster-wide.
#
# Minimal instance, beside the operator:
#
#   instances.cnpg-system.cnpg-barman-cloud.package = packages.experimental.cnpg-barman-cloud;
#
# A cnpg-cluster with `backup` set takes this instance as its `barmanCloud`
# dependency.
#
# Dependencies:
#   cnpgOperator (required)  the cnpg-operator instance, in this namespace.
#                            The package opens its pods' traffic to the
#                            plugin.
#   certManager (required)   the cert-manager instance whose Issuer and
#                            Certificate handles the package builds from.
#
# Replicas: from the cluster's availability level, one at `none` and two
# above it. Every pod serves the gRPC port, and the Service spreads the
# operator's calls across them. Only the pod that holds the leader lease
# reconciles ObjectStores. There is no `replicas` option. Set the
# instance's `availability` to change the count. The Deployment keeps
# upstream's Recreate strategy, so every deploy that changes the pod stops
# the plugin briefly, whatever the count. While no plugin pod is ready, the
# operator cannot reconcile a Cluster that uses it or create its instance
# pods. WAL archiving runs in the sidecar and goes on.
#
# Upgrades: 0.16 reads the ObjectStores, base backups, and WAL that 0.15
# wrote. Upstream needs no step to upgrade between these releases
# (web/docs/upgrades.mdx) and says nothing about going back. Going back to
# 0.15 works for an ObjectStore that uses no field 0.16 added: the plugin
# and the sidecars restart on 0.15, and archiving and backups go on. The
# 0.15 definition rejects `zstd` base backup compression, and it does not
# know `s3AddressingStyle` or `s3Credentials.sseCustomerKey`, so the API
# server rejects or drops them. Remove those fields from every ObjectStore
# before going back.
#
# Escape hatches: `extraArgs` (the operator subcommand's flags, such as
# `--log-level`), `env`, and the instance's `partsOverlays`.
#
# `out`:
#   out.mkObjectStore scope { name; spec; requires ? [ ]; }
#       Builds an ObjectStore in the caller's namespace, which must be the
#       namespace of the Cluster that uses it. Refuses a `{ name; key; }`
#       Secret selector anywhere in the spec whose name is a literal string,
#       so each credential comes from a secret dependency's `keyRef`. There
#       is no `out.crds.ObjectStore` handle.
#   out.pluginName  the plugin's name for a Cluster's `spec.plugins` and a
#                   backup's `pluginConfiguration`. It carries the plugin
#                   Deployment, so a resource that names it waits for the
#                   plugin.
#   out.extraImages the sidecar image.
#   out.version     the plugin version `image.tag` names.
#
# Limits: the plugin's metrics endpoint stays off and the package ships no
# alerts. The vendored ClusterRole lets the plugin read and write Secrets
# in every namespace, as upstream ships it.
#
# root = the plugin Deployment.
#
# Moving to another release: set `release` and the digests of `image` and
# `sidecar.image` (`crane digest ghcr.io/cloudnative-pg/plugin-barman-cloud:<release>`
# and `...-sidecar:<release>`), move the tag in crds/sources.txt and
# rbac/sources.txt, run `uv run scripts/vendor-crds.py cnpg-barman-cloud`,
# and compare the Deployment, Service, and Certificates below with the
# release manifest.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # meta.version, the default image tags, and the tag in crds/sources.txt
  # and rbac/sources.txt.
  release = "v0.16.0";

  name = scope.instanceName;
  ns = scope.namespaceName;

  readJSON = file: builtins.fromJSON (builtins.readFile file);

  # Fixed in the plugin binary (internal/cnpgi/metadata/constants.go
  # upstream); the operator keys plugins by it.
  pluginName = "barman-cloud.cloudnative-pg.io";
  grpcPort = 9090;
  # controller-runtime's health probe server (--health-probe-bind-address).
  healthPort = 8081;

  serverSecretName = "${name}-server-tls";
  clientSecretName = "${name}-client-tls";

  # Every `{ name; key; }` Secret selector in an ObjectStore spec, with its
  # path. A selector whose name has no string context was typed as a
  # literal.
  secretSelectors =
    path: v:
    if builtins.isAttrs v then
      if
        v ? name
        && v ? key
        && builtins.isString v.name
        &&
          builtins.attrNames v == [
            "key"
            "name"
          ]
      then
        [
          {
            inherit path;
            inherit (v) name key;
            literal = !builtins.hasContext v.name;
          }
        ]
      else
        lib.concatLists (lib.mapAttrsToList (k: secretSelectors "${path}.${k}") v)
    else if builtins.isList v then
      lib.concatLists (lib.imap0 (i: secretSelectors "${path}[${toString i}]") v)
    else
      [ ];
in
{
  meta = {
    version = release;
    description = "Barman Cloud plugin for CloudNativePG: WAL archiving and base backups to object storage";
    owner = "platform";
    defaultAliases = [ "barmanCloud" ];
    conflictsWith = [ "cluster:barmanCloud" ];
    # The plugin states only a minimum: `minKubeVersion` in the
    # ClusterServiceVersion of its OLM bundle
    # (config/olm/bases/plugin-barman-cloud.clusterserviceversion.yaml
    # upstream). The cnpgOperator dependency carries CloudNativePG's own,
    # narrower range. Move the bound with `release`.
    k8s = {
      minVersion = "1.31";
      reason = "plugin-barman-cloud ${release} supports Kubernetes 1.31 and later";
    };
  };

  assertions =
    { config, ... }:
    [
      (kix.image.checkRelease {
        inherit (config) image;
        inherit release;
        reason = "the CRD in kix/packages/experimental/cnpg-barman-cloud/crds and the RBAC roles in its rbac directory come from plugin-barman-cloud ${release}";
        fix = "To update this package to another version, follow the instructions at the top of kix/packages/experimental/cnpg-barman-cloud/default.nix.";
      })
    ]
    # A sidecar that keeps image.tag is covered by the check on image.tag.
    ++ lib.optional (config.sidecar.image.tag != config.image.tag) (
      kix.image.checkRelease {
        inherit (config.sidecar) image;
        option = "sidecar.image";
        inherit release;
        reason = "the plugin requires a sidecar from the same release (plugin-barman-cloud ${release})";
      }
    );

  options = {
    image = kix.options.image {
      repository = "ghcr.io/cloudnative-pg/plugin-barman-cloud";
      tag = release;
      digest = "sha256:6404a416718bd7aad943c67a25a7bb20d0558b43edfeab0bf167f013ca435882";
      description = "Plugin image. Its major.minor must be the package's release.";
    };

    sidecar.image = kix.options.image {
      repository = "ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar";
      tag = release;
      digest = "sha256:c669259e20ed1e11fad821f735c396c19d929985aa05b9544b13ecc8b5a386d0";
      tagText = "config.image.tag";
      description = "Image of the sidecar the plugin adds to each instance pod of a Cluster that uses it (SIDECAR_IMAGE). Its major.minor must be the package's release.";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "50m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "256Mi";
      };
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--log-level=debug" ];
      description = "Extra flags of the plugin's `operator` subcommand. The flags the package sets are refused with the reason.";
    };

    env = kix.options.env // {
      description = "Extra environment variables of the plugin container. SIDECAR_IMAGE is set from `sidecar.image` and refused here.";
    };
  };

  config =
    { config, ... }:
    {
      sidecar.image.tag = lib.mkDefault config.image.tag;
    };

  build =
    {
      self,
      config,
      cnpgOperator,
      certManager,
      ...
    }:
    let
      operator =
        if cnpgOperator.out ? podSelector then
          cnpgOperator.out
        else
          scope.fail {
            package = "cnpg-barman-cloud";
            message = "the cnpgOperator dependency has no out.podSelector, as with an import. The package opens the operator's traffic to the plugin from it.";
            fix = "Wire a managed cnpg-operator instance with deps.cnpgOperator = ref.${ns}.<instance>.";
          };
      operatorNamespace = (scope.forService cnpgOperator).namespaceName;
      _sameNamespace =
        if operatorNamespace != ns then
          scope.fail {
            package = "cnpg-barman-cloud";
            message = "the cnpgOperator dependency runs in namespace ${operatorNamespace}, and CloudNativePG finds plugins only by Services in its own namespace.";
            fix = "Move this instance to ${operatorNamespace}.";
          }
        else
          null;

      certCrds =
        certManager.out.crds or (scope.fail {
          package = "cnpg-barman-cloud";
          message = "the certManager dependency has no out.crds, as with an import.";
          fix = "Wire a managed cert-manager instance with deps.certManager = ref.<namespace>.<instance>.";
        });

      sidecarImage = kix.image.ref config.sidecar.image;

      env = kix.mkEnvVars (
        kix.mergeEnv {
          inherit scope;
          owned = [
            {
              vars.SIDECAR_IMAGE = sidecarImage;
              from = "the sidecar.image option";
              fix = "Set sidecar.image instead.";
            }
          ];
        } config.env
      );

      args = [
        "operator"
        "--server-cert=/server/tls.crt"
        "--server-key=/server/tls.key"
        "--client-cert=/client/tls.crt"
        "--server-address=:${toString grpcPort}"
        "--health-probe-bind-address=:${toString healthPort}"
        "--leader-elect"
      ]
      ++ kix.guardArgs {
        inherit scope;
        owned = {
          "--server-cert" =
            "the package mounts the server certificate from the Certificate it issues; remove it.";
          "--server-key" = "the package mounts the server key from the Certificate it issues; remove it.";
          "--client-cert" =
            "the package issues the client certificate the operator presents and names it on the Service; remove it.";
          "--server-address" =
            "the Service and the readiness probe use port ${toString grpcPort}; remove it.";
          "--health-probe-bind-address" = "the liveness probe uses port ${toString healthPort}; remove it.";
          "--leader-elect" = "the package always enables leader election; remove it.";
          "--plugin-path" =
            "the operator dials the plugin over TCP through its Service, not through a socket; remove it.";
        };
      } config.extraArgs;

      certSecret =
        secretName: certificate:
        kix.untrackedRef {
          kind = "Secret";
          name = secretName;
          by = certificate;
        };
      serverSecret = certSecret serverSecretName self.serverCertificate;
      clientSecret = certSecret clientSecretName self.clientCertificate;

      tcp = port: {
        inherit port;
        protocol = "TCP";
      };
      netpol = scope.networkPolicyEnforcer.netpol;

      mkObjectStore =
        consumerScope: args:
        let
          what = "ObjectStore ${consumerScope.namespaceName}/${args.name}";
          literal = builtins.filter (s: s.literal) (secretSelectors "spec" (args.spec or { }));
          first = builtins.head literal;
        in
        if literal != [ ] then
          scope.fail {
            package = "cnpg-barman-cloud";
            message = "${what} names Secret \"${first.name}\" at ${first.path} by a literal string, so Kix neither orders the store after the Secret nor checks that it holds key \"${first.key}\".";
            fix = "Use (<secret dependency>.out.keyRef \"${first.key}\").valueFrom.secretKeyRef, or, for a Secret created outside Kix, name = kix.untrackedRef { name = \"${first.name}\"; kind = \"Secret\"; }.";
          }
        else
          consumerScope.mkCR self.crds.objectStores args;
    in
    builtins.seq _sameNamespace {
      # The plugin installs no definitions of its own.
      crds.objectStores = scope.mkCRD {
        spec = (readJSON ./crds/objectstores.barmancloud.cnpg.io.json).spec;
        # The sidecar in the instance pods dials the endpoint; the Cluster
        # that names the ObjectStore carries the address on to them.
        factBehavior.endpoint = "conduct";
        # Configuration only. The backups it points at outlive it.
        holdsData = false;
        usesAtLeast = _: { };
      };

      serviceAccount = scope.mkResource {
        apiVersion = "v1";
        kind = "ServiceAccount";
        inherit name;
      };

      clusterRole = scope.rbac.mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        roles.${name} = (readJSON ./rbac/clusterrole-plugin-barman-cloud.json).rules;
      };

      leaderElectionRole = scope.rbac.mkRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = ns;
          }
        ];
        roles."${name}-leader-election" =
          (readJSON ./rbac/role-barman-plugin-leader-election-role.json).rules;
      };

      # Each Certificate is self-signed: the operator trusts the server
      # certificate itself, and the plugin trusts the client certificate
      # itself (--client-cert).
      issuer = scope.mkCR certCrds.Issuer {
        name = "${name}-selfsigned";
        spec.selfSigned = { };
      };

      serverCertificate = scope.mkCR certCrds.Certificate {
        name = "${name}-server";
        spec = {
          secretName = serverSecretName;
          # The operator verifies the certificate for the Service's name.
          # Plain names: the Deployment mounts this certificate's Secret and
          # the Service selects the Deployment's pods, so a reference to the
          # Service would close a cycle.
          commonName = name;
          dnsNames = [ name ];
          usages = [ "server auth" ];
          issuerRef = {
            group = "cert-manager.io";
            kind = "Issuer";
            name = self.issuer.out.name;
          };
        };
      };

      clientCertificate = scope.mkCR certCrds.Certificate {
        name = "${name}-client";
        spec = {
          secretName = clientSecretName;
          commonName = "${name}-client";
          usages = [ "client auth" ];
          issuerRef = {
            group = "cert-manager.io";
            kind = "Issuer";
            name = self.issuer.out.name;
          };
        };
      };

      # The operator registers the plugin from this Service.
      service = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        labels."cnpg.io/pluginName" = pluginName;
        # The operator reads the Secrets by these names.
        annotations = {
          "cnpg.io/pluginServerSecret" = serverSecretName;
          "cnpg.io/pluginClientSecret" = clientSecretName;
          "cnpg.io/pluginPort" = toString grpcPort;
        };
        spec = {
          selector = self.deployment.out.selector;
          ports = [
            {
              name = "grpc";
              port = grpcPort;
              targetPort = grpcPort;
              protocol = "TCP";
            }
          ];
        };
      };

      deployment = scope.mkDeployment {
        inherit name;
        requires = [ self.crds.objectStores ] ++ builtins.attrValues self.clusterRole;
        spec = {
          # The operator calls the plugin each time it reconciles a Cluster
          # that uses it, and to add the sidecar to each new instance pod.
          # One lost pod stalls both, so `pod` is two.
          replicas = kix.availability.pick availability {
            none = 1;
            pod = 2;
            node = 2;
            zone = 2;
          };
          # Upstream's strategy. A rolling update would run two plugin
          # releases side by side, and upstream does not promise that the
          # operator can talk to both.
          strategy.type = "Recreate";
          selector.matchLabels = scope.selectorLabels;
          template = {
            metadata.labels = scope.selectorLabels;
            spec = {
              serviceAccount = self.serviceAccount;
              # The Kubernetes default, stated as reliability.gracefulShutdown
              # asks.
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                (
                  {
                    name = "barman-cloud";
                    image = kix.image.ref config.image;
                    inherit args env;
                    ports = [
                      (kix.port "grpc" grpcPort)
                      (kix.port "health" healthPort)
                    ];
                    readinessProbe = {
                      tcpSocket.port = grpcPort;
                      periodSeconds = 10;
                    };
                    livenessProbe.httpGet = {
                      path = "/healthz";
                      port = healthPort;
                    };
                    resources = config.resources;
                    # The image's user.
                    securityContext = {
                      allowPrivilegeEscalation = false;
                      capabilities.drop = [ "ALL" ];
                      readOnlyRootFilesystem = true;
                      runAsUser = 10001;
                      runAsGroup = 10001;
                    };
                    volumeMounts = [
                      {
                        name = "server";
                        mountPath = "/server";
                        readOnly = true;
                      }
                      {
                        name = "client";
                        mountPath = "/client";
                        readOnly = true;
                      }
                    ];
                  }
                  // lib.optionalAttrs (config.image.pullPolicy != null) {
                    imagePullPolicy = config.image.pullPolicy;
                  }
                )
              ];
              volumes = [
                {
                  name = "server";
                  secret.secretName = serverSecret;
                }
                {
                  name = "client";
                  secret.secretName = clientSecret;
                }
              ];
            };
          };
        };
      };

      # The operator dials the plugin through the Service it discovered,
      # which no pod spec names, so neither direction is derived.
      operatorIngress = kix.operandPolicy {
        inherit scope;
        name = "${name}-operator-ingress";
        spec = {
          endpointSelector.matchLabels = self.deployment.out.selector;
          ingress = [
            (netpol.mkCallerIngressRule {
              callerSelector = operator.podSelector;
              callerNamespace = ns;
              ports = [ (tcp grpcPort) ];
            })
          ];
        };
      };
      operatorEgress = kix.operandPolicy {
        inherit scope;
        name = "${name}-operator-egress";
        spec = {
          endpointSelector.matchLabels = operator.podSelector;
          egress = [
            (netpol.mkServiceEgressRule {
              selector = self.deployment.out.selector;
              namespace = ns;
              sourceNamespace = ns;
              ports = [ (tcp grpcPort) ];
            })
          ];
        };
      };

      root = {
        resource = self.deployment;
        requires = [
          self.service
        ]
        ++ builtins.filter (r: r != null) [
          self.operatorIngress
          self.operatorEgress
        ]
        ++ builtins.attrValues self.leaderElectionRole;
        out = {
          inherit mkObjectStore;
          pluginName = scope.augmentEdge [ self.deployment ] pluginName;
          extraImages = [ sidecarImage ];
          version = kix.image.version config.image;
        };
      };
    };
}
