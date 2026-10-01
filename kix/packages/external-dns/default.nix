# external-dns: publishes DNS records in an external provider for the
# hostnames of Services, Ingresses, nodes, pods, and Gateway API routes.
#
# One Deployment runs the upstream binary with one replica. external-dns has
# no leader election, so a second pod would write the same records at the
# same time. The ClusterRole and the Gateway API CRD markers are derived from
# `sources` (sources.nix); the provider list and the credential variables
# each provider reads are in providers.nix.
#
# DI deps:
#   providerCredentials (optional)  a secret or secret-ref instance in the
#                                   same namespace holding the provider's API
#                                   credentials. With `secretEnv` empty the
#                                   whole Secret is injected with `envFrom`,
#                                   so its keys must be the variable names
#                                   the provider reads; `secretEnv` maps
#                                   variables to differently named keys and
#                                   injects only those.
#   prometheus (optional)           metrics Service, ServiceMonitor, and a
#                                   stale-sync alert.
#
# Egress: `meta.network.intents` cannot read config, so every instance may
# reach the world on TCP 443, which covers the HTTPS APIs of the hosted
# providers. A provider on another port warns under an enforcer.
#
# Escape hatches: `extraArgs` for upstream flags the package does not type
# (domain filters, TXT prefix, provider settings), `env`, and the instance's
# `partsOverlays` for pod labels, placement, and extra RBAC rules.
#
# root = the Deployment.

{
  scope,
  lib,
  kix,
}:

let
  release = "0.23.0";
  metricsPort = 7979;

  providers = import ./providers.nix;
  sources = import ./sources.nix scope.rbac;

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "external-dns ${ns}/${name}";

  intervalSeconds =
    interval:
    let
      m = builtins.match "([0-9]+)([smh])" interval;
      unit = {
        s = 1;
        m = 60;
        h = 3600;
      };
    in
    lib.toInt (builtins.elemAt m 0) * unit.${builtins.elemAt m 1};

  # "CF_API_TOKEN, or CF_API_KEY and CF_API_EMAIL"
  describeKeySets = sets: lib.concatMapStringsSep ", or " (lib.concatStringsSep " and ") sets;
  listOrNone = names: if names == [ ] then "nothing" else lib.concatStringsSep ", " names;

  # The value of `flag` in `args`, in either the `--flag=value` or the
  # `--flag value` form, for every occurrence.
  flagValues =
    flag: args:
    let
      indexed = lib.imap0 (i: arg: { inherit i arg; }) args;
    in
    builtins.concatMap (
      { i, arg }:
      if lib.hasPrefix "${flag}=" arg then
        [ (lib.removePrefix "${flag}=" arg) ]
      else if arg == flag && i + 1 < builtins.length args then
        [ (builtins.elemAt args (i + 1)) ]
      else
        [ ]
    ) indexed;

  # What the instance supplies for the provider's credential variables:
  # the mapped variables or, without `secretEnv`, the Secret's keys, plus
  # the string values in `env`. A `valueFrom` entry in `env` is not counted,
  # because Kix cannot check the Secret it names.
  credentialState =
    { config, deps }:
    let
      dep = deps.providerCredentials or null;
      declared = if dep == null then [ ] else (dep.out.keys or [ ]);
      envStrings = builtins.attrNames (lib.filterAttrs (_: builtins.isString) config.env);
      fromSecret =
        if config.secretEnv != { } then
          builtins.attrNames config.secretEnv
        else if dep != null then
          declared
        else
          [ ];
      supplied = fromSecret ++ envStrings;
      keySets = providers.${config.provider}.credentialKeySets or null;
    in
    {
      inherit
        dep
        declared
        envStrings
        keySets
        ;
      complete =
        keySets == null || builtins.any (set: builtins.all (k: builtins.elem k supplied) set) keySets;
    };

  # Default ports of the providers not reached on TCP 443: DNS UPDATE
  # (rfc2136), the PowerDNS API, the Pi-hole web server, and etcd (coredns,
  # skydns).
  providerPorts = {
    rfc2136 = 53;
    pdns = 8081;
    pihole = 80;
    coredns = 2379;
    skydns = 2379;
  };
