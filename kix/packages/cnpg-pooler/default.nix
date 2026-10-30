# cnpg-pooler: a PgBouncer connection pooler in front of a CloudNativePG
# cluster's primary, as one postgresql.cnpg.io Pooler of type `rw`.
#
# The operator creates a Deployment of PgBouncer pods and a Service, both
# named after the Pooler, in the cluster's namespace. By default PgBouncer
# authenticates each client with the client's own role through an auth
# query the operator sets up, so every role and database of the cluster is
# reachable through the pooler. The package references the Service, so
# consumers wait until a PgBouncer pod is ready and get network policy to
# the pooler pods.
#
# Apps reach the pooler through a cnpg-database that takes this instance as
# its postgres dependency. The database's role and database are still
# created on the cluster, and its `out.host` is the pooler's Service:
#
#   pg-pooler = {
#     package = packages.cnpg-pooler;
#     deps.postgres = ref.data.pg;
#   };
#   app-db = {
#     package = packages.cnpg-database;
#     deps.postgres = ref.data.pg-pooler;
#     config.passwordSource = ./secrets/app-db.yaml;
#     config.passwordHash = "...";
#   };
#
# The package claims no alias: `postgres` belongs to the cluster, so a
# cnpg-database names the pooler with a `ref`.
#
# Dependencies:
#   postgres (required)      a cnpg-cluster in this namespace. The package
#                            reads its Cluster's name and instance pod
#                            labels, so an import without out.clusterName
#                            is refused.
#   cnpgOperator (required)  the cnpg-operator whose Pooler handle the
#                            package builds from.
#   prometheus (optional)    a PodMonitor for PgBouncer's metrics (TCP
#                            9127) while `metrics.enabled`.
#
# Defaults: `instances` from the availability level (1 at none, 2 above),
# session pooling (`pgbouncer.poolMode`), PgBouncer 1.25.2, 100m CPU and
# 128Mi requested per pod.
#
# Placement: with more than one instance, the pods spread over nodes and
# zones as the availability level asks. The operator creates no
# PodDisruptionBudget for a Pooler, and neither does the package.
#
# Network policy: with an enforcer, the package opens the pooler pods' DNS
# and API server traffic and PostgreSQL (TCP 5432) from the pooler pods to
# the cluster's instance pods, at both ends. Clients get ingress through the
# Service reference. The pooler pods also carry the Cluster's cnpg.io/cluster
# label, so cnpg-cluster's policies for its operand pods select them too.
#
# Escape hatch: `extraSpec`, merged over the Pooler spec, for `pgbouncer`
# (`poolMode`, `parameters`, `pg_hba`), `serviceTemplate`, and
# `deploymentStrategy`. Setting `pgbouncer.authQuery`,
# `pgbouncer.authQuerySecret`, or `pgbouncer.serverTLSSecret` hands
# PgBouncer's authentication to the user: the operator then creates neither
# the auth role nor its query function (IsAutomatedIntegration in
# api/v1/pooler_funcs.go upstream). A Cluster whose client CA Secret has no
# private key needs them, because the operator cannot issue the auth role's
# client certificate. `cluster`, `type`, `instances`, and `template` are
# refused, and so is `monitoring.enablePodMonitor`, which has the operator
# create a PodMonitor outside Kix. The pod template goes through the
# instance's `partsOverlays.pooler`.
#
# Exposes, the fields cnpg-database reads from its postgres dependency:
#   out.name, out.fqdn, out.port  the pooler's Service (port 5432).
#   out.clusterName               the pooled Cluster's name.
#   out.selector                  the pooler pods' labels.
#   out.tls                       true: PgBouncer serves TLS with the
#                                 Cluster's server certificate.
#   out.extraImages               the PgBouncer image.
#
# Limits: one pooler type, `rw`, which sends every connection to the
# primary. The package ships no alerts.
#
# root = the Pooler.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  # meta.version and the default image.tag.
  release = "1.25.2";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "cnpg-pooler ${ns}/${name}";

  # The Pooler fields this package writes are those of CloudNativePG 1.30.
  supportedRelease = "1.30";

  postgresPort = 5432;
  # PgBouncer's exporter in the pooler pods (url.PgBouncerMetricsPort in
  # pkg/management/url/url.go upstream).
  metricsPort = 9127;

  # Pooler spec paths the package writes.
  locked = [
    [ "cluster" ]
    [ "type" ]
    [ "instances" ]
    [ "template" ]
  ];
