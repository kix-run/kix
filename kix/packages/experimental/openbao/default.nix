# openbao: OpenBao, a secrets manager (the MPL fork of HashiCorp Vault), as
# a StatefulSet on integrated Raft storage, with TLS from cert-manager and
# Kubernetes auth for external-secrets.
#
# Installs a StatefulSet with a volume per pod, a Service on port 8200, a
# headless Service for the Raft peers, the server's ServiceAccount and a
# ClusterRoleBinding to `system:auth-delegator` (Kubernetes auth reviews
# client tokens through the API server), a ConfigMap with the server
# configuration, and a cert-manager chain: a self-signed Issuer, a CA
# Certificate, a CA Issuer, and the server Certificate, whose Secret
# `<instance>-tls` carries the CA as `ca.crt`. OpenBao reloads a renewed
# server certificate itself (`tls_auto_reload`). With the default seal it
# also installs the reconcile Job, its ServiceAccount, and its ConfigMap.
#
# Dependencies:
#   certManager (required)     a managed cert-manager instance, for the
#                              Issuer and Certificate handles.
#   unsealKey (required with seal.type = "static", the default)
#                              a secret with key `key`: a 32-byte AES key,
#                              raw, hex (64 characters), or base64 (44, or
#                              43 unpadded URL-safe), with no trailing
#                              newline (`openssl rand -hex 32 | tr -d '\n'`).
#   storageClasses (optional)  the class of the volumes when
#                              `storage.storageClassName` is unset.
#   prometheus (optional)      a metrics listener, a metrics Service, a
#                              ServiceMonitor, and the alert rules while
#                              `metrics.enabled`.
#
# Minimal instance (`clusters/test-openbao.nix` evaluates this shape with
# `stringData`):
#
#   instances.secrets = {
#     openbao.package = packages.experimental.openbao;
#     openbao-unseal = {
#       package = packages.secret;
#       aliases = [ "unsealKey" ];
#       config.source = ./secrets/openbao-unseal.sops.yaml;
#       config.keys = [ "key" ];
#     };
#   };
#
# Unseal. With `seal.type = "static"` OpenBao unseals itself on every start
# with the key in `unsealKey`. Anyone who can read that Secret and a Raft
# volume can decrypt the data, so protection at rest is no stronger than
# the RBAC on Secrets in this namespace and the cluster's etcd encryption.
# `seal.type = "shamir"` keeps the unseal keys out of the cluster: a person
# runs `bao operator init` once and `bao operator unseal` on every pod after
# each start, and a deploy waits until they do. Transit and cloud KMS seals
# are not supported.
#
# Initialization. With the static seal, pod 0 initializes the cluster on its
# first start (OpenBao's declarative self-initialization). It enables
# Kubernetes auth and creates the policy and role `kix-reconcile`, bound
# only to the reconcile Job's ServiceAccount. The root token is revoked
# after that and no recovery keys exist. On every change to `policies`,
# `kubernetesAuth.roles`, or `secretsEngines`, the reconcile Job logs in
# through that role and writes them. It creates and updates and never
# deletes; its log lists the policies and roles OpenBao holds that are not
# declared. A secrets engine that already exists is left as it is. The Job
# can write any policy, its own included, so its ServiceAccount is as
# powerful as a root token: anyone who can run a pod under it in this
# namespace can take over OpenBao. People get access through a declared
# role and policy. With `seal.type = "shamir"` nothing is initialized, no
# Job runs, and the three options must stay empty.
#
# Replicas follow the cluster's availability level: one at `none`, three
# from `pod` up (two would lose quorum with either pod). Pods start in order
# and join pod 0 through `retry_join` over the headless Service. Standbys
# forward requests to the active pod, so the Service selects every pod.
# Scaling down leaves the removed pods in the Raft configuration until
# `bao operator raft remove-peer` removes them. Pod 0 started on an empty
# volume skips self-initialization and joins its peers when one of them
# answers within five seconds and reports an initialized cluster.
#
# `out`:
#   url, fqdn, port   the Service, as `https://<fqdn>:8200`.
#   caSecret          the Secret whose `ca.crt` signs the server certificate.
#   externalSecretsProvider scope { serviceAccount; role; mount; }
#       Returns `{ vault = ...; }` for the `spec.provider` of a
#       ClusterSecretStore built with external-secrets'
#       `out.mkClusterSecretStore`: the server, the CA from `caSecret`, the
#       mount `mount` as `path` with its KV version, and Kubernetes auth as
#       role `role` with a token of `serviceAccount` (a ServiceAccount
#       resource in the caller's scope). It refuses a role that is not
#       declared or that does not bind that ServiceAccount and namespace,
#       and a mount that is not a declared `kv` secrets engine. The store
#       is ordered after the reconcile Job. A namespaced SecretStore cannot
#       read the CA Secret from this namespace; set the ClusterSecretStore's
#       `conditions` to limit the namespaces that use it.
#
# Network policy: an intent opens egress to the API server for the server
# pods, for token reviews. A ClusterSecretStore built from
# `out.externalSecretsProvider` names the Service address, and the
# external-secrets package declares that its controller dials a store's
# provider, so Kix opens the controller's egress to port 8200 and this
# instance's ingress from the controller.
#
# Known limits:
#   - If self-initialization fails on pod 0's first start (a request
#     refused, the ServiceAccount token not mounted), OpenBao has already
#     initialized the volume and revoked the root token, and refuses to
#     unseal on every later start. No root token or recovery key exists.
#     Delete the claim `data-<instance>-0` and the pod, and let it start
#     again; self-initialization runs only on an empty volume, so the
#     claim holds nothing else.
#   - The static key cannot be rotated. A changed `unsealKey` value
#     restarts the pods, and they cannot unseal the existing data until the
#     old value is restored.
#
# Metrics: with a prometheus dependency and `metrics.enabled`, each pod
# opens a second listener on TCP 8202 that serves only `/v1/sys/metrics`,
# without TLS and without a token (`metrics_only`,
# `unauthenticated_metrics_access`), so standbys and sealed pods report
# too. The listener refuses every other path, but its metrics name mounts,
# auth methods, and policies; under network policy only the scrape reaches
# it. The ServiceMonitor asks for `format=prometheus`. The package sets
# `telemetry.disable_hostname`, without which gauge names carry the pod
# name, and `telemetry.prometheus_retention_time`, and refuses those and
# `telemetry.metrics_prefix` in `settings`.
#
# Alerts: a PrometheusRule `<instance>-alerts` selects the metrics
# Service's series. Several gauges keep their last value for
# `prometheus_retention_time` after a pod seals, and the autopilot gauges
# after a pod stops being the leader, so the rules read them only from
# unsealed pods and the active pod.
#   OpenBaoDown (critical)            no pod answers a scrape.
#   OpenBaoAllSealed (critical)       every pod is sealed, so OpenBao serves
#                                     no request.
#   OpenBaoNoActiveNode (critical)    pods are unsealed but none is active,
#                                     so requests fail.
#   OpenBaoAuditFailing (critical)    no audit device could log a request,
#                                     so OpenBao refused it. One failing
#                                     device among several that log does
#                                     not count; that shows only in the
#                                     server log.
#   OpenBaoSealed (warning, 3 replicas)
#                                     one pod is sealed while another is
#                                     not. With the static seal check the
#                                     `unsealKey` Secret; with shamir, run
#                                     `bao operator unseal`.
#   OpenBaoRaftUnhealthy (warning, 3 replicas)
#                                     autopilot reports an unhealthy Raft
#                                     peer, or the cluster tolerates no
#                                     further peer failure.
#   OpenBaoMetricsMissing (warning)   pods are scraped but report no
#                                     OpenBao metrics.
# The package configures no audit device, so OpenBaoAuditFailing fires
# only for a device added through the API. Left to
# prometheus-default-rules: full volumes (KubePersistentVolumeFillingUp),
# crash loops, and a failed reconcile Job (KubeJobFailed); the server
# certificate to cert-manager's alerts. Lease and token counts depend on
# the site.
#
# Escape hatches: `settings` for server configuration keys the package does
# not set, `env`, and the instance's `partsOverlays`. Audit devices and the
# web UI are not configured.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    release
    minVersion
    name
    ns
    metricsServiceName
    reconcileRole
    validName
    validMountPath
    reservedMount
    roleType
    engineType
    ;

  replicas = kix.availability.pick availability {
    none = 1;
    pod = 3;
    node = 3;
    zone = 3;
  };
