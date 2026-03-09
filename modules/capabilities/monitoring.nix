# modules/capabilities/monitoring.nix — capability interface for monitoring.
#
# Charts declare monitoring intent via capabilities.monitoring.*, providing input
# fields (serviceName, namespace, portName, selector, etc.). The submodule computes
# output metadata (labels, annotations) from its own inputs. Implementation modules
# (monitoring-prometheus.nix) read the inputs to create ServiceMonitor resources.
#
# Flow: chart → capabilities.monitoring.* (input) → submodule computes output →
#       chart reads output | implementation module reads inputs → manifests
#
# WHY OUTPUT IS COMPUTED IN THE SUBMODULE (not the implementation module):
# If an implementation module both reads FROM and writes TO capabilities.monitoring.*,
# the NixOS module system creates infinite recursion (attrsOf merges all definitions,
# including the implementation's contribution, which depends on the merged result).
# By computing output inside the submodule, each target's output depends only on
# its own inputs + cluster-level config — no cross-option cycle.
#
# KEY RULES:
# 1. Charts read output, never write it
# 2. Implementation modules NEVER read config.manifests to produce manifests
# 3. One implementation module per capability
# 4. Don't name a target "enabled" — attrsOf namespace collision
#
# DESIGN NOTES:
# - portName (string) is the primary port identifier — mkServiceMonitor needs it.
#   port (int) is optional, for future use (e.g., withMetrics combinator).
# - selector is kept — removing it would require selector inference.
# - interval is per-target — valkey may need different scrape intervals.
# - No per-target 'enabled' flag — charts use lib.mkIf on the whole declaration.

{
  lib,
  config,
  ...
}:

let
  types = lib.types;

  # Capture parent config for use inside the submodule closure.
  # Inside the submodule, `config` refers to the submodule's own config.
  parentConfig = config;

  capabilitySubmodule = types.submodule ({ config, ... }: {
    options = {
      # --- Input fields (charts write these) ---

      serviceName = lib.mkOption {
        type = types.str;
        description = "Name of the Kubernetes Service to scrape.";
      };

      namespace = lib.mkOption {
        type = types.str;
        description = "Namespace of the Service to scrape.";
      };

      portName = lib.mkOption {
        type = types.str;
        description = ''
          Name of the port on the Service to scrape. Must match a named
          port in the Service spec. This is the primary port identifier —
          mkServiceMonitor needs a string port name.
        '';
      };

      port = lib.mkOption {
        type = types.nullOr types.int;
        default = null;
        description = ''
          Numeric port for the metrics endpoint. Optional — portName is the
          primary identifier. Stored for future use (e.g., withMetrics combinator).
          Known duplication: this port is also hardcoded in the container spec.
          Unavoidable without withMetrics (deferred). See doc 12 / 10C.
        '';
      };

      path = lib.mkOption {
        type = types.str;
        default = "/metrics";
        description = "HTTP path for the metrics endpoint.";
      };

      interval = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Scrape interval override for this target. Null means use
          monitoring.defaultInterval. Per-target override allows services
          like valkey to have different scrape frequencies.
        '';
      };

      selector = lib.mkOption {
        type = types.attrsOf types.str;
        description = ''
          Label selector to match the target Service. Typically the chart's
          selector labels plus a component label. Kept because removing it
          would require selector inference, which is complex.
        '';
      };

      # --- Output fields (computed from inputs, read by charts) ---

      output = {
        labels = lib.mkOption {
          type = types.attrsOf types.str;
          default = {};
          description = ''
            Labels computed from inputs. Charts may READ these to merge into
            Service metadata (e.g., kix.monitoring/scrape label).
            Charts must NEVER write to output fields.
          '';
        };

        annotations = lib.mkOption {
          type = types.attrsOf types.str;
          default = {};
          description = ''
            Annotations computed from inputs. Charts may READ these to merge
            into Service metadata. Charts must NEVER write to output fields.
          '';
        };
      };
    };

    # Compute output from the submodule's own inputs + parent monitoring config.
    # This runs inside each target submodule — `config` here is the target's own
    # config (serviceName, portName, etc.), NOT the parent module config.
    # parentConfig.monitoring.enabled/provider gates the output computation.
    #
    # This avoids infinite recursion: the submodule reads its OWN inputs (no
    # cross-module dependency) and writes its OWN output. The implementation
    # module (monitoring-prometheus.nix) only reads capabilities.monitoring to
    # create manifests — it never writes back to capabilities.monitoring.
    config = lib.mkIf (parentConfig.monitoring.enabled && parentConfig.monitoring.provider == "prometheus") {
      output.labels = {
        "kix.monitoring/scrape" = "true";
      };
      output.annotations = {
        "kix.monitoring/port-name" = config.portName;
        "kix.monitoring/path" = config.path;
      } // lib.optionalAttrs (config.port != null) {
        "kix.monitoring/port" = toString config.port;
      };
    };
  });
in
{
  options = {
    # Cluster-level monitoring switches.
    monitoring.enabled = lib.mkOption {
      type = types.bool;
      default = false;
      description = ''
        Master switch for the monitoring capability system.
        When enabled, submodules compute output metadata and implementation
        modules materialize ServiceMonitors from declared capabilities.
        When disabled (default), capability declarations are inert.
      '';
    };

    monitoring.defaultInterval = lib.mkOption {
      type = types.str;
      default = "30s";
      description = ''
        Default scrape interval for all targets unless overridden per-target.
        Applies cluster-wide monitoring policy.
      '';
    };

    monitoring.provider = lib.mkOption {
      type = types.enum [ "prometheus" "none" ];
      default = "prometheus";
      description = ''
        Which monitoring backend to use. "prometheus" enables output computation
        in capability submodules and ServiceMonitor creation in the implementation
        module. "none" disables both — capabilities are declared but not materialized.
      '';
    };

    # Capability submodule — charts declare intent here.
    capabilities.monitoring = lib.mkOption {
      type = types.attrsOf capabilitySubmodule;
      default = {};
      description = ''
        Monitoring capabilities declared by chart modules. Each chart adds its
        own entry (e.g., capabilities.monitoring.coredns). Output metadata is
        computed within the submodule; implementation modules read inputs to
        create ServiceMonitor resources.

        Do NOT name a target "enabled" — attrsOf namespace collision.
      '';
    };
  };
}
