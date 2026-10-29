# Harbor registry (OCI blob storage) and registryctl sidecar.

{
  self,
  config,
  scope,
  lib,
  kix,
  valkey,
  storage,
  harborSecrets,
  caBundle ? null,
  prometheus ? null,
  reloader ? null,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    who
    metricsPort
    registryUser
    svc
    ;
  b = c.forBuild {
    inherit
      self
      config
      valkey
      harborSecrets
      caBundle
      prometheus
      reloader
      ;
  };
  inherit (b)
    metricsEnabled
    secrets
    ca
    valkeySecret
    checksumOf
    reloadOn
    redisAuth
    redisSentinel
    redisAddr
    redisPasswordRef
    valkeyChecksum
    caTrust
    componentSelector
    componentLabels
    containerSecurityContext
    caBundleMount
    tmpMount
    harborPodDefaults
    registryProbe
    registryCtlProbe
    metricsContainerPort
    metricsServicePort
    ;

  registryStorageKeys = [
    "cache"
    "maintenance"
    "delete"
    "redirect"
    "tag"
  ];
  # A non-attrset `storage` is left to mergeGuarded, which refuses it
  # as the replaced ancestor of the locked storage.filesystem.
  storageSettings = config.registry.settings.storage or { };
  badStorageKeys = lib.optionals (builtins.isAttrs storageSettings) (
    builtins.filter (k: !(builtins.elem k registryStorageKeys)) (builtins.attrNames storageSettings)
  );
  registryConfig =
    if badStorageKeys != [ ] then
      throw "${who}: registry.settings.storage sets ${lib.concatStringsSep ", " badStorageKeys}, a storage driver or an unknown key. This package stores blobs on the storage claim with the filesystem driver; object storage is not supported. registry.settings.storage accepts cache, maintenance, delete, redirect, and tag."
    else
      lib.filterAttrsRecursive (_: v: v != null) (
        kix.mergeGuarded
          {
            inherit who;
            what = "registry.settings";
            locked = [
              [
                "storage"
                "filesystem"
              ]
              [
                "redis"
                "addr"
              ]
              [
                "redis"
                "db"
              ]
              [
                "redis"
                "sentinelMasterSet"
              ]
              [
                "redis"
                "password"
              ]
              [
                "http"
                "addr"
              ]
              [
                "http"
                "debug"
              ]
              [ "auth" ]
            ];
          }
          {
            version = "0.1";
            log = {
              level = "info";
              fields.service = "registry";
            };
            storage = {
              filesystem.rootdirectory = "/storage";
              cache.layerinfo = "redis";
              maintenance.uploadpurging = {
                enabled = true;
                age = "168h";
                interval = "24h";
                dryrun = false;
              };
              delete.enabled = true;
              redirect.disable = false;
            };
            # The password arrives as REGISTRY_REDIS_PASSWORD;
            # distribution reads REGISTRY_* env over the file.
            redis = {
              addr = redisAddr;
              db = 2;
              readtimeout = "10s";
              writetimeout = "10s";
              dialtimeout = "10s";
              pool = {
                maxidle = 100;
                maxactive = 500;
                idletimeout = "60s";
              };
            }
            // lib.optionalAttrs redisSentinel { sentinelMasterSet = valkey.out.primarySet; };
            http = {
              addr = ":5000";
              relativeurls = false;
              debug = {
                addr = ":${toString metricsPort}";
                prometheus = {
                  enabled = metricsEnabled;
                  path = "/metrics";
                };
              };
            };
            auth.htpasswd = {
              realm = "harbor-registry-basic-realm";
              path = "/etc/registry-auth/passwd";
            };
            validation.disabled = true;
            compatibility.schema1.enabled = true;
          }
          config.registry.settings
      );
in
{
  registryConfigMap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-registry";
    data = {
      # JSON is YAML, and distribution reads it as such.
      "config.yml" = builtins.toJSON registryConfig;
      "ctl-config.yml" = ''
        ---
        protocol: "http"
        port: 8080
        log_level: info
        registry_config: "/etc/registry/config.yml"
      '';
    };
  };

  registryService =
    self.registryDeployment
    |> kix.service.fromWorkload {
      name = svc.registry;
      labels = componentLabels "registry";
      ports = [
        {
          name = "http-registry";
          port = 5000;
          targetPort = 5000;
          protocol = "TCP";
        }
        {
          name = "http-controller";
          port = 8080;
          targetPort = 8080;
          protocol = "TCP";
        }
      ]
      ++ metricsServicePort;
      outputs.port = "5000";
    }
    |> scope.mkResource;

  registryDeployment =
    let
      # Shared volumes are injected once, on the registry container;
      # registryctl and the init container mount them by name.
      configMount = kix.mount.configMap self.registryConfigMap {
        name = "registry-config";
        mountPath = "/etc/registry/config.yml";
        subPath = "config.yml";
      };
      dataMount = kix.mount.pvc storage {
        name = "registry-data";
        mountPath = "/storage";
      };
      authMount = kix.mount.emptyDir {
        name = "registry-auth";
        mountPath = "/etc/registry-auth";
        sizeLimit = "1Mi";
      };
      registryEnv =
        secrets.out.mkEnv { REGISTRY_HTTP_SECRET = "registryHttpSecret"; }
        ++ lib.optional redisAuth (redisPasswordRef "REGISTRY_REDIS_PASSWORD")
        ++ kix.mkEnvVars caTrust;
    in
    {
      name = "${name}-registry";
      labels = componentSelector "registry";
      # The filesystem driver keeps blobs and upload state on the one
      # storage claim, which a second pod would have to share.
      availability.max = "none";
      spec = {
        replicas = 1;
        revisionHistoryLimit = 5;
        strategy.type = "Recreate";
        selector.matchLabels = componentSelector "registry";
        template.metadata.annotations = {
          "checksum/config" = self.registryConfigMap.out.identityHash;
        }
        // checksumOf "harbor-secrets" secrets
        // checksumOf "ca-bundle" ca
        // valkeyChecksum;
        template.spec = harborPodDefaults // {
          securityContext = harborPodDefaults.securityContext // {
            fsGroupChangePolicy = "OnRootMismatch";
          };
          # The registry checks core's and jobservice's basic auth
          # against a bcrypt htpasswd line. Nix has no bcrypt, and a
          # SOPS value is not readable at evaluation, so this
          # container computes the line from registryPassword when the
          # pod starts. `-i` reads the password from stdin, which keeps
          # it out of the process arguments.
          initContainers = [
            {
              name = "htpasswd";
              image = kix.image.ref config.htpasswd.image;
              imagePullPolicy = config.htpasswd.image.pullPolicy;
              command = [
                "/bin/sh"
                "-c"
                ''printf '%s' "$REGISTRY_PASSWORD" | htpasswd -niB ${registryUser} > /etc/registry-auth/passwd''
              ];
              env = secrets.out.mkEnv { REGISTRY_PASSWORD = "registryPassword"; };
              volumeMounts = [
                {
                  name = authMount.name;
                  mountPath = "/etc/registry-auth";
                }
              ];
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "16Mi";
                };
                limits = {
                  cpu = "100m";
                  memory = "64Mi";
                };
              };
              securityContext = containerSecurityContext;
            }
          ];
          containers = [
            {
              name = "registry";
              image = kix.image.ref config.registry.image;
              command = [ "/usr/bin/registry_DO_NOT_USE_GC" ];
              args = [
                "serve"
                "/etc/registry/config.yml"
              ];
              imagePullPolicy = config.registry.image.pullPolicy;
              ports = [ (kix.port "registry" 5000) ] ++ metricsContainerPort;
              livenessProbe = registryProbe // {
                initialDelaySeconds = 300;
              };
              readinessProbe = registryProbe // {
                initialDelaySeconds = 1;
              };
              env = registryEnv;
              resources = config.registry.resources;
              securityContext = containerSecurityContext;
            }
            {
              name = "registryctl";
              image = kix.image.ref config.registryctl.image;
              command = [ "/home/harbor/harbor_registryctl" ];
              args = [
                "-c"
                "/etc/registryctl/config.yml"
              ];
              imagePullPolicy = config.registryctl.image.pullPolicy;
              ports = [ (kix.port "registryctl" 8080) ];
              livenessProbe = registryCtlProbe // {
                initialDelaySeconds = 300;
              };
              readinessProbe = registryCtlProbe // {
                initialDelaySeconds = 1;
              };
              env =
                registryEnv
                ++ secrets.out.mkEnv {
                  CORE_SECRET = "coreSecret";
                  JOBSERVICE_SECRET = "jobserviceSecret";
                };
              volumeMounts = [
                {
                  name = configMount.name;
                  mountPath = "/etc/registry/config.yml";
                  subPath = "config.yml";
                }
                {
                  name = configMount.name;
                  mountPath = "/etc/registryctl/config.yml";
                  subPath = "ctl-config.yml";
                }
                {
                  name = dataMount.name;
                  mountPath = "/storage";
                }
              ]
              # The registry container's withMountsOn below adds the
              # volume itself.
              ++ lib.optional (caBundleMount != null) {
                inherit (caBundleMount) name mountPath subPath;
              };
              resources = config.registryctl.resources;
              securityContext = containerSecurityContext;
            }
          ];
        };
      };
    }
    |> kix.withMountsOn "registry" [
      configMount
      authMount
      dataMount
      (tmpMount "registry-tmp")
      caBundleMount
    ]
    |> kix.withMountsOn "registryctl" [ (tmpMount "registryctl-tmp") ]
    |> reloadOn [
      secrets
      ca
      valkeySecret
    ]
    |> scope.mkDeployment;
}
