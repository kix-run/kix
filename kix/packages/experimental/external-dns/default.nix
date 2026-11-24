# external-dns: publishes DNS records in an external provider for the
# hostnames of Services, Ingresses, nodes, pods, and Gateway API routes.
#
# One Deployment runs the upstream binary with one replica. external-dns has
# no leader election, so a second pod would write the same records at the
# same time. The ClusterRole and the Gateway API CRD markers are derived from
# `sources` (sources.nix); the provider list and the credential variables
# each provider reads are in providers.nix. Both files follow `release`, so
# an `image.tag` of another major.minor release fails the build.
#
# Required config: `provider`, `policy`, and `txtOwnerId` have no default.
#
#   instances.external-dns.external-dns = {
#     package = packages.experimental.external-dns;
#     deps.providerCredentials = ref.external-dns.cloudflare-api-token;
#     config = {
#       provider = "cloudflare";
#       policy = "upsert-only";
#       txtOwnerId = "prod/external-dns";      # unique per writer of a zone
#       secretEnv.CF_API_TOKEN = "api-token";  # variable = key of the Secret
#       extraArgs = [ "--domain-filter=example.com" ];
#     };
#   };
#
# Dependencies:
#   providerCredentials (optional)  a secret or secret-ref instance in the
#                                   same namespace holding the provider's API
#                                   credentials. With `secretEnv` empty the
#                                   whole Secret is injected with `envFrom`,
#                                   so its keys must be the variable names
#                                   the provider reads; `secretEnv` maps
#                                   variables to differently named keys and
#                                   injects only those.
#   prometheus (optional)           metrics Service, ServiceMonitor, and
#                                   alerts.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series.
#   ExternalDNSDown (warning)       the pod answers no scrape. Published
#                                   records stay; changes are not published.
#   ExternalDNSSyncStale (warning)  no successful synchronization for three
#                                   intervals (at least 15 minutes), such as
#                                   when the provider refuses the credential
#                                   or rate-limits, or a source fails.
# Source and registry errors (`external_dns_source_errors_total`,
# `external_dns_registry_errors_total`) end the synchronization before its
# timestamp is set, so the stale alert covers them without a rule of its
# own. A crash loop is left to prometheus-default-rules.
#
# Credentials belong in the providerCredentials Secret, not in the rendered
# manifests. external-dns reads every flag from `EXTERNAL_DNS_<FLAG>` as
# well, so a credential that upstream takes as a flag (`--pdns-api-key`,
# `--rfc2136-tsig-secret`, and the others in `secretFlags`) goes in that
# Secret under the variable's name. Those flags in `extraArgs`, and a
# literal string in `env` for a credential variable, are refused.
#
# Egress: `meta.network.intents` cannot read config, so every instance may
# reach the world on TCP 443, which covers the HTTPS APIs of the hosted
# providers. A provider on another port warns under an enforcer.
#
# Not supported: webhook providers, which run as a sidecar container, and
# `--once`, after which the Deployment would restart the process forever.
# `--registry=crd` and `--gateway-listener-sets` need RBAC the package does
# not grant, and a warning says so.
#
# Escape hatches: `extraArgs` for upstream flags the package does not type
# (domain filters, TXT prefix, provider endpoints), `env`, and the
# instance's `partsOverlays` for pod labels, placement, and extra RBAC rules.
#
# Upgrades: the Deployment keeps no state in the cluster. Records and their
# TXT ownership records live in the provider, and v0.24.0 reads and adopts
# what v0.23.0 wrote. Going back is a deploy of the previous package version,
# which adopts the same records. Upstream asks for a first run with
# `--dry-run=true` in `extraArgs` and says nothing about going back. With the
# `gateway-httproute` or `gateway-grpcroute` source, a hostname from an
# annotation or `--fqdn-template` now replaces the listener's hostname, so
# `policy = "sync"` deletes the records that came from the listener.
#
# `out`: root is the Deployment, and `out` adds `version`, the external-dns
# version `image.tag` names.

{
  scope,
  lib,
  kix,
}:

