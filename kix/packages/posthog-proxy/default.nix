# PostHog reverse proxy — kix package.
#
# Creates ExternalName Services pointing to PostHog's ingestion and
# asset hosts, fronted by an Ingress with SSL passthrough config.
#
# Resources: Service (posthog-proxy, ExternalName),
#            Service (posthog-assets-proxy, ExternalName),
#            Ingress (with dual-backend routing).
#
# root = Ingress.

{
  scope,
  lib,
  kix,
}:

{
  meta = {
    version = "1.0.0";
    description = "An Ingress that proxies PostHog ingestion and asset traffic through ExternalName Services on a first-party hostname";
    owner = "app-team";
  };

  options = {
    host = lib.mkOption {
      type = lib.types.str;
      description = "Ingress hostname (e.g. e.northwind.example)";
    };
    ingressClassName = lib.mkOption {
      type = lib.types.str;
      default = "public";
    };
    posthogHost = lib.mkOption {
      type = lib.types.str;
      default = "us.i.posthog.com";
    };
    posthogAssetsHost = lib.mkOption {
      type = lib.types.str;
      default = "us-assets.i.posthog.com";
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
    }:
    {
      # --- ExternalName Service: PostHog ingestion ---
      posthogService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "posthog-proxy";
        labels."app.kubernetes.io/component" = "ingestion";
        spec = {
          type = "ExternalName";
          externalName = config.posthogHost;
          ports = [
            {
              name = "https";
              port = 443;
              protocol = "TCP";
              targetPort = 443;
            }
          ];
        };
      };

      # --- ExternalName Service: PostHog assets ---
      posthogAssetsService = scope.mkResource {
        apiVersion = "v1";
        kind = "Service";
        name = "posthog-assets-proxy";
        labels."app.kubernetes.io/component" = "assets";
        spec = {
          type = "ExternalName";
          externalName = config.posthogAssetsHost;
          ports = [
            {
              name = "https";
              port = 443;
              protocol = "TCP";
              targetPort = 443;
            }
          ];
        };
      };

      # --- Ingress ---
      ingress = scope.mkResource {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        name = "posthog-proxy";
        annotations = {
          "nginx.ingress.kubernetes.io/backend-protocol" = "HTTPS";
          "nginx.ingress.kubernetes.io/configuration-snippet" = ''
            proxy_ssl_name ${config.posthogHost};
            proxy_ssl_server_name on;
          '';
          "nginx.ingress.kubernetes.io/proxy-body-size" = "10m";
          "nginx.ingress.kubernetes.io/ssl-redirect" = "false";
          "nginx.ingress.kubernetes.io/upstream-vhost" = config.posthogHost;
        };
        spec = {
          ingressClassName = config.ingressClassName;
          tls = [
            {
              hosts = [ config.host ];
              secretName = "tls";
            }
          ];
          rules = [
            {
              host = config.host;
              http.paths = [
                {
                  path = "/";
                  pathType = "Prefix";
                  backend.service = {
                    name = self.posthogService.out.name;
                    port.name = "https";
                  };
                }
                {
                  path = "/static";
                  pathType = "Prefix";
                  backend.service = {
                    name = self.posthogAssetsService.out.name;
                    port.name = "https";
                  };
                }
              ];
            }
          ];
        };
      };

      # --- Entry point ---
      root = self.ingress;
    };
}
