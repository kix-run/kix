# cert-manager module options — the user-facing API surface.
#
# This file declares all configurable options for services.cert-manager.
# Resource construction and config wiring live in resources.nix.
#
# Source Helm chart: jetstack/cert-manager (v1.19.4)
#
# Option naming follows Helm's values.yaml structure where sensible, but
# flattened where the Helm nesting is gratuitous (e.g., global.rbac.create
# becomes rbac.create since there's no per-component rbac toggle).

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
  options.services.cert-manager = {

    # --- Controller options ---

    image = lib.mkOption {
      type = opts.imageSubmodule {
        repository = "quay.io/jetstack/cert-manager-controller";
        tag = "v1.19.4";
      };
      default = {};
      description = "Controller container image.";
    };

    replicaCount = lib.mkOption {
      type = types.int;
      default = 1;
      description = "Number of controller replicas.";
    };

    # Helm accepts any integer; cert-manager itself clamps to 0-6.
    logLevel = lib.mkOption {
      type = types.ints.between 0 6;
      default = 2;
      description = "Controller log verbosity (0 = quiet, 6 = trace).";
    };

    maxConcurrentChallenges = lib.mkOption {
      type = types.int;
      default = 60;
      description = "Maximum number of concurrent ACME challenges.";
    };

    # The ACME HTTP01 solver image — passed to controller as --acme-http01-solver-image.
    # Helm exposes this under acmesolver.image; we keep it here since the controller
    # is the only consumer.
    acmeSolverImage = lib.mkOption {
      type = opts.imageSubmodule {
        repository = "quay.io/jetstack/cert-manager-acmesolver";
        tag = "v1.19.4";
      };
      default = {};
      description = "ACME HTTP01 solver container image.";
    };

    resources = lib.mkOption {
      type = opts.resourcesSubmodule {};
      default = {};
      description = "Controller container resource requests/limits.";
    };

    leaderElection = lib.mkOption {
      type = types.submodule {
        options.namespace = lib.mkOption {
          type = types.str;
          default = "kube-system";
          description = "Namespace for leader election leases. Both controller and cainjector use this.";
        };
      };
      default = {};
    };

    serviceAccount = lib.mkOption {
      type = types.submodule {
        options = {
          create = lib.mkOption { type = types.bool; default = true; description = "Create ServiceAccounts for all components."; };
          automountServiceAccountToken = lib.mkOption { type = types.bool; default = true; };
        };
      };
      default = {};
    };

    rbac = lib.mkOption {
      type = types.submodule {
        options = {
          create = lib.mkOption { type = types.bool; default = true; description = "Create RBAC resources."; };
          aggregateClusterRoles = lib.mkOption {
            type = types.bool;
            default = true;
            description = "Create aggregated ClusterRoles (view, edit, cluster-view) for K8s default user-facing roles.";
          };
        };
      };
      default = {};
    };

    # Pod/container security contexts — same defaults across all components.
    # Uses the shared typed submodules from kixlib.options. Helm has per-component
    # overrides but they all default to the same values, so we share a single option.
    # If per-component overrides are needed later, add component-specific options
    # that override these.
    securityContext = lib.mkOption {
      type = opts.podSecurityContextSubmodule {};
      default = {};
      description = "Pod-level security context applied to all components.";
    };

    containerSecurityContext = lib.mkOption {
      type = opts.containerSecurityContextSubmodule {};
      default = {};
      description = "Container-level security context applied to all components.";
    };

    # Prometheus annotations on Services. When true, adds prometheus.io/*
    # annotations to all component Services for scraping.
    prometheus = lib.mkOption {
      type = types.submodule {
        options.enabled = lib.mkOption {
          type = types.bool;
          default = true;
          description = "Add Prometheus scrape annotations to Services.";
        };
      };
      default = {};
    };

    # --- Webhook options ---

    webhook = lib.mkOption {
      type = types.submodule {
        options = {
          image = lib.mkOption {
            type = opts.imageSubmodule {
              repository = "quay.io/jetstack/cert-manager-webhook";
              tag = "v1.19.4";
            };
            default = {};
          };
          replicaCount = lib.mkOption { type = types.int; default = 1; };
          resources = lib.mkOption {
            type = opts.resourcesSubmodule {};
            default = {};
            description = "Webhook container resource requests/limits.";
          };
          securePort = lib.mkOption {
            type = types.int;
            default = 10250;
            description = "Port for the webhook HTTPS server. 10250 is the kubelet port — works without extra firewall rules on most clusters.";
          };
          # K8s enforces max 30s for webhook timeouts. Using bounded int to catch
          # misconfigurations at eval time rather than at apply time.
          timeoutSeconds = lib.mkOption {
            type = types.ints.between 1 30;
            default = 30;
            description = "Timeout for webhook admission requests.";
          };
        };
      };
      default = {};
    };

    # --- CA Injector options ---

    cainjector = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption {
            type = types.bool;
            default = true;
            description = "Deploy the CA injector component. Required for automatic caBundle population in webhook configs.";
          };
          image = lib.mkOption {
            type = opts.imageSubmodule {
              repository = "quay.io/jetstack/cert-manager-cainjector";
              tag = "v1.19.4";
            };
            default = {};
          };
          replicaCount = lib.mkOption { type = types.int; default = 1; };
          resources = lib.mkOption {
            type = opts.resourcesSubmodule {};
            default = {};
            description = "CA injector container resource requests/limits.";
          };
        };
      };
      default = {};
    };

    # --- Startup API Check options ---

    startupapicheck = lib.mkOption {
      type = types.submodule {
        options = {
          enabled = lib.mkOption {
            type = types.bool;
            default = true;
            description = "Run a post-install Job to verify the cert-manager API is working.";
          };
          image = lib.mkOption {
            type = opts.imageSubmodule {
              repository = "quay.io/jetstack/cert-manager-startupapicheck";
              tag = "v1.19.4";
            };
            default = {};
          };
          resources = lib.mkOption {
            type = opts.resourcesSubmodule {};
            default = {};
            description = "Startupapicheck container resource requests/limits.";
          };
        };
      };
      default = {};
    };

    # --- Common chart options (enable, namespace, clusterDomain) ---
    # mkChartOptions defaults namespace to "default"; cert-manager conventionally
    # deploys to its own namespace but we match Helm's default of the release namespace.
  } // opts.mkChartOptions { description = "cert-manager"; };
}