in
{
  meta = {
    version = release;
    description = "PgBouncer connection pooler for a CloudNativePG cluster (Pooler)";
    owner = "platform";
  };

  assertions =
    { config, ... }:
    [
      {
        # The operator names the pooler's Deployment and Service after the
        # Pooler, and a Service name is a DNS-1035 label.
        assertion =
          builtins.stringLength name <= 63 && builtins.match "[a-z]([-a-z0-9]*[a-z0-9])?" name != null;
        message = "the operator names the pooler's Service after the instance, and \"${name}\" is not a DNS-1035 label of at most 63 characters (^[a-z]([-a-z0-9]*[a-z0-9])?$). Rename the instance.";
      }
      {
        assertion = !((config.extraSpec.monitoring or { }) ? enablePodMonitor);
        message = "extraSpec sets monitoring.enablePodMonitor, which has the operator create a PodMonitor that Kix does not track. Set metrics.enabled and wire a prometheus dependency instead.";
      }
    ];

  # An imported operator has no out.release; the build refuses it first.
  deps.cnpgOperator.assertions = dep: [
    {
      assertion = !(dep.out ? release) || lib.versions.majorMinor dep.out.release == supportedRelease;
      message = "this package writes the Pooler fields of CloudNativePG ${supportedRelease}, and the cnpgOperator dependency runs ${dep.out.release}. Update kix/packages/cnpg-pooler for that release.";
    }
  ];

  options = {
    instances = lib.mkOption {
      type = lib.types.ints.positive;
      # Every client connection passes through a pooler pod, so `pod` and up
      # keep a second one through a pod's restart.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };
      defaultText = lib.literalExpression "kix.availability.pick availability { none = 1; pod = 2; node = 2; zone = 2; }";
      description = "PgBouncer pods (`spec.instances`).";
    };

    image = kix.options.image {
      repository = "ghcr.io/cloudnative-pg/pgbouncer";
      tag = release;
      digest = "sha256:b15c428057d1ffbc19fb70496911a5f1a47066dcc1315bf794f4e85ade29e2e5";
      description = "PgBouncer image, the operator's default for CloudNativePG 1.30 (DefaultPgbouncerImage in pkg/versions/versions.go upstream).";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "500m";
        memory = "128Mi";
      };
    };

    metrics = kix.options.monitor;

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        pgbouncer = {
          poolMode = "transaction";
          parameters.max_client_conn = "500";
        };
      };
      description = ''
        Merged over the Pooler spec. Refused: `cluster`, `type`,
        `instances`, `template`, and `monitoring.enablePodMonitor`. The
        package sets `pgbouncer.poolMode` to `session`, which any client
        works with; under `transaction`, clients share server connections
        between transactions and must not depend on session state such as
        `SET` or advisory locks.
        `pgbouncer.authQuery`, `pgbouncer.authQuerySecret`, and
        `pgbouncer.serverTLSSecret` hand authentication to the user: the
        operator then sets up no auth role or query, and the user must
        create them on the Cluster.
      '';
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      postgres,
      cnpgOperator,
      prometheus ? null,
      ...
    }:
    let
      cluster =
        if postgres.out ? clusterName && postgres.out ? selector then
          postgres.out
        else
          throw "${who}: the postgres dependency publishes no out.clusterName, as with an import or a stackgres-cluster. A Pooler fronts a cnpg-cluster; wire one with deps.postgres = ref.${ns}.<instance>.";
      operator =
        if cnpgOperator.out ? crds then
          cnpgOperator.out
        else
          throw "${who}: the cnpgOperator dependency publishes no out.crds, as with an import. Wire a managed cnpg-operator instance with deps.cnpgOperator = ref.<namespace>.<instance>.";

      clusterNamespace = (scope.forService postgres).namespaceName;
      _sameNamespace =
        if clusterNamespace != ns then
          throw "${who}: the postgres dependency runs in namespace ${clusterNamespace}, and CloudNativePG reads a Pooler's Cluster from the Pooler's own namespace. Move this instance to ${clusterNamespace}."
        else
          null;

      # The labels the operator puts on the pooler pods
      # (pkg/specs/pgbouncer/deployments.go upstream).
      poolerSelector."cnpg.io/poolerName" = name;

      spread = lib.optionals (config.instances > 1) (
        kix.availability.spreadConstraints {
          level = availability;
          selector = poolerSelector;
          topology = clusterConfig.cluster.topology;
        }
      );

      baseSpec = {
        cluster.name = cluster.clusterName;
        type = "rw";
        inherit (config) instances;
        pgbouncer.poolMode = "session";
        template = {
          spec = {
            containers = [
              (
                {
                  name = "pgbouncer";
                  image = kix.image.ref config.image;
                  inherit (config) resources;
                }
                // lib.optionalAttrs (config.image.pullPolicy != null) {
                  imagePullPolicy = config.image.pullPolicy;
                }
              )
            ];
          }
          // lib.optionalAttrs (spread != [ ]) {
            topologySpreadConstraints = spread;
          };
        };
      };

      spec = kix.mergeGuarded {
        inherit who locked;
      } baseSpec config.extraSpec;

      # Read only when the scope has an enforcer (kix.operandPolicy).
      netpol = scope.networkPolicyEnforcer.netpol;
      postgresPorts = [
        {
          port = postgresPort;
          protocol = "TCP";
        }
      ];
    in
    builtins.seq _sameNamespace {
      pooler = scope.mkCR operator.crds.Pooler {
        inherit name spec;
      };

      service = scope.mkServiceRef {
        inherit name;
        selector = poolerSelector;
        ports = postgresPorts;
        requires = [ self.pooler ];
      };

      podMonitor =
        if config.metrics.enabled && prometheus != null then
          prometheus.out.mkPodMonitor scope {
            inherit name;
            spec = {
              selector.matchLabels = poolerSelector;
              podMetricsEndpoints = [
                (
                  {
                    # The scrape egress rule needs the number, because Kix
                    # does not see the operator's pods.
                    portNumber = metricsPort;
                  }
                  // lib.optionalAttrs (config.metrics.interval != null) { inherit (config.metrics) interval; }
                )
              ];
            };
            requires = [ self.pooler ];
          }
        else
          null;

      # The operator creates the pooler pods, so no policy is derived for
      # them, and the Pooler names its Cluster without an address.
      poolerEgress = kix.operandPolicy {
        inherit scope;
        name = "${name}-pooler-egress";
        spec = {
          endpointSelector.matchLabels = poolerSelector;
          egress = [
            netpol.dnsEgressRule
            netpol.apiServerEgressRule
            (netpol.mkServiceEgressRule {
              selector = cluster.selector;
              namespace = ns;
              sourceNamespace = ns;
              ports = postgresPorts;
            })
          ];
        };
      };
      instanceIngress = kix.operandPolicy {
        inherit scope;
        name = "${name}-pooler-to-instances";
        spec = {
          endpointSelector.matchLabels = cluster.selector;
          ingress = [
            (netpol.mkCallerIngressRule {
              callerSelector = poolerSelector;
              callerNamespace = ns;
              ports = postgresPorts;
            })
          ];
        };
      };

      root = {
        resource = self.pooler;
        requires = [
          self.service
        ]
        ++ builtins.filter (r: r != null) [
          self.podMonitor
          self.poolerEgress
          self.instanceIngress
        ];
        out = {
          inherit (self.service.out) name fqdn port;
          inherit (cluster) clusterName;
          selector = poolerSelector;
          tls = true;
          extraImages = [ (kix.image.ref config.image) ];
        };
      };
    };
}
