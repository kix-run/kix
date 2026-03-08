# cert-manager module options — the user-facing API surface.
#
# Returns chart-specific options only. Enable, namespace, and clusterDomain
# are added automatically by mkChartModule.
#
# Source Helm chart: jetstack/cert-manager (v1.19.4)

{ lib, kixlib, opts }:

let
  types = lib.types;
in
{
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
        description = "Namespace for leader election leases.";
      };
    };
    default = {};
  };

  serviceAccount = lib.mkOption {
    type = types.submodule {
      options = {
        create = lib.mkOption { type = types.bool; default = true; };
        automountServiceAccountToken = lib.mkOption { type = types.bool; default = true; };
      };
    };
    default = {};
  };

  rbac = lib.mkOption {
    type = types.submodule {
      options = {
        create = lib.mkOption { type = types.bool; default = true; };
        aggregateClusterRoles = lib.mkOption {
          type = types.bool;
          default = true;
          description = "Create aggregated ClusterRoles (view, edit, cluster-view).";
        };
      };
    };
    default = {};
  };

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
        };
        securePort = lib.mkOption {
          type = types.int;
          default = 10250;
        };
        timeoutSeconds = lib.mkOption {
          type = types.ints.between 1 30;
          default = 30;
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
          description = "Deploy the CA injector component.";
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
        };
      };
    };
    default = {};
  };
}
