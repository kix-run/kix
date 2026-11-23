# OpenBao StatefulSet, Services, cert-manager TLS chain, and server ConfigMaps.

{
  self,
  config,
  clusterConfig,
  scope,
  lib,
  kix,
  availability,
  certManager,
  unsealKey ? null,
  storageClasses ? null,
  prometheus ? null,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    ns
    who
    ports
    metricsServiceName
    reconcileRole
    dirs
    labelsFor
    uid
    gid
    containerSecurity
    headlessName
    tlsSecretName
    caSecretName
    reconcilePolicy
    ;

  replicas = kix.availability.pick availability {
    none = 1;
    pod = 3;
    node = 3;
    zone = 3;
  };

  selfInit = config.seal.type == "static";
  metricsOn = config.metrics.enabled && prometheus != null;

  certCrds =
    certManager.out.crds or (scope.fail {
      package = "openbao";
      message = "the certManager dependency has no out.crds, as with an import.";
      fix = "Wire a managed cert-manager instance with deps.certManager = ref.<namespace>.<instance>.";
    });

  unseal =
    if !selfInit then
      null
    else if unsealKey == null then
      scope.fail {
        package = "openbao";
        option = "seal.type";
        message = "seal.type is \"static\" and there is no unsealKey dependency.";
        fix = "Add a secret aliased unsealKey with key \"key\", a 32-byte key (`openssl rand -hex 32 | tr -d '\\n'`), or set seal.type = \"shamir\" to initialize and unseal OpenBao by hand.";
      }
    else
      kix.contracts.secret.helpers.use {
        inherit who;
        arg = "unsealKey";
        dep = unsealKey;
        keys = [ "key" ];
      };

  storageClassName =
    if config.storage.storageClassName != null then
      config.storage.storageClassName
    else if storageClasses != null then
      storageClasses.out.storageClassName
    else
      null;

  headlessFqdn = self.headlessService.out.fqdn;
  podUrl = i: "https://${name}-${toString i}.${headlessFqdn}:${toString ports.api}";
  enginePaths = builtins.attrNames config.secretsEngines;

  # Top-level keys the package writes, with what derives each one.
  ownedSettings = {
    listener = "the Services, the probes, the certificate paths, and the metrics listener";
    storage = "the volumes and the Raft join addresses of the StatefulSet";
    seal = "seal.type and seal.keyId";
    api_addr = "BAO_API_ADDR, derived from each pod's name";
    cluster_addr = "BAO_CLUSTER_ADDR, derived from each pod's name";
    initialize = "the self-initialization the reconcile Job depends on";
  };
  # The telemetry keys the metrics listener and the alerts rely on.
  ownedTelemetry = {
    disable_hostname = "gauge names without the pod name, which the alerts read";
    prometheus_retention_time = "the Prometheus metrics the ServiceMonitor scrapes";
    metrics_prefix = "the vault_ metric names the alerts read";
  };
  telemetryOwned = lib.optionals metricsOn (
    builtins.filter (k: ownedTelemetry ? ${k}) (builtins.attrNames (config.settings.telemetry or { }))
  );
  settingsOwned =
    builtins.filter (k: ownedSettings ? ${k}) (builtins.attrNames config.settings)
    ++ map (k: "telemetry.${k}") telemetryOwned;
  ownedReason =
    k:
    if lib.hasPrefix "telemetry." k then
      ownedTelemetry.${lib.removePrefix "telemetry." k}
    else
      ownedSettings.${k};
  serverConfig =
    if settingsOwned != [ ] then
      scope.fail {
        package = "openbao";
        option = "settings";
        message = "settings sets ${lib.concatStringsSep ", " settingsOwned}, which the package sets from ${
          lib.concatMapStringsSep "; " ownedReason settingsOwned
        }.";
        fix = "Remove ${if builtins.length settingsOwned == 1 then "it" else "them"} from settings.";
      }
    else
      lib.recursiveUpdate baseConfig config.settings;

  baseConfig = {
    listener = [
      {
        tcp = {
          address = "[::]:${toString ports.api}";
          cluster_address = "[::]:${toString ports.cluster}";
          tls_cert_file = "${dirs.tls}/tls.crt";
          tls_key_file = "${dirs.tls}/tls.key";
          # OpenBao 2.7.0 added tls_auto_reload.
          tls_auto_reload = true;
        };
      }
    ]
    ++ lib.optional metricsOn {
      tcp = {
        address = "[::]:${toString ports.metrics}";
        tls_disable = true;
        telemetry = {
          metrics_only = true;
          unauthenticated_metrics_access = true;
        };
      };
    };
    storage.raft = {
      path = dirs.data;
      retry_join = map (i: {
        leader_api_addr = podUrl i;
        leader_ca_cert_file = "${dirs.tls}/ca.crt";
      }) (lib.range 0 (replicas - 1));
    };
  }
  // lib.optionalAttrs metricsOn {
    telemetry = {
      disable_hostname = true;
      # OpenBao's default. A series with no update for this long drops
      # out of the output and a counter starts again from zero, so a
      # day keeps the audit counters continuous on an instance that
      # serves few requests. Zero would turn off the Prometheus output.
      prometheus_retention_time = "24h";
    };
  }
  // lib.optionalAttrs selfInit {
    seal.static = {
      current_key_id = config.seal.keyId;
      current_key = "file://${dirs.unseal}/key";
    };
  };

  request = rname: path: data: {
    ${rname} = {
      operation = "update";
      inherit path data;
    };
  };

  initConfig.initialize = [
    {
      kix-bootstrap.request = [
        (request "enable-kubernetes-auth" "sys/auth/kubernetes" { type = "kubernetes"; })
        # In a pod, Kubernetes auth reviews tokens with the pod's own
        # ServiceAccount token and CA.
        (request "configure-kubernetes-auth" "auth/kubernetes/config" {
          kubernetes_host = "https://kubernetes.default.svc";
        })
        (request "reconcile-policy" "sys/policies/acl/${reconcileRole}" {
          policy = reconcilePolicy enginePaths;
        })
        (request "reconcile-role" "auth/kubernetes/role/${reconcileRole}" {
          bound_service_account_names = [ self.reconcileServiceAccount.out.name ];
          bound_service_account_namespaces = [ ns ];
          token_policies = [ reconcileRole ];
          token_ttl = "15m";
          token_max_ttl = "15m";
        })
      ];
    }
  ];

  podAddr = port: "https://$(POD_NAME).${headlessFqdn}:${toString port}";

  # POD_NAME comes first: Kubernetes expands $(POD_NAME) only in the
  # variables after it, and mkEnvVars sorts by name.
  env = [
    {
      name = "POD_NAME";
      valueFrom.fieldRef.fieldPath = "metadata.name";
    }
  ]
  ++ kix.mkEnvVars (
    kix.mergeEnv {
      inherit scope;
      owned = [
        {
          vars = {
            BAO_API_ADDR = podAddr ports.api;
            BAO_CLUSTER_ADDR = podAddr ports.cluster;
            BAO_RAFT_NODE_ID = "$(POD_NAME)";
            # For `bao` run in the pod, which dials https://127.0.0.1:8200.
            BAO_CACERT = "${dirs.tls}/ca.crt";
            CONFIG_DIR = dirs.config;
            INIT_DIR = dirs.init;
            TLS_DIR = dirs.tls;
            SELF_INIT = lib.boolToString selfInit;
            PEER_ADDRS = lib.concatMapStringsSep " " podUrl (lib.range 1 (replicas - 1));
          };
          names = [
            "POD_NAME"
            "BAO_ADVERTISE_ADDR"
            "BAO_REDIRECT_ADDR"
            "BAO_RAFT_PATH"
            "BAO_RAFT_RETRY_JOIN_AS_NON_VOTER"
            "BAO_SEAL_TYPE"
            "BAO_STATIC_SEAL_CURRENT_KEY"
            "BAO_STATIC_SEAL_CURRENT_KEY_ID"
            "BAO_STATIC_SEAL_PREVIOUS_KEY"
            "BAO_STATIC_SEAL_PREVIOUS_KEY_ID"
          ];
          from = "the package, which derives the addresses, the Raft node, and the seal from the StatefulSet and the seal options";
          fix = "Remove it from env.";
        }
      ];
    } config.env
  );

  healthProbe = query: {
    httpGet = {
      path = "/v1/sys/health?${query}";
      port = "api";
      scheme = "HTTPS";
    };
  };

  issuerRef = issuer: {
    group = "cert-manager.io";
    kind = "Issuer";
    name = issuer.out.name;
  };
