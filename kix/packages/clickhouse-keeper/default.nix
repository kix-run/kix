# ClickHouse Keeper, a quorum run by the Altinity operator.
#
# One ClickHouseKeeperInstallation CR, built through the operator package's
# builder. The operator turns it into one StatefulSet per replica, the
# Services between them, and a PodDisruptionBudget. Three replicas is the
# default and the smallest quorum that survives losing one; the scorecard
# cannot see operator-created pods, so high availability has to be the
# default here and not something a rule reminds you of.
#
# The Service the operator creates (`keeper-<name>`) is described with a
# ServiceRef, not rendered a second time, so `out.host` carries dependency
# context and the endpoint fact: a ClickHouseInstallation that puts it in
# its spec waits for the quorum and gets the network policy edge.
#
# Traffic between the replicas (raft) runs between pods that no build
# knows about, so no address can carry that edge. The package states it as
# a policy over the operator's pod labels.
#
# DI deps:
#   clickhouseOperator (required)  the CRD and out.mkKeeperInstallation
#   storageClasses (optional)      storageClassName when the option is
#                                  unset; absent means the cluster default
#
# Exposes:
#   out.host    "keeper-<name>.<ns>.svc..." (the operator's Service)
#   out.port    "2181"
#
# root = the ServiceRef.

{
  scope,
  lib,
  kix,
}:
let
  name = scope.instanceName;
  clientPort = 2181;
in
{
  meta = {
    version = "26.3.32";
    description = "ClickHouse Keeper quorum via a ClickHouseKeeperInstallation CR";
    lifecycle = "stateful";
    defaultAliases = [ "clickhouseKeeper" ];
    k8s.minVersion = "1.25";
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/clickhouse/clickhouse-keeper";
      tag = "26.3.32.14";
      digest = "sha256:8dd3ed81719ae9467ad659d86b7af53a9ec5be6b50320f9ca84cf9c31dc7ccc8";
    };

    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = ''
        Keeper replicas: 1, or an odd number. Three is the smallest quorum
        that survives the loss of one. An even count is refused, since it
        survives no more losses than one fewer replica.
      '';
    };

    storage = {
      size = lib.mkOption {
        type = lib.types.str;
        default = "5Gi";
        description = "Volume per replica for the raft log and snapshots.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "StorageClass for the volumes. Null takes it from the storageClasses dep, or the cluster default.";
      };
    };

    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "256Mi";
      };
      limits = {
        cpu = "1";
        memory = "512Mi";
      };
    };

    extraSpec = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Merged over the ClickHouseKeeperInstallation spec the package builds.";
    };
  };

  build =
    {
      self,
      config,
      scope,
      kix,
      clickhouseOperator,
      storageClasses ? null,
      ...
    }:
    let
      # What the operator stamps on every pod of this installation.
      podSelector = clickhouseOperator.out.operandSelector.clickHouseKeeperInstallations name;

      storageClassName =
        if config.storage.storageClassName != null then
          config.storage.storageClassName
        else if storageClasses != null then
          storageClasses.out.storageClassName or null
        else
          null;

      baseSpec = {
        configuration.clusters = [
          {
            name = "keeper";
            layout.replicasCount = config.replicas;
          }
        ];
        defaults.templates = {
          podTemplate = "keeper";
          dataVolumeClaimTemplate = "data";
        };
        templates = {
          podTemplates = [
            {
              name = "keeper";
              spec = {
                # One replica per node where there are nodes to spread
                # over; still schedulable on a single-node cluster.
                affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution = [
                  {
                    weight = 100;
                    podAffinityTerm = {
                      topologyKey = "kubernetes.io/hostname";
                      labelSelector.matchLabels = podSelector;
                    };
                  }
                ];
                containers = [
                  {
                    name = "clickhouse-keeper";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    inherit (config) resources;
                  }
                ];
              };
            }
          ];
          volumeClaimTemplates = [
            {
              name = "data";
              spec = {
                accessModes = [ "ReadWriteOnce" ];
                resources.requests.storage = config.storage.size;
              }
              // lib.optionalAttrs (storageClassName != null) { inherit storageClassName; };
            }
          ];
        };
      };

      netpol = if scope.networkPolicyEnforcer == null then null else scope.networkPolicyEnforcer.netpol;
      mkOperandPolicy =
        suffix: spec:
        kix.operandPolicy {
          inherit scope;
          name = "${name}-keeper-${suffix}";
          spec = {
            endpointSelector.matchLabels = podSelector;
          }
          // spec;
        };
    in
    # Raft needs a majority. Two replicas stop when either one is lost, and
    # every ReplicatedMergeTree table on the servers goes read-only with them.
    if lib.mod config.replicas 2 == 0 then
      throw "clickhouse-keeper (${name}): replicas is ${toString config.replicas}. A Keeper quorum needs a majority, so an even count survives no more losses than one fewer replica. Set config.replicas to 1 or an odd number (3 survives the loss of one)."
    else
      {
        keeper = clickhouseOperator.out.mkKeeperInstallation scope {
          inherit name;
          spec = kix.mergeGuarded {
            who = "clickhouse-keeper (${name})";
            # The replica count is the quorum, the pod template carries
            # the image and the spread, the volume has its option.
            locked = [
              [
                "configuration"
                "clusters"
              ]
              [
                "templates"
                "podTemplates"
              ]
              [
                "templates"
                "volumeClaimTemplates"
              ]
            ];
          } baseSpec config.extraSpec;
        };

        service = scope.mkServiceRef {
          name = "keeper-${name}";
          selector = podSelector;
          ports = [
            {
              name = "zk";
              port = clientPort;
              protocol = "TCP";
            }
          ];
          requires = [ self.keeper ];
        };

        # Raft between the replicas, and name resolution for it.
        peerEgress = mkOperandPolicy "egress" {
          egress = [
            netpol.dnsEgressRule
            { toEndpoints = [ { matchLabels = podSelector; } ]; }
          ];
        };
        peerIngress = mkOperandPolicy "ingress" {
          ingress = [ { fromEndpoints = [ { matchLabels = podSelector; } ]; } ];
        };

        root = {
          resource = self.service;
          requires = [
            self.keeper
          ]
          ++ lib.optional (self.peerEgress != null) self.peerEgress
          ++ lib.optional (self.peerIngress != null) self.peerIngress;
          out = {
            host = self.service.out.fqdn;
            port = toString clientPort;
            extraImages = [ (kix.image.ref config.image) ];
          };
        };
      };
}
