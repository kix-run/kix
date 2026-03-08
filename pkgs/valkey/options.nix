# Valkey module options — the user-facing API surface.
#
# This file declares all configurable options for services.valkey.
# Resource construction and config wiring live in resources.nix.

{
  lib,
  kixlib,
  ...
}:

let
  types = lib.types;
  opts = kixlib.options;

in
{
  options.services.valkey = {
    # --- Images ---

    image = lib.mkOption {
      type = opts.imageSubmodule {
        repository = "docker.io/bitnami/valkey";
        tag = "8.1.1-debian-12-r0";
      };
      default = {};
      description = "Valkey container image.";
    };

    # --- Auth ---
    # Valkey auth is always via an existing secret. We never generate secrets.

    auth = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
          existingSecret = lib.mkOption {
            type = types.str;
            default = "";
            description = "Name of existing secret containing valkey-password key. If empty, Helm would auto-generate (we don't support that).";
          };
          existingSecretPasswordKey = lib.mkOption {
            type = types.str;
            default = "valkey-password";
          };
          sentinel = lib.mkOption {
            type = types.bool;
            default = true;
            description = "Whether sentinel uses auth too.";
          };
        };
      };
      default = {};
    };

    # --- Configuration ---

    commonConfiguration = lib.mkOption {
      type = types.str;
      default = ''
        # Enable AOF https://valkey.io/docs/topics/persistence.html
        appendonly yes
        # Disable RDB persistence, AOF persistence already enabled.
        save ""'';
      description = "Common valkey.conf content applied to all nodes.";
    };

    primary = lib.mkOption {
      type = types.submodule {
        options = {
          configuration = lib.mkOption { type = types.str; default = ""; };
          disableCommands = lib.mkOption {
            type = types.listOf types.str;
            default = [ "FLUSHDB" "FLUSHALL" ];
          };
          resources = lib.mkOption {
            type = opts.resourcesSubmodule {
              defaultRequests = { cpu = "100m"; memory = "128Mi"; ephemeral-storage = "50Mi"; };
              defaultLimits = { cpu = "150m"; memory = "192Mi"; ephemeral-storage = "2Gi"; };
            };
            default = {};
          };
        };
      };
      default = {};
    };

    replica = lib.mkOption {
      type = types.submodule {
        options = {
          replicaCount = lib.mkOption { type = types.int; default = 3; };
          configuration = lib.mkOption { type = types.str; default = ""; };
          disableCommands = lib.mkOption {
            type = types.listOf types.str;
            default = [ "FLUSHDB" "FLUSHALL" ];
          };
          resources = lib.mkOption {
            type = opts.resourcesSubmodule {
              defaultRequests = { cpu = "100m"; memory = "128Mi"; ephemeral-storage = "50Mi"; };
              defaultLimits = { cpu = "150m"; memory = "192Mi"; ephemeral-storage = "2Gi"; };
            };
            default = {};
          };
          autoscaling = lib.mkOption {
            type = types.submodule {
              options = {
                hpa = lib.mkOption {
                  type = opts.hpaSubmodule { defaults = { maxReplicas = 11; }; };
                  default = {};
                };
              };
            };
            default = {};
            description = "Autoscaling options for replica pods.";
          };
        };
      };
      default = {};
    };

    # --- Sentinel ---

    sentinel = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption {
            type = types.bool;
            default = false;
            description = "Enable Sentinel for HA. Changes architecture from separate primary/replica to single node StatefulSet.";
          };
          quorum = lib.mkOption { type = types.int; default = 2; };
          primarySet = lib.mkOption { type = types.str; default = "myprimary"; };
          downAfterMilliseconds = lib.mkOption { type = types.int; default = 60000; };
          failoverTimeout = lib.mkOption { type = types.int; default = 180000; };
          parallelSyncs = lib.mkOption { type = types.int; default = 1; };
          configuration = lib.mkOption {
            type = types.str;
            default = "";
            description = "Extra sentinel.conf content.";
          };
          image = lib.mkOption {
            type = opts.imageSubmodule {
              repository = "docker.io/bitnami/valkey-sentinel";
              tag = "8.1.1-debian-12-r0";
            };
            default = {};
          };
          resources = lib.mkOption {
            type = opts.resourcesSubmodule {
              defaultRequests = { cpu = "100m"; memory = "128Mi"; ephemeral-storage = "50Mi"; };
              defaultLimits = { cpu = "150m"; memory = "192Mi"; ephemeral-storage = "2Gi"; };
            };
            default = {};
          };
        };
      };
      default = {};
    };

    # --- Persistence ---

    persistence = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
          size = lib.mkOption { type = types.str; default = "8Gi"; };
          storageClass = lib.mkOption { type = types.nullOr types.str; default = null; };
          accessModes = lib.mkOption { type = types.listOf types.str; default = [ "ReadWriteOnce" ]; };
        };
      };
      default = {};
    };

    # --- Security contexts ---

    podSecurityContext = lib.mkOption {
      type = types.attrsOf types.anything;
      default = {
        fsGroup = 1001;
        fsGroupChangePolicy = "Always";
      };
    };

    containerSecurityContext = lib.mkOption {
      type = types.attrsOf types.anything;
      default = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        readOnlyRootFilesystem = true;
        runAsGroup = 1001;
        runAsNonRoot = true;
        runAsUser = 1001;
        seccompProfile.type = "RuntimeDefault";
      };
    };

    # --- Optional features ---

    metrics = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = false; };
          image = lib.mkOption {
            type = opts.imageSubmodule {
              repository = "docker.io/bitnami/redis-exporter";
              tag = "1.70.0-debian-12-r2";
            };
            default = {};
          };
          resources = lib.mkOption {
            type = opts.resourcesSubmodule {
              defaultRequests = { cpu = "100m"; memory = "128Mi"; ephemeral-storage = "50Mi"; };
              defaultLimits = { cpu = "150m"; memory = "192Mi"; ephemeral-storage = "2Gi"; };
            };
            default = {};
          };
          serviceMonitor = lib.mkOption {
            type = opts.serviceMonitorSubmodule {};
            default = {};
          };
          podMonitor = lib.mkOption {
            type = opts.podMonitorSubmodule {};
            default = {};
            description = "PodMonitor targets pods directly instead of going through a Service.";
          };
          prometheusRule = lib.mkOption {
            type = opts.prometheusRuleSubmodule {};
            default = {};
            description = "PrometheusRule for alerting/recording rules.";
          };
        };
      };
      default = {};
    };

    # Matches Helm chart default: networkPolicy.enabled = true
    networkPolicy = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption { type = types.bool; default = true; };
        };
      };
      default = {};
    };

    # Matches Helm chart default: pdb.create = true
    pdb = lib.mkOption {
      type = opts.pdbSubmodule { defaults = { maxUnavailable = 1; }; };
      default = {};
    };
  } // opts.mkChartOptions { description = "Valkey"; };
}
