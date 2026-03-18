# Tailscale subnet router package.
#
# Config-driven: each entry in `routers` produces a StatefulSet + Secret
# pair that runs tailscaled advertising the specified routes.
#
# Resources (per router): StatefulSet, Secret (auth key).
# Shared resources: ServiceAccount, Role, RoleBinding.
#
# main = ServiceAccount (shared root; all routers depend on it)

{
  scope,
  config,
  lib,
}:

let
  name = scope.instanceName;

  cfg = scope.defaults config {
    image = {
      repository = "ghcr.io/tailscale/tailscale";
      tag = "v1.78.3";
      pullPolicy = "IfNotPresent";
    };
    routers = { };
    resources = {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "500m";
        memory = "256Mi";
      };
    };
  };

  selectorLabels = {
    "app.kubernetes.io/name" = "tailscale";
    "app.kubernetes.io/instance" = name;
  };

  # Build per-router resources. Takes `self` from the fixpoint.
  mkRouter =
    self: routerName: routerCfg:
    let
      routerLabels = selectorLabels // {
        "app.kubernetes.io/component" = routerName;
      };
      hostname = routerCfg.hostname or "${name}-${routerName}";
      routes = builtins.concatStringsSep "," routerCfg.routes;
    in
    {
      secret = scope.mkResource {
        apiVersion = "v1";
        kind = "Secret";
        name = "${name}-${routerName}-auth";
        labels = routerLabels;
        extra.type = "Opaque";
        extra.stringData = {
          AUTH_KEY = routerCfg.authKeySecret;
        };
      };

      statefulSet = scope.mkResource {
        apiVersion = "apps/v1";
        kind = "StatefulSet";
        name = "${name}-${routerName}";
        labels = routerLabels;
        spec = {
          replicas = routerCfg.replicas or 1;
          serviceName = "${name}-${routerName}";
          selector.matchLabels = routerLabels;
          template = {
            metadata.labels = routerLabels;
            spec = {
              serviceAccountName = "${self.serviceAccount}";
              terminationGracePeriodSeconds = 60;
              securityContext = {
                runAsNonRoot = false;
                seccompProfile.type = "RuntimeDefault";
              };
              initContainers = [
                {
                  name = "sysctler";
                  image = "busybox:1.36";
                  command = [
                    "/bin/sh"
                    "-c"
                    "sysctl -w net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1"
                  ];
                  securityContext = {
                    privileged = true;
                  };
                }
              ];
              containers = [
                {
                  name = "tailscale";
                  image = "${cfg.image.repository}:${cfg.image.tag}";
                  imagePullPolicy = cfg.image.pullPolicy;
                  env = [
                    {
                      name = "TS_KUBE_SECRET";
                      value = "${name}-${routerName}-state";
                    }
                    {
                      name = "TS_USERSPACE";
                      value = "false";
                    }
                    {
                      name = "TS_AUTHKEY";
                      valueFrom.secretKeyRef = {
                        name = "${name}-${routerName}-auth";
                        key = "AUTH_KEY";
                      };
                    }
                    {
                      name = "TS_ROUTES";
                      value = routes;
                    }
                    {
                      name = "TS_HOSTNAME";
                      value = hostname;
                    }
                    {
                      name = "TS_EXTRA_ARGS";
                      value = "--advertise-routes=${routes}";
                    }
                    {
                      name = "TS_STATE_DIR";
                      value = "/var/lib/tailscale";
                    }
                  ];
                  resources = routerCfg.resources or cfg.resources;
                  securityContext = {
                    capabilities.add = [
                      "NET_ADMIN"
                      "NET_RAW"
                    ];
                  };
                  volumeMounts = [
                    {
                      name = "tailscale-state";
                      mountPath = "/var/lib/tailscale";
                    }
                  ];
                }
              ];
              volumes = [
                {
                  name = "tailscale-state";
                  emptyDir = { };
                }
              ];
            };
          };
        };
      };
    };

in
self:
let
  routerResources = lib.mapAttrs (mkRouter self) cfg.routers;
in
{

  # --- ServiceAccount (shared) ---
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    inherit name;
    labels = selectorLabels;
  };

  # --- Role (manage own secrets/configmaps in namespace) ---
  role = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "Role";
    inherit name;
    labels = selectorLabels;
    extra.rules = [
      {
        apiGroups = [ "" ];
        resources = [
          "secrets"
          "configmaps"
        ];
        verbs = [
          "get"
          "list"
          "watch"
          "create"
          "update"
          "patch"
          "delete"
        ];
      }
    ];
  };

  # --- RoleBinding ---
  roleBinding = scope.mkResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "RoleBinding";
    inherit name;
    labels = selectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "Role";
        name = "${self.role}";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = "${self.serviceAccount}";
          namespace = scope.namespaceName;
        }
      ];
    };
  };

  # --- Per-router resources (secrets + statefulsets) ---
  routers = lib.mapAttrs (_: r: r.statefulSet) routerResources;
  secrets = lib.mapAttrs (_: r: r.secret) routerResources;

  # --- Entry point ---
  main = {
    resource = self.serviceAccount;
    requires = [
      self.role
      self.roleBinding
    ]
    ++ lib.attrValues self.routers
    ++ lib.attrValues self.secrets;
  };
}
