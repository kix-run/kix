# cloudflared — Cloudflare Tunnel connector.
#
# Runs the cloudflared agent for a *remotely-managed* tunnel: it dials out to
# Cloudflare and forwards traffic to in-cluster Services, so there's no need for
# a LoadBalancer, public node port, or Ingress. Public-hostname routing for a
# remotely-managed tunnel is configured in the Cloudflare dashboard (or API);
# this package just runs the connector and holds the tunnel token in a Secret.
#
# Provide the token inline (`token`, dev) or via a SOPS-encrypted file
# (`tokenSource`, prod). root = the cloudflared Deployment.

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
    version = "0.1.0";
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
    resources = lib.mkOption {
      type = lib.types.anything;
      default = {
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
      # Tunnel token Secret — inline stringData, or hydrated from a SOPS source.
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
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65532;
                runAsGroup = 65532;
              };
              containers = [
                {
                  inherit name;
                  image = kix.image.ref config.image;
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
