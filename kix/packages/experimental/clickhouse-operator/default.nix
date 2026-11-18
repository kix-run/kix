# clickhouse-operator: the Altinity operator for ClickHouse.
#
# Replicated ClickHouse is not a StatefulSet Kix renders. It is a
# ClickHouseInstallation (CHI) the operator turns into StatefulSets, Services,
# and config at runtime, with a ClickHouseKeeperInstallation (CHK) beside it
# for coordination. This package owns the four CRDs (crds.nix, from the table
# in kinds.nix) and the controller (operator.nix). The sibling packages build
# one CR each through the builders below and never spell a kind string.
#
# Configuration is the operator's own vocabulary. `operatorConfig` is its
# config.yaml as a Nix attrset, merged over the few keys this package has to
# set. `files` are the ClickHouse and Keeper config fragments the operator
# copies into every operand pod, kept verbatim from upstream under ./files.
#
# One replica, and it stays that way: the operator has no leader election,
# so two of them would reconcile the same installation against each other.
# Operand pods keep serving while it is away.
#
# Dependencies:
#   credentials (required)  a secret or secret-ref instance with `username`
#                           and `password` keys. The operator logs in to
#                           every server it manages with them (port 8123) to
#                           propagate schema and collect metrics, and it
#                           creates that user in each installation itself.
#                           Without the Secret it falls back to a password
#                           compiled into the binary, so the dep is required
#                           and this package ships no default.
#   prometheus (optional)   ServiceMonitor on both metrics ports, and the
#                           alerts below
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the series of the Service
# `<instance>-metrics`.
#   ClickHouseOperatorDown (warning)              neither container of the
#                                                 operator pod answers a
#                                                 scrape. Installations keep
#                                                 serving; changes to them
#                                                 are not applied.
#   ClickHouseOperatorReconcileAborted (warning)  the operator aborted more
#                                                 reconciles of a
#                                                 ClickHouseInstallation than
#                                                 it completed in the last
#                                                 24 hours.
# The operator counts no reconciles of a ClickHouseKeeperInstallation
# (pkg/controller/chk/metrics upstream), so a failed one shows only in the
# CR's status, and the deploy waits on it. The health of each server is
# left to clickhouse-cluster's alerts, which read the servers' own
# endpoint, and of Keeper to clickhouse-keeper's.
#
# `out`:
#   out.mkClickHouseInstallation scope { name; spec; }
#   out.mkKeeperInstallation scope { name; spec; }
#       CR builders. The CR waits for its CRD and for the operator
#       Deployment, carries the readiness convention
#       (status.status == "Completed"), and carries the operand pod selector
#       netpol needs. The installation builder refuses a user field in the
#       `k8s_secret_` syntax, which the operator no longer reads.
#   out.operandSelector.<kind> <crName>
#       The labels the operator stamps on that installation's pods, from
#       kinds.nix, for the policies the CR packages write over them.
#   out.podSelector
#       The operator's own pods, with dependency context.
#   out.version
#       The operator version `image.tag` names.
#
# Upgrades: 0.27.4 takes over the installations 0.27.3 created. It keeps
# the ClickHouse pods and replaces each Keeper pod once, one at a time, so
# the quorum holds. Until it has reconciled each installation, about a
# minute, it cannot log in to the servers, because their config still
# allows the old operator pod's address only. To go back, deploy the older
# package. 0.27.3 then recreates every StatefulSet of both kinds, because
# their volumeClaimTemplates differ and cannot be updated in place, so
# every ClickHouse and Keeper pod restarts once. The volumes and their data
# stay.
#
# root = the operator Deployment.

{
  scope,
  lib,
  kix,
}:
let
  inherit (import ./kinds.nix) crdDefs;
  # The operator and its metrics exporter are released in lockstep under
  # one version. Both declared tags come from this binding, so the exporter
  # keeps its default digest until the instance moves `image.tag`.
  release = "0.27.4";
  credentialKeys = [
    "username"
    "password"
  ];
