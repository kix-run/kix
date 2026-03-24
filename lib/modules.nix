# lib/modules.nix — NixOS module options for kix cluster definitions.
#
# Provides the option declarations used by buildCluster's evalModules.
# Each cluster is composed of modules that set these options.
# See v2_discussions/20_module_system_design.md for design rationale.

{ lib, ... }:
{
  options = {

    clusterLabels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Labels injected into every resource.";
    };

    clusterDomain = lib.mkOption {
      type = lib.types.str;
      default = "cluster.local";
      description = "Kubernetes cluster DNS domain. Used to construct resource FQDNs (e.g. svc.cluster.local).";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.attrsOf (
          lib.types.submodule {
            options = {
              package = lib.mkOption {
                type = lib.types.raw;
                description = ''
                  The package function. types.raw avoids recursive merge
                  processing that would break lib.fix in package evaluation.
                  Two modules declaring the same (ns, instance) is caught
                  by the submodule merge at the instance level.
                '';
              };
              aliases = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "Additional DI resolution keys (beyond the instance name).";
              };
              config = lib.mkOption {
                type = lib.types.deferredModule;
                default = { };
                description = ''
                  Instance configuration. Multiple modules can contribute
                  config to the same instance — they merge via deferredModule.
                  Use mkDefault/mkForce for priority control.
                '';
              };
              deps = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = { };
                description = ''
                  Explicit DI overrides. Keys are package function arg names.
                  Collision = error (two modules setting same dep for same
                  instance must be resolved explicitly).
                '';
              };
              partsOverlays = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = [ ];
                description = ''
                  Parts overlay functions (scope: self: base: attrset).
                  Applied in order after package evaluation. Multiple modules
                  contribute overlays — they concatenate.
                '';
              };
              version = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              labelStyle = lib.mkOption {
                type = lib.types.enum [
                  "kix"
                  "helm"
                ];
                default = "kix";
                description = ''
                  Label convention for selectors and metadata.
                  "kix" uses app.kubernetes.io/* keys.
                  "helm" uses app/release keys for Helm compatibility.
                '';
              };
              selectorLabels = lib.mkOption {
                type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
                default = null;
                description = ''
                  Override auto-generated selector labels. Use when the cluster has
                  immutable selectors (e.g. StatefulSet) that don't match the kix
                  or Helm naming convention.
                '';
              };
            };
          }
        )
      );
      default = { };
    };

    namespaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            labels = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
            };
            annotations = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
            };
            resourceQuota = lib.mkOption {
              type = lib.types.nullOr lib.types.anything;
              default = null;
            };
            networkPolicies = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
            };
          };
        }
      );
      default = { };
    };

    globalPartsOverlays = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = [ ];
      description = ''
        Parts overlay functions applied to ALL instances. Signature:
        scope → self → base → attrset. The overlay decides per-instance
        whether to act by inspecting base.
      '';
    };

    global = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = ''
        Cluster-wide configuration values. Packages read these via
        _kixOptions defaults that reference them.
      '';
    };
  };
}
