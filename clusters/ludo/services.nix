# Services — all application workloads.
# Hosts auto-derive from cluster.domain (e.g. immich.ludo.lan).
# Override with config.ingress.host if a different subdomain is needed.
#
# This cluster uses Gateway API. Packages using kix.expose get HTTPRoutes
# automatically — no per-app ingress controller wiring needed.
# LAN-only: plain HTTP, no TLS.

{
  config,
  packages,
  kix,
  ...
}:
let
  domain = config.cluster.domain;
  ref = config.ref;
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
      };
    };

    # --- HomeAssistant: home automation ---
    # NOTE: Helm chart creates its own Ingress resource via values.
    # On this cluster we disable the Helm-managed Ingress and let
    # the chart just run the app. Exposure is handled by a manual
    # HTTPRoute wired to the gateway.
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
        # Disable Helm-managed Ingress — exposure via Gateway API HTTPRoute.
        ingress.enabled = false;
        persistence = {
          enabled = true;
          size = "5Gi";
        };
      };
    };

  };
}