in
{
  meta = {
    version = release;
    description = "Altinity ClickHouse operator: ClickHouseInstallation and ClickHouseKeeperInstallation controller";
    defaultAliases = [ "clickhouseOperator" ];
    # One operator watches every namespace, so consumers in any namespace
    # find it by name.
    scope = "cluster";
    k8s = {
      minVersion = "1.25";
      reason = "Altinity clickhouse-operator ${release} supports Kubernetes 1.25 and later. Move the cluster to a supported Kubernetes version first";
    };
  };

  deps = {
    credentials.assertions =
      dep:
      let
        declared = dep.out.keys or [ ];
        missing = builtins.filter (k: !(builtins.elem k declared)) credentialKeys;
      in
      lib.optional (missing != [ ]) {
        assertion = false;
        message = "clickhouse-operator reads the `username` and `password` keys of its credentials secret to log in to the servers it manages, and the resolved secret declares: ${lib.concatStringsSep ", " declared}. Add ${
          lib.concatMapStringsSep " and " (k: "`${k}`") missing
        } to that instance's keys.";
      };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/altinity/clickhouse-operator";
      tag = release;
      digest = "sha256:c60c872fedd85017f843167dfdd2b900bb06b668a3deaf02b21782e59af859e3";
    };

    # Second container of the operator pod. It serves the ClickHouse metrics
    # of every installation on one endpoint (8888) by querying each server on
    # every scrape. Released in lockstep with the operator, so its tag
    # follows `image.tag` (see `config` below).
    metricsExporterImage = kix.options.image {
      repository = "docker.io/altinity/metrics-exporter";
      tag = release;
      tagText = "config.image.tag";
      digest = "sha256:d257a72e6a6a9e1a9768b7a5a231b56901ea6dee668e41c7243b78bd298f631a";
    };

    operatorConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        watch.namespaces.include = [ "analytics" ];
        reconcile.runtime.reconcileCHIsThreadsNumber = 2;
      };
      description = ''
        The operator's config.yaml, merged over the package's own (see
        `builtinOperatorConfig` in operator.nix). Set a key to null to remove
        it from the package's own, which hands that setting back to the
        operator's compiled-in default. `clickhouse.access.secret` comes from
        the credentials dep.
      '';
    };

    files = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.attrsOf (lib.types.nullOr lib.types.str)));
      default = { };
      example = {
        chi."config.d"."50-limits.xml" =
          "<clickhouse><max_concurrent_queries>200</max_concurrent_queries></clickhouse>";
        chi."config.d"."01-clickhouse-02-logger.xml" = null;
      };
      description = ''
        Config fragments the operator injects into every operand pod, as
        `<chi|chk>.<directory>.<file name> = contents`. The directories are
        the operator's: `conf.d`, `config.d`, `templates.d`, and `users.d`
        for chi; `conf.d`, `keeper_config.d`, `templates.d`, and `users.d` for
        chk. Merged over the upstream files under ./files, and null removes
        one of those. A fragment for a single installation belongs in that
        CR's `spec.configuration.files`.
      '';
    };

    resources = kix.options.resources {
      requests = {
        cpu = "50m";
        memory = "128Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
      description = ''
        Resources of the operator container. Upstream sets none. The operator
        holds every installation it watches in memory, with the normalized
        copy beside it, so the memory limit grows with their count and size.
      '';
    };

    metricsExporterResources = kix.options.resources {
      requests = {
        cpu = "20m";
        memory = "64Mi";
      };
      limits = {
        cpu = "250m";
        memory = "256Mi";
      };
      description = "Resources of the metrics-exporter container. Its work per scrape is one round of queries per ClickHouse host.";
    };

    metrics = kix.options.monitor;
  };

  config =
    { config, ... }:
    {
      metricsExporterImage.tag = lib.mkDefault config.image.tag;
    };

  build = [
    ./crds.nix
    ./operator.nix
    (
      { self, config, ... }:
      let
        # The typed builder already makes the CR wait for its CRD and stamps
        # readiness and fact behavior on it. The CR also has to wait for the
        # operator Deployment: a CR applied to a cluster with the CRD and no
        # controller is accepted and never reconciled, and the deploy would
        # spend its whole timeout on a status nobody is there to write.
        mkOperand =
          part: consumerScope: args:
          self.crds.${part}.out.mkCR consumerScope (
            args
            // {
              requires = (args.requires or [ ]) ++ [ self.operatorDeployment ];
            }
          );

        # Return the `spec.configuration.users` fields that use the
        # `k8s_secret_` or `k8s_secret_env_` syntax. The operator dropped
        # it in 0.27.4 and aborts the reconcile of an installation that
        # still has it, so the build refuses it first. A user's fields are
        # written flat ("alice/k8s_secret_password") or nested, and the
        # first path segment is the user's name.
        removedSecretRefs =
          spec:
          let
            paths =
              prefix: attrs:
              lib.concatLists (
                lib.mapAttrsToList (
                  key: value:
                  let
                    path = prefix ++ lib.splitString "/" key;
                  in
                  if builtins.isAttrs value then paths path value else [ path ]
                ) attrs
              );
          in
          map (lib.concatStringsSep "/") (
            builtins.filter (path: builtins.any (lib.hasPrefix "k8s_secret_") (lib.drop 1 path)) (
              paths [ ] (spec.configuration.users or { })
            )
          );

        mkClickHouseInstallation =
          consumerScope: args:
          let
            removed = removedSecretRefs (args.spec or { });
          in
          if removed != [ ] then
            consumerScope.fail {
              id = "K7577";
              message = "ClickHouseInstallation ${args.name} sets ${lib.concatStringsSep ", " removed} in spec.configuration.users. clickhouse-operator ${release} no longer reads the k8s_secret_ and k8s_secret_env_ syntax, and it stops reconciling an installation that uses it.";
              fix = "Replace each field with the same field without the prefix, set to `valueFrom.secretKeyRef = { name = <Secret>; key = <key>; }`. The Secret must be in the installation's namespace. For example, replace \"alice/k8s_secret_password\" = \"alice-secret/password\" with \"alice/password\".valueFrom.secretKeyRef = { name = \"alice-secret\"; key = \"password\"; }.";
            }
          else
            mkOperand "clickHouseInstallations" consumerScope args;
      in
      {
        root = {
          resource = self.operatorDeployment;
          requires = [ self.operatorService ];

          out = {
            version = kix.image.version config.image;
            inherit mkClickHouseInstallation;
            mkKeeperInstallation = mkOperand "clickHouseKeeperInstallations";
            # The pods of an installation, by the label kinds.nix says the
            # operator stamps, so the CR packages and crds.nix's
            # factBehavior cannot drift apart.
            operandSelector = lib.mapAttrs (_: def: crName: { ${def.operandLabel} = crName; }) (
              lib.filterAttrs (_: def: def.operand) crdDefs
            );
            # The operator's own pods. An installation needs it to let the
            # operator in: the operator dials every server on 8123 to
            # propagate schema and to read metrics, and those servers are
            # pods no build knows about, so no address carries the edge.
            podSelector = self.operatorDeployment.out.selector;
            # ClickHouseInstallationTemplate and
            # ClickHouseOperatorConfiguration get no builder until something
            # in Kix writes one. `operatorConfig` covers what the second is
            # for.
          };
        };
      }
    )

    # The Service carries both ports. The primary endpoint is the operator's
    # own metrics; the second is every installation's ClickHouse metrics,
    # relayed by the exporter.
    (
      let
        ns = scope.namespaceName;
        sel = ''namespace="${ns}",service="${scope.instanceName}-metrics"'';
        aborted = "sum by (namespace, service, exported_namespace, chi) (increase(clickhouse_operator_chi_reconciles_aborted{${sel}}[24h]))";
        completed = "sum by (namespace, service, exported_namespace, chi) (increase(clickhouse_operator_chi_reconciles_completed{${sel}}[24h]))";
        operator = "ClickHouse operator ${ns}/${scope.instanceName}";
      in
      kix.monitor {
        service = "operatorService";
        port = "op-metrics";
        extraEndpoints = [
          {
            port = "ch-metrics";
            path = "/metrics";
            scheme = "http";
          }
        ];
        alerts = {
          ClickHouseOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The ClickHouse operator is down.";
            description = "Neither the operator nor its metrics exporter in the pod of the ${operator} has answered a scrape for 10 minutes. ClickHouse installations keep serving, but changes to ClickHouseInstallations and ClickHouseKeeperInstallations are not applied. Check the operator Deployment in ${ns}.";
          };
          # The operator labels these series with the installation's own
          # namespace, which the scrape renames to exported_namespace
          # (pkg/metrics/operator/labels.go upstream). An aborted
          # installation sees no new reconcile until its spec changes or a
          # host recovers, so the counters stop moving. The 24h window keeps
          # the alert firing for a day after the abort; a completed reconcile
          # in that day clears it. The operator creates the completed series
          # at zero with the first reconcile. The right side still falls back
          # to zero, so the rule holds for a scrape that lost that series.
          ClickHouseOperatorReconcileAborted = {
            expr = "${aborted} > (${completed} or ${aborted} * 0)";
            "for" = "15m";
            severity = "warning";
            summary = "The ClickHouse operator aborted the reconcile of a ClickHouseInstallation.";
            description = "The ${operator} aborted more reconciles of ClickHouseInstallation {{ $labels.exported_namespace }}/{{ $labels.chi }} than it completed in the last 24 hours, so its servers may not match its spec. The operator does not retry until the spec changes or a host recovers. Check the status and events of the ClickHouseInstallation and the operator log.";
          };
        };
      }
    )
  ];
}