in
{
  meta = {
    version = release;
    description = "OpenBao, a secrets manager, on integrated Raft storage with Kubernetes auth";
    owner = "platform";
    lifecycle = "stateful";
    defaultAliases = [ "openbao" ];
    network.intents.tokenReview.egress = [ { to = "apiserver"; } ];
  };

  assertions =
    { config, ... }:
    let
      policyNames = builtins.attrNames config.policies;
      roleNames = builtins.attrNames config.kubernetesAuth.roles;
      enginePaths = builtins.attrNames config.secretsEngines;
      bad = pred: names: builtins.filter (n: !(pred n)) names;
      show = names: lib.concatMapStringsSep ", " builtins.toJSON names;
      unknownPolicies = lib.concatLists (
        lib.mapAttrsToList (
          role: r:
          map (p: "${role} -> ${p}") (
            builtins.filter (p: p != "default" && !(config.policies ? ${p})) r.token_policies
          )
        ) config.kubernetesAuth.roles
      );
      declared = policyNames ++ roleNames ++ enginePaths;
      imageTag = builtins.unsafeDiscardStringContext config.image.tag;
      tagVersion = builtins.match "v?([0-9]+\\.[0-9]+)(\\..*)?" imageTag;
    in
    [
      {
        assertion =
          tagVersion == null || builtins.compareVersions (builtins.head tagVersion) minVersion >= 0;
        message = "image.tag \"${imageTag}\" is older than OpenBao ${minVersion}, which added the tls_auto_reload listener option the package sets. Remove image.tag or set a ${minVersion} or later tag.";
      }
      {
        assertion = config.seal.type == "static" || declared == [ ];
        message = "seal.type is \"shamir\", and policies, kubernetesAuth.roles, or secretsEngines declare ${show declared}. They are applied by a Job that logs in through the role self-initialization creates, and self-initialization needs the static seal. Remove them and configure OpenBao through its API, or set seal.type = \"static\".";
      }
      {
        assertion = bad validName policyNames == [ ];
        message = "policies has the names ${show (bad validName policyNames)}; a name starts with a letter or digit and holds only letters, digits, '_', '.', and '-'.";
      }
      {
        assertion = !(builtins.elem reconcileRole policyNames) && !(config.policies ? root);
        message = "policies declares \"root\" or \"${reconcileRole}\"; OpenBao owns root, and ${reconcileRole} is the reconcile Job's own policy. Rename the policy.";
      }
      {
        assertion = bad validName roleNames == [ ];
        message = "kubernetesAuth.roles has the names ${show (bad validName roleNames)}; a name starts with a letter or digit and holds only letters, digits, '_', '.', and '-'.";
      }
      {
        assertion = !(builtins.elem reconcileRole roleNames);
        message = "kubernetesAuth.roles declares \"${reconcileRole}\", the reconcile Job's own role. Rename the role.";
      }
      {
        assertion = unknownPolicies == [ ];
        message = "kubernetesAuth.roles name policies that policies does not declare: ${lib.concatStringsSep ", " unknownPolicies}. Declare them in policies, or use \"default\".";
      }
      {
        assertion =
          bad validMountPath enginePaths == [ ] && builtins.filter reservedMount enginePaths == [ ];
        message = "secretsEngines has the paths ${
          show (bad validMountPath enginePaths ++ builtins.filter reservedMount enginePaths)
        }; a path is segments of letters, digits, '_', '.', and '-' joined by '/', without a leading or trailing '/', outside sys/, auth/, identity/, and cubbyhole/.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "quay.io/openbao/openbao";
      tag = release;
      digest = "sha256:6d2b93856e3fcf7b18ad855a0b51eaba474dc8b79cf554379ea32034797d2acf";
      description = "Image of the server and of the reconcile Job, which runs its `bao` CLI.";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "250m";
        memory = "256Mi";
      };
      limits = {
        cpu = "2";
        memory = "1Gi";
      };
    };

    seal = {
      type = lib.mkOption {
        type = lib.types.enum [
          "static"
          "shamir"
        ];
        default = "static";
        description = ''
          `static`: OpenBao unseals itself with the key from the `unsealKey`
          dependency and initializes itself on its first start. Anyone who
          can read that Secret and a volume can decrypt the data.
          `shamir`: a person initializes OpenBao and unseals every pod after
          each start; `policies`, `kubernetesAuth.roles`, and
          `secretsEngines` must be empty.
        '';
      };
      keyId = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_.-]+";
        default = "1";
        description = "Identifier OpenBao records with data sealed by the static key (`current_key_id`). The package does not rotate keys: a changed `unsealKey` value leaves restarted pods unable to unseal until the old value is restored.";
      };
    };

    storage = {
      size = lib.mkOption {
        type = kix.types.quantity;
        default = "10Gi";
        description = "Volume requested for each pod, holding the Raft log and snapshots.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "StorageClass of the volumes. Null takes the class from the storageClasses dependency, or with none the cluster default.";
      };
    };

    policies = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = {
        app-read = ''path "secret/data/app/*" { capabilities = ["read"] }'';
      };
      description = "ACL policies in HCL, by name, written by the reconcile Job. `root` and `kix-reconcile` are refused. A policy removed here stays in OpenBao, and the Job's log lists it.";
    };

    kubernetesAuth.roles = lib.mkOption {
      type = lib.types.attrsOf roleType;
      default = { };
      example = {
        external-secrets = {
          bound_service_account_names = [ "app-store" ];
          bound_service_account_namespaces = [ "app" ];
          token_policies = [ "app-read" ];
        };
      };
      description = "Roles of the Kubernetes auth method at `auth/kubernetes`, by name, as the body of `auth/kubernetes/role/<name>`, written by the reconcile Job. `kix-reconcile` is refused. A role removed here stays in OpenBao, and the Job's log lists it.";
    };

    secretsEngines = lib.mkOption {
      type = lib.types.attrsOf engineType;
      default = { };
      example = {
        secret = {
          type = "kv";
          options.version = "2";
        };
      };
      description = "Secrets engines by mount path, as the body of `sys/mounts/<path>`. The reconcile Job enables a missing engine and leaves an existing one of the same type unchanged; one of another type fails the Job.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        log_level = "debug";
      };
      description = "Server configuration keys merged over the package's, as JSON. The package sets `listener`, `storage`, `seal`, `api_addr`, `cluster_addr`, and `initialize`, and refuses them here; with metrics, also `telemetry.disable_hostname`, `telemetry.prometheus_retention_time`, and `telemetry.metrics_prefix`.";
    };

    env = kix.options.env // {
      description = "Extra environment variables of the server container. The addresses, Raft, and seal variables are set by the package.";
    };

    metrics = kix.options.monitor;
  };

  build = [
    ./server.nix
    ./reconcile.nix

    # DI passes a build function only the arguments its formals name, so
    # the wrapper names every argument kix.monitor reads.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      let
        sel = ''namespace="${ns}",service="${metricsServiceName}"'';
        by = "namespace, service";
        instance = "OpenBao ${ns}/${name}";
        # The gauges of pods that are unsealed, and of the active pod. Other
        # pods keep exporting the values they had before they sealed or
        # stepped down. Each pod also exports a `vault_core_unsealed` at 0
        # without the `cluster` label from before its first unseal, for
        # `prometheus_retention_time`, so a per-pod read must take the
        # `max` over the pod's series.
        unsealed = "on (${by}, pod) vault_core_unsealed{${sel}} == 1";
        active = "on (${by}, pod) vault_core_active{${sel}} == 1";
        fromLeader = metric: "${metric}{${sel}} and ${active} and ${unsealed}";
      in
      kix.monitor {
        service = "metricsService";
        path = "/v1/sys/metrics";
        # OpenBao answers in its own JSON format unless asked for Prometheus
        # text, by this parameter or by an OpenMetrics Accept header, which
        # not every scraper sends.
        params.format = [ "prometheus" ];
        alerts = {
          OpenBaoDown = {
            expr = "sum by (${by}) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "critical";
            summary = "OpenBao is down.";
            description = "No pod of ${instance} has answered a scrape for 10 minutes, so clients cannot read secrets. Check the pods of the StatefulSet ${name} in ${ns}.";
          };
          OpenBaoAllSealed = {
            expr = "max by (${by}) (vault_core_unsealed{${sel}}) == 0";
            "for" = "5m";
            severity = "critical";
            summary = "Every OpenBao pod is sealed.";
            description = "Every pod of ${instance} has been sealed for 5 minutes, so OpenBao serves no request. ${
              if config.seal.type == "static" then
                "The pods unseal themselves with the key in the unsealKey Secret; check that Secret and the pod logs."
              else
                "Unseal each pod with `bao operator unseal`."
            }";
          };
          OpenBaoNoActiveNode = {
            expr = "max by (${by}) (vault_core_unsealed{${sel}}) == 1 unless on (${by}) max by (${by}) (vault_core_active{${sel}} and ${unsealed}) == 1";
            "for" = "5m";
            severity = "critical";
            summary = "OpenBao has no active pod.";
            description = "Pods of ${instance} are unsealed but none has been active for 5 minutes, so requests fail. The pods cannot elect a Raft leader; check their logs and `bao operator raft list-peers`.";
          };
          # OpenBao adds to both counters on every audited request, zero when
          # logging succeeds, so the series exist before the first failure.
          # The ten-minute window already spans a restart, so the rule has
          # no `for`.
          OpenBaoAuditFailing = {
            expr = "sum by (${by}) (increase(vault_audit_log_request_failure{${sel}}[10m])) > 0 or sum by (${by}) (increase(vault_audit_log_response_failure{${sel}}[10m])) > 0";
            severity = "critical";
            summary = "OpenBao refuses requests it cannot audit.";
            description = "No audit device of ${instance} could log some requests in the last 10 minutes, so OpenBao refused them. Check the audit devices (`bao audit list`) and the space or endpoint they write to.";
          };
          OpenBaoMetricsMissing = {
            expr = "count by (${by}) (up{${sel}} == 1) unless on (${by}) count by (${by}) (vault_core_unsealed{${sel}})";
            "for" = "15m";
            severity = "warning";
            summary = "OpenBao reports no metrics.";
            description = "The pods of ${instance} are scraped but report no vault_core_unsealed, so the seal and leader alerts cannot fire. Check `settings.telemetry` for a filter that drops the vault.core metrics, and the server log.";
          };
        }
        // lib.optionalAttrs (replicas > 1) {
          OpenBaoSealed = {
            expr = "max by (${by}, pod) (vault_core_unsealed{${sel}}) == 0 and on (${by}) max by (${by}) (vault_core_unsealed{${sel}}) == 1";
            "for" = "10m";
            severity = "warning";
            summary = "An OpenBao pod is sealed.";
            description = "Pod {{ $labels.pod }} of ${instance} has been sealed for 10 minutes, so it serves no request and one more lost pod stops OpenBao. ${
              if config.seal.type == "static" then
                "It unseals itself with the key in the unsealKey Secret; check that Secret and the pod log."
              else
                "Unseal it with `bao operator unseal`."
            }";
          };
          # Autopilot reports healthy = 0 when a peer lags or does not
          # answer, and failure_tolerance = 0 when losing one more voter
          # loses quorum.
          OpenBaoRaftUnhealthy = {
            expr = "min by (${by}) (${fromLeader "vault_autopilot_healthy"}) == 0 or min by (${by}) (${fromLeader "vault_autopilot_failure_tolerance"}) < 1";
            "for" = "10m";
            severity = "warning";
            summary = "OpenBao's Raft cluster is degraded.";
            description = "The active pod of ${instance} reports an unhealthy Raft peer or no failure tolerance, so losing one more pod stops OpenBao. Check `bao operator raft autopilot state` and the pods that it names.";
          };
        };
      } args
    )
  ];
}