let
  release = "0.24.0";
  metricsPort = 7979;

  providers = import ./providers.nix;
  sources = import ./sources.nix scope.rbac;

  name = scope.instanceName;
  ns = scope.namespaceName;

  # kingpin's DefaultEnvars (pkg/apis/externaldns/types.go) reads `--<flag>`
  # from this variable when the flag is not on the command line.
  flagEnvVar = flag: "EXTERNAL_DNS_" + lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] flag);

  # Upstream flags at v0.24.0 whose value is a credential.
  secretFlags = [
    "pdns-api-key"
    "godaddy-api-key"
    "godaddy-api-secret"
    "exoscale-apikey"
    "exoscale-apisecret"
    "rfc2136-tsig-secret"
    "rfc2136-kerberos-password"
    "pihole-password"
    "txt-encrypt-aes-key"
  ];

  # Variables whose value is a credential, for any provider.
  secretVariables =
    lib.unique (builtins.concatMap (p: p.secretVariables or [ ]) (builtins.attrValues providers))
    ++ map flagEnvVar secretFlags;

  # The variables of the flags the package sets. kingpin gives the command
  # line precedence, so the same name from `env` or the Secret is ignored.
  ownedEnvNames = map flagEnvVar [
    "provider"
    "policy"
    "txt-owner-id"
    "source"
    "interval"
    "metrics-address"
  ];

  # "CF_API_TOKEN, or CF_API_KEY and CF_API_EMAIL"
  describeKeySets = sets: lib.concatMapStringsSep ", or " (lib.concatStringsSep " and ") sets;
  listOrNone = names: if names == [ ] then "nothing" else lib.concatStringsSep ", " names;

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
    # Upstream's README ("Kubernetes version compatibility") supports
    # Kubernetes 1.21 and every later version for external-dns 0.18 and
    # later, and states no upper bound.
    k8s = {
      minVersion = "1.21";
      reason = "[K3140] external-dns ${release} supports Kubernetes 1.21 and later. Move the cluster to a supported Kubernetes version first";
    };
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
      digest = "sha256:a80a146d2540fa138565e404f0625157271071a06093021f27ae19d8316d10f9";
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
        minutes, or hours, such as `"90s"` or `"5m"`. ExternalDNSSyncStale
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
      literalSecrets = builtins.filter (var: builtins.elem var secretVariables) s.envStrings;
      firstLiteral = builtins.head (literalSecrets ++ [ "" ]);
      ownedKeys = lib.optionals (s.dep != null && config.secretEnv == { }) (
        builtins.filter (key: builtins.elem key ownedEnvNames) s.declared
      );
    in
    [
      # sources.nix and providers.nix follow `release`, and another release
      # may need other RBAC rules or accept other providers.
      (kix.image.checkRelease {
        inherit (config) image;
        inherit release;
        reason = "the ClusterRole rules (sources.nix) and supported providers (providers.nix) match external-dns v${release}";
        fix = "To update this package to another version, change release in kix/packages/experimental/external-dns/default.nix and update sources.nix and providers.nix from clusterrole.yaml in that version's chart and pkg/apis/externaldns/types.go.";
      })
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
            "secretEnv.${var} names key \"${key}\", and providerCredentials \"${depName}\" declares ${listOrNone s.declared}. Map one of those keys, or add \"${key}\" to that instance's keys."
          ) wrongKeys
        );
      }
      {
        assertion = config.secretEnv == { } || s.dep != null;
        message = "secretEnv maps ${lib.concatStringsSep ", " (builtins.attrNames config.secretEnv)} but no providerCredentials dependency is wired. Set deps.providerCredentials = ref.${ns}.<instance>.";
      }
      {
        assertion = literalSecrets == [ ];
        message = "env sets ${lib.concatStringsSep ", " literalSecrets} to a literal string, which would be stored in the Nix store and the rendered manifests. Put the credential in a Secret wired as deps.providerCredentials, and name the key ${firstLiteral} or map it with secretEnv.${firstLiteral} = \"<key>\".";
      }
      {
        assertion = ownedKeys == [ ];
        message = "providerCredentials \"${depName}\" declares ${lib.concatStringsSep ", " ownedKeys}, which envFrom injects as variables of flags the package sets, and the flags take precedence. Remove those keys from that Secret, or inject only the credential keys with secretEnv.";
      }
    ];

  # The fixes for these need `partsOverlays` or a namespace NetworkPolicy,
  # which the package cannot see, so they warn instead of failing.
  warnings =
    { config, ... }:
    let
      crdRegistry = builtins.elem "crd" (kix.argValues { parser = "gnu"; } "--registry" config.extraArgs);
      listenerSets = builtins.any (
        arg: arg == "--gateway-listener-sets" || arg == "--gateway-listener-sets=true"
      ) config.extraArgs;
      port = providerPorts.${config.provider} or null;
    in
    lib.optional crdRegistry "extraArgs set --registry=crd, which keeps ownership records in resources of the dnsrecords.externaldns.k8s.io CRD. The package neither installs that CRD nor grants RBAC for dnsrecords and dnsrecords/status. Install the CRD, and add the rules to the ClusterRole with partsOverlays."
    ++ lib.optional listenerSets "extraArgs make external-dns use listenersets, which the package grants no RBAC for. Add the rules to the ClusterRole with partsOverlays."
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
              scope.mkCRDRef (
                {
                  group = "gateway.networking.k8s.io";
                  inherit (ref) kind plural;
                  version = "v1";
                  crdScope = "Namespaced";
                }
                # A route runs no pods; a Gateway may, through its controller.
                // lib.optionalAttrs (ref.kind != "Gateway") { usesAtLeast = _: { }; }
              )
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
            inherit scope;
            owned = [
              {
                names = ownedEnvNames;
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

        # external-dns parses flags with kingpin (pkg/apis/externaldns/types.go
        # upstream), which refuses a repeated single-value flag at startup.
        args = kix.mergeArgs {
          inherit scope;
          parser = "gnu";
          args = [
            {
              flags = [ "--provider=${config.provider}" ];
              from = "the provider option";
              fix = "Set provider instead.";
            }
            {
              flags = [ "--policy=${config.policy}" ];
              from = "the policy option";
              fix = "Set policy instead.";
            }
            {
              flags = [ "--txt-owner-id=${config.txtOwnerId}" ];
              from = "the txtOwnerId option";
              fix = "Set txtOwnerId instead.";
            }
            {
              flags = [ "--interval=${config.interval}" ];
              from = "the interval option";
              fix = "Set interval instead.";
            }
            {
              flags = [ "--metrics-address=:${toString metricsPort}" ];
              reason = "the probes, metrics Service, and ServiceMonitor use port ${toString metricsPort}.";
            }
            # `--source` in extraArgs would bypass the RBAC derived from
            # `sources`.
            {
              flags = map (s: "--source=${s}") selected;
              names = [ "--source" ];
              from = "the sources option";
              fix = "Set sources instead, which also grants the required RBAC.";
            }
            {
              names = [ "--once" ];
              reason = "--once makes external-dns exit after a single sync, causing the Deployment to restart it in a loop.";
            }
          ]
          ++ map (
            flag:
            let
              var = flagEnvVar flag;
            in
            {
              names = [ "--${flag}" ];
              reason = "passing a credential as a flag exposes it in Kix's local store and the pod spec.";
              fix = "Store the credential in the providerCredentials Secret under key ${var} (or map it with secretEnv.${var} = \"<key>\"), and remove --${flag} from extraArgs.";
            }
          ) secretFlags;
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
              # names a Secret managed outside Kix, which has no content
              # hash, so a rotation does not roll the pod.
              // lib.optionalAttrs (providerCredentials != null && providerCredentials.out ? contentHash) {
                annotations."checksum/provider-credentials" = providerCredentials.out.contentHash;
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

        root = {
          resource = self.deployment;
          out.version = kix.image.version config.image;
        };
      }
      // clusterRoles
      // crdRefParts
    )

    # The lib passes a build function only the arguments it names, so
    # `scope` and `lib` are listed for `kix.monitor`, which reads them from
    # `args`.
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
        staleAfter = lib.max 900 (3 * kix.durations.toSeconds config.interval);
        sel = ''namespace="${ns}",service="${name}"'';
      in
      kix.monitor {
        service = "metricsService";
        port = "metrics";
        alerts = {
          ExternalDNSDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "external-dns is down.";
            description = "external-dns ${ns}/${name} has not answered a scrape for 10 minutes. The records it published stay in place, but new and changed hostnames are not published. Check its Deployment in ${ns}.";
          };
          # The gauge is 0 until the first successful synchronization, so
          # an instance that never synchronized fires too. A source or
          # provider error that external-dns retries (a soft error) stops
          # the gauge; any other error exits the process, which the down
          # alert and prometheus-default-rules report.
          ExternalDNSSyncStale = {
            expr = "time() - max by (namespace, service) (external_dns_controller_last_sync_timestamp_seconds{${sel}}) > ${toString staleAfter}";
            "for" = "5m";
            severity = "warning";
            summary = "external-dns has not synchronized DNS records recently.";
            description = "external-dns ${ns}/${name} last synchronized with its DNS provider {{ $value | humanizeDuration }} ago, more than three intervals, so DNS records do not follow changed hostnames. Look in its log for provider API errors, such as HTTP 429 rate limiting or a refused credential, and for source errors.";
          };
        };
      } args
    )
  ];
}
