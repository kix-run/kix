# cloudflared: the Cloudflare Tunnel connector for a remotely managed
# tunnel.
#
# Installs a Deployment that dials out to Cloudflare and forwards traffic to
# in-cluster Services, so the cluster needs no LoadBalancer, public node
# port, or Ingress for the hostnames the tunnel serves, and a Secret holding
# the tunnel token. Public hostnames and their target Services are set in
# the Cloudflare dashboard or API, not here.
#
# Config: the tunnel token, as `tokenSource` (a SOPS-encrypted file with a
# `token` key) or `token` (the token itself, which then sits in the cluster
# file and the Nix store).
#
# Minimal instance:
#
#   instances.edge.tunnel = {
#     package = packages.cloudflared;
#     config.tokenSource = ./secrets/tunnel-token.sops.yaml;
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
    token = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Tunnel token (inline; dev). Prefer tokenSource in production.";
    };
    tokenSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a SOPS-encrypted file providing the `token` key.";
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
        the cluster's availability level (v2_discussions/145).
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
      ...
    }:
    {
      # Tunnel token Secret: inline stringData, or hydrated from a SOPS source.
      tunnelToken = scope.mkSecret {
        name = "${name}-token";
        keys = [ "token" ];
        stringData = lib.optionalAttrs (config.token != null) { token = config.token; };
        source = config.tokenSource;
      };

      deployment =
        {
          inherit name;
          spec = {
            replicas = config.replicas;
            selector.matchLabels = scope.selectorLabels;
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
                  env = self.tunnelToken.out.mkEnv { TUNNEL_TOKEN = "token"; };
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
        |> scope.mkDeployment;

      root = self.deployment;
    };
}
