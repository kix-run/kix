# Platform infrastructure — storage, networking, TLS, ingress.
# Single-node home server: cert-manager, ingress-nginx, storage classes,
# CoreDNS, Tailscale, shared Postgres.
# Owned by: Luca (platform)

{ config, lib, ref, packages, kix, ... }:
{
  options = {
    cluster.domain = lib.mkOption {
      type = lib.types.str;
      description = "Base domain for the cluster (e.g. ludo.example.com)";
    };

    tls.clusterIssuer = lib.mkOption {
      type = lib.types.str;
      default = "letsencrypt-production";
    };

    dns.upstreamResolvers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "1.1.1.1" "8.8.8.8" ];
    };
  };

  config = {
    instances = {

      # ================================================================
      # kube-system — core cluster services
      # ================================================================

      kube-system = {

        storage-classes = {
          package = packages.storage-classes;
          # TODO: configure local-ssd and zfs-bulk storage classes
          # once the storage-classes package supports custom class definitions
        };

        coredns = {
          package = packages.coredns;
          config = {
            replicaCount = 1; # single node, one replica is fine
            image.tag = "1.12.3";
            resources = {
              requests = { cpu = "50m"; memory = "64Mi"; };
              limits = { cpu = "200m"; memory = "128Mi"; };
            };
            servers = [
              {
                zones = [ "." ];
                port = "53";
                plugins = [
                  "errors"
                  { name = "health"; parameters = ""; block = [ "lameduck 5s" ]; }
                  "ready"
                  # DNS rewrites for internal service access
                  { name = "rewrite"; parameters = "name exact grafana.${config.cluster.domain} ${ref.ingress-system.ingress-nginx.out.fqdn} answer auto"; }
                  {
                    name = "kubernetes";
                    parameters = "${config.cluster.domain} cluster.local in-addr.arpa ip6.arpa";
                    block = [
                      "pods insecure"
                      "fallthrough ${config.cluster.domain} in-addr.arpa ip6.arpa"
                      "ttl 30"
                    ];
                  }
                  "prometheus 0.0.0.0:9153"
                  "forward . ${lib.concatMapStringsSep " " (r: "${r}:53") config.dns.upstreamResolvers}"
                  "loop"
                  "reload"
                  "loadbalance"
                ];
              }
            ];
            prometheus = {
              service = {
                enabled = true;
                annotations = {
                  "prometheus.io/scrape" = "true";
                  "prometheus.io/port" = "9153";
                };
              };
              monitor = { enabled = false; interval = null; };
            };
          };
        };

        cert-manager = {
          package = packages.cert-manager;
          config = {
            dns01RecursiveNameservers = "1.1.1.1:53,8.8.8.8:53";
            dns01RecursiveNameserversOnly = true;
          };
        };
      };

      # ================================================================
      # ingress-system — single nginx ingress controller
      # ================================================================

      ingress-system = {
        ingress-nginx = {
          package = packages.ingress-nginx;
          aliases = [ "ingress-nginx" ];
          config = {
            namePrefix = "default";
            replicaCount = 1; # single node
            serviceType = "ClusterIP"; # Tailscale handles external access
            ingressClassName = "nginx";
            isDefaultClass = true;
            controllerValue = "${config.cluster.domain}/nginx";
            config = {
              proxy-body-size = "0"; # no upload limit (Immich needs large uploads)
              use-forwarded-headers = "true";
            };
          };
        };
      };

      # ================================================================
      # cert-manager — TLS issuers
      # ================================================================

      cert-manager = {
        cluster-issuers = {
          package = packages.cluster-issuers;
          config = {
            mainIssuer = config.tls.clusterIssuer;
            issuers = {
              letsencrypt-production = {
                server = "https://acme-v02.api.letsencrypt.org/directory";
                email = "admin@example.com"; # TODO: set real email
                privateKeySecretName = "tls-production";
                cloudflareSecret = { name = "cloudflare-credentials"; key = "api-token"; };
                dnsZones = [ config.cluster.domain ];
              };
              letsencrypt-staging = {
                server = "https://acme-staging-v02.api.letsencrypt.org/directory";
                email = "admin@example.com"; # TODO: set real email
                privateKeySecretName = "tls-staging";
                cloudflareSecret = { name = "cloudflare-credentials"; key = "api-token"; };
                dnsZones = [ config.cluster.domain ];
              };
            };
          };
        };
      };

      # ================================================================
      # data — shared Postgres + shared Valkey (saves RAM on 16GB)
      # ================================================================

      data = {
        postgres = {
          package = packages.stackgres-cluster;
          aliases = [ "postgres" ];
          config = {
            instances = 1; # single node, no HA needed
            postgres = {
              version = "16";
              extensions = [
                # pgvecto.rs for Immich smart search
                { name = "vectors"; publisher = "tensorchord"; version = "0.3.0"; }
              ];
            };
            storage = {
              size = "50Gi";
              # TODO: storageClass = "local-ssd";
            };
            instanceProfile = {
              cpu = "2";
              memory = "2Gi";
            };
            pgConfig = {
              maxConnections = "200";
              postgresqlConf = {
                shared_buffers = "512MB";
                effective_cache_size = "1536MB";
                maintenance_work_mem = "128MB";
              };
            };
          };
        };

        valkey = {
          package = packages.valkey;
          aliases = [ "valkey" ];
          config = {
            replicaCount = 1; # single node
            sentinel.enabled = false;
            auth.enabled = true;
            metrics.enabled = true;
            persistence = {
              enabled = true;
              size = "2Gi";
            };
            resources = {
              requests = { cpu = "50m"; memory = "64Mi"; };
              limits = { cpu = "200m"; memory = "128Mi"; };
            };
          };
        };
      };

    };
  };
}
