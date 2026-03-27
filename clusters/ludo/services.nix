# Services — all application workloads.
# Ingress hosts auto-derive from cluster.domain (e.g. immich.ludo.example.com).
# Override with config.ingress.host if a different subdomain is needed.

{
  config,
  packages,
  kix,
  ...
}:
let
  domain = config.cluster.domain;
in
{
  config.instances = {

    # --- Immich: photo backup & sharing ---
    immich = {
      storage = {
        package = packages."persistent-volume-claim";
        config.size = "100Gi"; # expand when on ZFS
      };

      immich = {
        package = packages.immich;
        config = {
          image.tag = "v2.0.0";
          ingress.host = "photos.${domain}"; # override: "immich" isn't a great subdomain
          metrics.enabled = true;
        };
      };
    };

    # --- NAS: file browsing ---
    nas = {
      storage = {
        package = packages."persistent-volume-claim";
        config.size = "100Gi";
      };

      filebrowser = {
        package = packages.filebrowser;
        config.ingress.host = "files.${domain}"; # override: "filebrowser" is too long
      };
    };

    # --- Vaultwarden: password management (SQLite) ---
    vaultwarden = {
      storage = {
        package = packages."persistent-volume-claim";
        config.size = "1Gi";
      };

      vaultwarden = {
        package = packages.vaultwarden;
        # ingress.host defaults to vaultwarden.<domain> ✓
        # domain defaults to https://vaultwarden.<domain> ✓
      };
    };

    # --- HomeAssistant: home automation ---
    homeassistant.homeassistant = {
      package = kix.fromHelmChart {
        chart = kix.fetchHelmChart {
          repo = "https://pajikos.github.io/home-assistant-helm-chart";
          name = "home-assistant";
          version = "0.3.51";
          hash = "sha256-gcZzrAYS23YiOyVJg8cIntyBQmF/Q+/d0q5sKWtl8WY=";
        };
        releaseName = "homeassistant";
        rootSelector = {
          kind = "Service";
          name = "homeassistant-home-assistant";
        };
        # StatefulSet needs a headless Service for per-pod DNS identity.
        patchResources = map (
          r:
          if r.kind == "Service" && r.metadata.name == "homeassistant-home-assistant" then
            r
            // {
              spec = r.spec // {
                clusterIP = "None";
              };
            }
          else
            r
        );
      };
      config.values = {
        ingress = {
          enabled = true;
          className = "nginx";
          hosts = [
            {
              host = "home.${domain}";
              paths = [
                {
                  path = "/";
                  pathType = "Prefix";
                }
              ];
            }
          ];
          tls = [
            {
              secretName = "homeassistant-tls";
              hosts = [ "home.${domain}" ];
            }
          ];
        };
        persistence = {
          enabled = true;
          size = "5Gi";
        };
      };
    };

  };
}
