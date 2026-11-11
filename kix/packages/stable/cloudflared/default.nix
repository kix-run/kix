# cloudflared: the Cloudflare Tunnel connector for a remotely managed
# tunnel.
#
# Installs a Deployment that dials out to Cloudflare and forwards traffic to
# in-cluster Services, so the cluster needs no LoadBalancer, public node
# port, or Ingress for the hostnames the tunnel serves, and a Secret holding
# the tunnel token. Public hostnames and their target Services are set in
# the Cloudflare dashboard or API, not here.
#
# Dependencies:
#   tunnelToken (required)  a secret with the key `token`, the tunnel token
#                           from the Cloudflare dashboard. A `packages.secret`
#                           instance (a SOPS `source`, or `stringData` for a
#                           test cluster) or a `packages.secret-ref` instance
#                           for a Secret a secrets operator writes.
#   reloader (optional)     restarts the connector when a `secret-ref` token
#                           changes. A Kix-built token rolls the pods through
#                           a checksum annotation without it.
#
# Minimal instance:
#
#   instances.edge = {
#     tunnel.package = packages.cloudflared;
#     tunnel-token = {
#       package = packages.secret;
#       aliases = [ "tunnelToken" ];
#       config.keys = [ "token" ];
#       config.source = ./secrets/tunnel-token.sops.yaml;
#     };
#   };
#
# `out`: the Deployment's `name`. The default alias `tunnel` lets other
# packages depend on it.
#
# Escape hatches: the instance's `partsOverlays`.
#
# Limits: the hostnames and target Services live in Cloudflare, so Kix
# derives no dependency or network policy from them. The metrics port
# (2000) serves the probes; the package renders no ServiceMonitor.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  name = scope.instanceName;
  who = "cloudflared ${scope.namespaceName}/${name}";
in
{
  meta = {
    version = "2026.9.3";
    description = "Cloudflare Tunnel connector (cloudflared)";
    owner = "platform";
    lifecycle = "stateless";
    defaultAliases = [ "tunnel" ];
  };

  options = {
    image = kix.options.image {
      repository = "cloudflare/cloudflared";
      tag = "2026.9.3";
    };
    replicas = lib.mkOption {
      type = lib.types.int;
      # Stateless outbound connectors: a second one holds the tunnel open
      # across a pod restart, and a third buys nothing.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };
      description = ''
        Connector replicas (>=2 for connection redundancy). Defaults from
        the cluster's availability level.
      '';
    };
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "32Mi";
      };
      limits = {
        cpu = "200m";
        memory = "128Mi";
      };
    };
  };

  build =
    {
      self,
      config,
      scope,
      kix,
      tunnelToken,
      reloader ? null,
      ...
    }:
    let
      token = kix.checkSecretKeys {
        inherit who;
        arg = "tunnelToken";
        dep = tunnelToken;
        keys = [ "token" ];
      };

      # The container reads the token into its environment once, so a
      # changed token must roll the pods. A Kix-built Secret has an identity
      # hash to put on the pod template; a `secret-ref` Secret has none, and
      # the reloader restarts the pods instead.
      kixBuilt = token.out ? identityHash;
      withReload =
        args: if kixBuilt || reloader == null then args else reloader.out.withReloadOn [ token ] args;
    in
    {
      deployment =
        {
          inherit name;
          spec = {
            replicas = config.replicas;
            selector.matchLabels = scope.selectorLabels;
            template.metadata.annotations = lib.optionalAttrs kixBuilt {
              "checksum/tunnel-token" = token.out.identityHash;
            };
            template.spec = {
              # Matches cloudflared's `--grace-period` default of 30s, the
              # time it waits for in-flight requests after SIGTERM.
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65532;
                runAsGroup = 65532;
              };
              containers = [
                {
                  inherit name;
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  args = [
                    "tunnel"
                    "--no-autoupdate"
                    "--metrics"
                    "0.0.0.0:2000"
                    "run"
                  ];
                  ports = [ (kix.port "metrics" 2000) ];
                  env = token.out.mkEnv { TUNNEL_TOKEN = "token"; };
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    readOnlyRootFilesystem = true;
                    capabilities.drop = [ "ALL" ];
                  };
                  livenessProbe = {
                    httpGet = {
                      path = "/ready";
                      port = "metrics";
                    };
                    initialDelaySeconds = 10;
                    periodSeconds = 10;
                    failureThreshold = 3;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/ready";
                      port = "metrics";
                    };
                    initialDelaySeconds = 5;
                    periodSeconds = 10;
                  };
                }
              ];
            };
          };
        }
        |> withReload
        |> scope.mkDeployment;

      root = self.deployment;
    };
}