in
{
  meta = {
    version = release;
    description = "ExternalDNS, which publishes DNS records in an external provider for Services, Ingresses, and Gateway API routes";
    owner = "platform";
    # external-dns has no leader election: a second replica writes the same
    # records concurrently.
    availability.max = "none";
    network.intents.providerApi.egress = [
      {
        to = "world";
        ports = [
          {
            port = 443;
            protocol = "TCP";
          }
        ];
      }
    ];
  };

  options = {
    image = kix.options.image {
      repository = "registry.k8s.io/external-dns/external-dns";
      tag = "v${release}";
      digest = "sha256:1854499e2b08cee47c40a08e356bff20dcb192dbcfde8378fc3f900f12cad5a3";
    };

    provider = lib.mkOption {
      type = lib.types.enum (builtins.attrNames providers);
      description = "DNS provider the records are written to (`--provider`). Webhook providers are not supported.";
    };

    policy = lib.mkOption {
      type = lib.types.enum [
        "sync"
        "upsert-only"
        "create-only"
      ];
      description = ''
        How records are synchronized (`--policy`). `sync` also deletes
        records whose source is gone; `upsert-only` creates and updates but
        never deletes; `create-only` only creates. external-dns has no
        default.
      '';
    };

    txtOwnerId = lib.mkOption {
      type = lib.types.nonEmptyStr;
      example = "prod-eu/external-dns/public";
      description = ''
        Owner id written into the TXT registry records (`--txt-owner-id`).
        external-dns changes only records whose TXT record carries this id,
        so it must be unique among every external-dns instance, in any
        cluster, that writes the same zones. Changing it on a running
        install leaves the records written under the old id unowned, unless
        `extraArgs` carries `--migrate-from-txt-owner=<old id>` for one
        synchronization.
      '';
    };

    sources = lib.mkOption {
      type = lib.types.nonEmptyListOf (lib.types.enum (builtins.attrNames sources));
      default = [
        "service"
        "ingress"
      ];
      description = ''
        Resource kinds external-dns reads hostnames from (`--source`, once
        per entry). The ClusterRole grants read access to these kinds only.
        The gateway sources need the Gateway API CRDs installed in the
        cluster.
      '';
    };

    interval = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*[smh]";
      default = "1m";
      example = "5m";
      description = ''
        Time between two synchronizations (`--interval`), in seconds,
        minutes, or hours, such as `"90s"` or `"5m"`. The stale-sync alert
        fires after three intervals without a successful synchronization,
        and never sooner than 15 minutes. A longer interval lowers the rate
        of provider API calls.
      '';
    };

    secretEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.nonEmptyStr;
      default = { };
      example = {
        CF_API_TOKEN = "api-token";
      };
      description = ''
        Maps environment variables to keys of the `providerCredentials`
        Secret. Empty injects the whole Secret with `envFrom`, so its key
        names must be the variables the provider reads. Non-empty injects
        only the mapped keys.
      '';
    };

    env = kix.options.env // {
      description = ''
        Extra container environment variables. A value is a string, a
        `fieldRef` source, or a `secretKeyRef` source naming a Secret
        managed outside Kix with `kix.untrackedRef`. Provider credentials
        come from the `providerCredentials` dependency. The
        `EXTERNAL_DNS_*` variables of the flags this package sets are
        refused.
      '';
    };

    serviceAccountAnnotations = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "eks.amazonaws.com/role-arn" = "arn:aws:iam::111122223333:role/external-dns";
      };
      description = ''
        Annotations on the ServiceAccount, for workload identity on a cloud
        provider (`eks.amazonaws.com/role-arn`,
        `iam.gke.io/gcp-service-account`, or
        `azure.workload.identity/client-id`).
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--domain-filter=example.com"
        "--cloudflare-proxied"
      ];
      description = ''
        Flags appended to the package's own, verbatim. The flags the
        package sets from options (`--provider`, `--policy`,
        `--txt-owner-id`, `--interval`, `--source`) and
        `--metrics-address` are refused.
      '';
    };

    # No CPU limit: a synchronization is a short burst of API calls, and a
    # limit would only stretch it.
    resources = kix.options.resources {
      requests = {
        cpu = "50m";
        memory = "64Mi";
      };
      limits.memory = "256Mi";
    };

    metrics = kix.options.monitor;
  };

  assertions =
    { config, deps, ... }:
    let
      s = credentialState { inherit config deps; };
      depName = s.dep.out.name or "";
      keySetText = if s.keySets == null then "" else describeKeySets s.keySets;
      firstVar = if s.keySets == null then "" else builtins.head (builtins.head s.keySets);
      wrongKeys = lib.filterAttrs (_: key: !(builtins.elem key s.declared)) config.secretEnv;
    in
    [
      {
        assertion = s.complete || s.dep != null || config.secretEnv != { };
        message = "provider \"${config.provider}\" reads its API credentials from ${keySetText}, and no complete set is supplied. Add a secret or secret-ref instance in namespace \"${ns}\" holding them, set deps.providerCredentials = ref.${ns}.<instance>, and name the key ${firstVar} or map it with secretEnv.${firstVar} = \"<key>\".";
      }
      {
        assertion = s.complete || s.dep == null;
        message = "provider \"${config.provider}\" needs ${keySetText}. providerCredentials \"${depName}\" declares ${listOrNone s.declared}; secretEnv maps ${listOrNone (builtins.attrNames config.secretEnv)}; env sets ${listOrNone s.envStrings}. Map the key that holds the credential: secretEnv.${firstVar} = \"<key>\".";
      }
      {
        assertion = s.dep == null || wrongKeys == { };
        message = lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            var: key:
            "secretEnv.${var} names key \"${key}\", and providerCredentials \"${depName}\" declares ${listOrNone s.declared}."
          ) wrongKeys
        );
      }
      {
        assertion = config.secretEnv == { } || s.dep != null;
        message = "secretEnv maps ${lib.concatStringsSep ", " (builtins.attrNames config.secretEnv)} but no providerCredentials dependency is wired. Set deps.providerCredentials = ref.${ns}.<instance>.";
      }
    ];

  # The fixes for these need `partsOverlays` or a namespace NetworkPolicy,
  # which the package cannot see, so they warn instead of failing.
  warnings =
    { config, ... }:
    let
      rbacNeeds =
        lib.optional (builtins.elem "crd" (flagValues "--registry" config.extraArgs)) "dnsrecords and dnsrecords/status"
        ++ lib.optional (builtins.any (
          arg: arg == "--gateway-listener-sets" || arg == "--gateway-listener-sets=true"
        ) config.extraArgs) "listenersets";
      port = providerPorts.${config.provider} or null;
    in
    map (
      resources:
      "extraArgs make external-dns use ${resources}, which the package grants no RBAC for. Add the rules to the ClusterRole with partsOverlays."
    ) rbacNeeds
    ++
      lib.optional (port != null && scope.networkPolicyEnforcer != null)
        "egress policy allows only TCP 443 to the world; provider ${config.provider} uses port ${toString port}. Add a NetworkPolicy under namespaces.${ns}.networkPolicies.<name>.";

  build = [
    (
      {
        self,
        config,
        providerCredentials ? null,
        prometheus ? null,
        ...
      }:
      let
        selected = lib.unique config.sources;

        rules = map (r: r // { resources = lib.unique r.resources; }) (
          scope.rbac.grant (builtins.concatMap (s: sources.${s}.intents) selected)
        );

        crdRefs = lib.unique (builtins.concatMap (s: sources.${s}.crdRefs) selected);
        crdRefParts = builtins.listToAttrs (
          map (
            ref:
            lib.nameValuePair "crdRef${ref.kind}" (
              scope.mkCRDRef {
                group = "gateway.networking.k8s.io";
                inherit (ref) kind plural;
                version = "v1";
                crdScope = "Namespaced";
              }
            )
          ) crdRefs
        );

        clusterRoles = scope.rbac.mkClusterRoleSet scope {
          subjects = [
            {
              kind = "ServiceAccount";
              name = self.serviceAccount.out.name;
              namespace = ns;
            }
          ];
          roles."${name}-${ns}" = rules;
        };

        # Keys outside the Secret's declared keys are left to the
        # assertions, which name them; `keyRef` would throw first.
        declaredKeys = if providerCredentials == null then [ ] else (providerCredentials.out.keys or [ ]);
        secretVars = lib.mapAttrs (_: key: providerCredentials.out.keyRef key) (
          lib.filterAttrs (_: key: builtins.elem key declaredKeys) config.secretEnv
        );
        useEnvFrom = providerCredentials != null && config.secretEnv == { };

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            owned = [
              {
                names = [
                  "EXTERNAL_DNS_PROVIDER"
                  "EXTERNAL_DNS_POLICY"
                  "EXTERNAL_DNS_TXT_OWNER_ID"
                  "EXTERNAL_DNS_SOURCE"
                  "EXTERNAL_DNS_INTERVAL"
                  "EXTERNAL_DNS_METRICS_ADDRESS"
                ];
                from = "a flag the package sets (provider, policy, txtOwnerId, sources, interval, or the metrics address), and the flag overrides the variable";
                fix = "Set the option instead; the metrics address is fixed at :${toString metricsPort}.";
              }
              {
                vars = secretVars;
                from = "providerCredentials through secretEnv";
                fix = "Remove it from env or from secretEnv.";
              }
              {
                # A variable in `env` overrides the same name from `envFrom`
                # without any error.
                names = lib.optionals useEnvFrom declaredKeys;
                from = "providerCredentials, whose keys are injected with envFrom";
                fix = "Remove it from env, or rename the key in that Secret.";
              }
            ];
          } config.env
        );

        # kingpin refuses a repeated single-value flag at startup, and
        # `--source` here would bypass the RBAC derived from `sources`.
        args = [
          "--provider=${config.provider}"
          "--policy=${config.policy}"
          "--txt-owner-id=${config.txtOwnerId}"
          "--interval=${config.interval}"
          "--metrics-address=:${toString metricsPort}"
        ]
        ++ map (s: "--source=${s}") selected
        ++ kix.guardArgs {
          inherit who;
          owned = {
            "--provider" = "set the provider option.";
            "--policy" = "set the policy option.";
            "--txt-owner-id" = "set the txtOwnerId option.";
            "--interval" = "set the interval option.";
            "--source" = "add it to sources, which also grants its RBAC.";
            "--metrics-address" =
              "the probes, the metrics Service, and the ServiceMonitor use :${toString metricsPort}; remove it.";
          };
        } config.extraArgs;

        probe = {
          httpGet = {
            path = "/healthz";
            port = "metrics";
          };
          periodSeconds = 10;
          timeoutSeconds = 5;
          successThreshold = 1;
        };
      in
      {
        serviceAccount = scope.mkResource (
          {
            apiVersion = "v1";
            kind = "ServiceAccount";
            inherit name;
          }
          // lib.optionalAttrs (config.serviceAccountAnnotations != { }) {
            annotations = config.serviceAccountAnnotations;
          }
        );

        metricsService =
          if config.metrics.enabled && prometheus != null then
            self.deployment |> kix.service.fromWorkload { inherit name; } |> scope.mkResource
          else
            null;

        deployment = scope.mkDeployment {
          inherit name;
          requires = builtins.attrValues clusterRoles ++ builtins.attrValues crdRefParts;
          spec = {
            replicas = 1;
            # A rolling update would run the old and the new pod together.
            strategy.type = "Recreate";
            selector.matchLabels = scope.selectorLabels;
            template = {
              metadata = {
                labels = scope.selectorLabels;
              }
              # Rolls the pod when a Kix-built Secret changes. A secret-ref
              # names a Secret managed outside Kix, which has no identity
              # hash; reloader's `withReloadOn` rolls the pod for that one.
              // lib.optionalAttrs (providerCredentials != null && providerCredentials.out ? identityHash) {
                annotations."checksum/provider-credentials" = providerCredentials.out.identityHash;
              };
              spec = {
                serviceAccount = self.serviceAccount;
                # The image declares user 0. 65532 is the upstream chart's user,
                # and the binary needs no root privileges.
                securityContext = {
                  runAsNonRoot = true;
                  runAsUser = 65532;
                  runAsGroup = 65532;
                  seccompProfile.type = "RuntimeDefault";
                };
                containers = [
                  (
                    {
                      name = "external-dns";
                      image = kix.image.ref config.image;
                      inherit args;
                      ports = [ (kix.port "metrics" metricsPort) ];
                      # Timings from the upstream chart's values.yaml.
                      livenessProbe = probe // {
                        initialDelaySeconds = 10;
                        failureThreshold = 2;
                      };
                      readinessProbe = probe // {
                        initialDelaySeconds = 5;
                        failureThreshold = 6;
                      };
                      inherit (config) resources;
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        readOnlyRootFilesystem = true;
                        capabilities.drop = [ "ALL" ];
                        privileged = false;
                      };
                    }
                    // lib.optionalAttrs (config.image.pullPolicy != null) {
                      imagePullPolicy = config.image.pullPolicy;
                    }
                    // lib.optionalAttrs (env != [ ]) { inherit env; }
                    // lib.optionalAttrs useEnvFrom {
                      envFrom = [ providerCredentials.out.envFrom ];
                    }
                  )
                ];
              };
            };
          };
        };

        # The monitoring parts depend on the Deployment, not the reverse,
        # so root lists them to keep them in the build.
        root = {
          resource = self.deployment;
          requires = builtins.filter (r: r != null) [
            self.serviceMonitor
            self.prometheusRules
          ];
        };
      }
      // clusterRoles
      // crdRefParts
    )

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
        # Three synchronization intervals, at least 15 minutes, so a long
        # interval set to stay under a provider's rate limit does not keep
        # the alert firing.
        staleAfter = lib.max 900 (3 * intervalSeconds config.interval);
      in
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        alerts.ExternalDNSSyncStale = {
          expr = "time() - external_dns_controller_last_sync_timestamp_seconds{namespace=\"${ns}\", service=\"${self.metricsService.out.name}\"} > ${toString staleAfter}";
          "for" = "5m";
          severity = "warning";
          summary = "external-dns ${ns}/${name} has not synchronized DNS records for ${toString (staleAfter / 60)} minutes.";
          description = "The last successful synchronization is older than three intervals. Look for provider API errors, such as HTTP 429 rate limiting, in the pod log.";
        };
      } args
    )
  ];
}