in
{
  serviceAccount = scope.mkResource {
    apiVersion = "v1";
    kind = "ServiceAccount";
    inherit name;
  };

  # Kubernetes auth checks each login token with a TokenReview.
  authDelegator = scope.mkClusterResource {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRoleBinding";
    name = "${name}-${ns}-auth-delegator";
    labels = scope.selectorLabels;
    extra = {
      roleRef = {
        apiGroup = "rbac.authorization.k8s.io";
        kind = "ClusterRole";
        name = "system:auth-delegator";
      };
      subjects = [
        {
          kind = "ServiceAccount";
          name = self.serviceAccount.out.name;
          namespace = ns;
        }
      ];
    };
  };

  # A CA that outlives the server certificates, so `ca.crt` stays the
  # same across renewals and clients keep trusting a renewed server.
  selfSignedIssuer = scope.mkCR certCrds.Issuer {
    name = "${name}-selfsigned";
    spec.selfSigned = { };
  };

  caCertificate = scope.mkCR certCrds.Certificate {
    name = caSecretName;
    spec = {
      secretName = caSecretName;
      isCA = true;
      commonName = "${name}.${ns} CA";
      duration = "87600h";
      privateKey.algorithm = "ECDSA";
      issuerRef = issuerRef self.selfSignedIssuer;
    };
  };

  caIssuer = scope.mkCR certCrds.Issuer {
    name = caSecretName;
    spec.ca.secretName = kix.untrackedRef {
      kind = "Secret";
      name = caSecretName;
      by = self.caCertificate;
    };
  };

  # Names spelled from the cluster domain: the StatefulSet mounts this
  # certificate's Secret and the Services select the StatefulSet's pods,
  # so reading their `out.fqdn` here would close a cycle.
  serverCertificate =
    let
      svcNames = svc: [
        svc
        "${svc}.${ns}"
        "${svc}.${ns}.svc"
        "${svc}.${ns}.svc.${clusterConfig.clusterDomain}"
      ];
    in
    scope.mkCR certCrds.Certificate {
      name = tlsSecretName;
      spec = {
        secretName = tlsSecretName;
        commonName = name;
        dnsNames =
          svcNames name
          ++ svcNames headlessName
          ++ [ "*.${headlessName}.${ns}.svc.${clusterConfig.clusterDomain}" ];
        # `bao` run in a pod dials the loopback address by default.
        ipAddresses = [ "127.0.0.1" ];
        privateKey.algorithm = "ECDSA";
        usages = [ "server auth" ];
        issuerRef = issuerRef self.caIssuer;
      };
    };

  configMap = scope.mkResource {
    apiVersion = "v1";
    kind = "ConfigMap";
    name = "${name}-config";
    data = {
      "server.json" = builtins.toJSON serverConfig;
      "start.sh" = builtins.readFile ./start.sh;
    };
  };

  # Read only on pod 0's first start, so a change does not restart the
  # pods.
  initConfigMap =
    if selfInit then
      scope.mkResource {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "${name}-init";
        data."init.json" = builtins.toJSON initConfig;
      }
    else
      null;

  statefulSet =
    {
      inherit name;
      spec = {
        inherit replicas;
        headlessService = self.headlessService;
        # Pod 0 initializes the cluster and each later pod joins the
        # pods before it, so they start one at a time.
        podManagementPolicy = "OrderedReady";
        updateStrategy.type = "RollingUpdate";
        selector.matchLabels = labelsFor "server";
        template = {
          metadata.annotations = {
            "checksum/config" = self.configMap.out.contentHash;
          }
          # A secret-ref has no contentHash. The key is read at start.
          // lib.optionalAttrs (unseal != null && unseal.out ? contentHash) {
            "checksum/unsealKey" = unseal.out.contentHash;
          };
          spec = {
            serviceAccount = self.serviceAccount;
            # Long enough for the active pod to hand over leadership.
            terminationGracePeriodSeconds = 30;
            securityContext = {
              runAsNonRoot = true;
              runAsUser = uid;
              runAsGroup = gid;
              fsGroup = gid;
              fsGroupChangePolicy = "OnRootMismatch";
              seccompProfile.type = "RuntimeDefault";
            };
            containers = [
              {
                name = "openbao";
                image = kix.image.ref config.image;
                imagePullPolicy = config.image.pullPolicy;
                command = [
                  "/bin/sh"
                  "${dirs.config}/start.sh"
                ];
                inherit env;
                ports = [
                  (kix.port "api" ports.api)
                  (kix.port "cluster" ports.cluster)
                ]
                ++ lib.optional metricsOn (kix.port "metrics" ports.metrics);
                # 200 for the active pod and standbys; 429, 473, 501
                # (not initialized), and 503 (sealed) fail.
                readinessProbe = healthProbe "standbyok=true&perfstandbyok=true" // {
                  periodSeconds = 5;
                  timeoutSeconds = 3;
                  failureThreshold = 2;
                };
                # Succeeds while the process answers, sealed or not, so
                # a sealed pod waiting for its key or for a person is not
                # restarted.
                livenessProbe = healthProbe "standbyok=true&perfstandbyok=true&sealedcode=204&uninitcode=204" // {
                  initialDelaySeconds = 10;
                  periodSeconds = 10;
                  timeoutSeconds = 5;
                  failureThreshold = 6;
                };
                resources = config.resources;
                securityContext = containerSecurity;
                volumeMounts = [
                  {
                    name = "data";
                    mountPath = dirs.data;
                  }
                  {
                    name = "tls";
                    mountPath = dirs.tls;
                    readOnly = true;
                  }
                ];
              }
            ];
            volumes = [
              # A directory mount, not subPath, so a renewed
              # certificate reaches the pod and tls_auto_reload.
              {
                name = "tls";
                secret.secretName = c.tlsSecret self;
              }
            ];
          };
        };
        volumeClaimTemplates = [
          {
            metadata.name = "data";
            spec = {
              accessModes = [ "ReadWriteOnce" ];
              resources.requests.storage = toString config.storage.size;
            }
            // lib.optionalAttrs (storageClassName != null) { inherit storageClassName; };
          }
        ];
      };
    }
    |> kix.withMounts (
      [
        (kix.mount.configMap self.configMap {
          name = "config";
          mountPath = dirs.config;
          readOnly = true;
        })
        (kix.mount.emptyDir {
          name = "tmp";
          mountPath = "/tmp";
        })
      ]
      ++ lib.optionals selfInit [
        (kix.mount.configMap self.initConfigMap {
          name = "init";
          mountPath = dirs.init;
          readOnly = true;
        })
        (kix.mount.secret unseal {
          name = "unseal";
          mountPath = dirs.unseal;
          items = [
            {
              key = "key";
              path = "key";
            }
          ];
        })
      ]
    )
    |> scope.mkStatefulSet;

  # The config reads this Service's `out.fqdn`, so it selects through
  # `rawSelector`; `out.selector` would recurse. Unready addresses are
  # published so a starting pod resolves the peers it joins.
  headlessService = scope.mkResource {
    apiVersion = "v1";
    kind = "Service";
    name = headlessName;
    labels."app.kubernetes.io/component" = "headless";
    spec = {
      clusterIP = "None";
      publishNotReadyAddresses = true;
      selector = self.statefulSet.rawSelector;
      ports = [
        {
          name = "api";
          port = ports.api;
          targetPort = ports.api;
          protocol = "TCP";
        }
        {
          name = "cluster";
          port = ports.cluster;
          targetPort = ports.cluster;
          protocol = "TCP";
        }
      ];
    };
  };

  service =
    self.statefulSet
    |> kix.service.fromWorkload {
      inherit name;
      labels."app.kubernetes.io/component" = "server";
      ports = [
        {
          name = "api";
          port = ports.api;
          targetPort = "api";
        }
      ];
    }
    |> scope.mkResource;

  # Sealed pods fail the readiness probe, and their metrics are what
  # OpenBaoSealed reads, so the Service publishes unready addresses.
  metricsService =
    if metricsOn then
      self.statefulSet
      |> kix.service.fromWorkload {
        name = metricsServiceName;
        labels."app.kubernetes.io/component" = "metrics";
        spec.publishNotReadyAddresses = true;
        ports = [
          {
            name = "metrics";
            port = ports.metrics;
            targetPort = "metrics";
            protocol = "TCP";
          }
        ];
      }
      |> scope.mkResource
    else
      null;
}
