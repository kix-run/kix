# Shared constants, alerts, and build helpers for the Harbor package.

{
  lib,
  kix,
  scope,
}:

rec {
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "harbor ${ns}/${name}";
  release = "2.15.2";
  tag = "v${release}";

  # Every component serves /metrics on this port when metrics are on.
  metricsPort = 8001;
  registryUser = "harbor_registry_user";

  # Service names, shared by the Service builders and the alert selectors.
  svc = {
    core = "${name}-core";
    portal = "${name}-portal";
    registry = "${name}-registry";
    jobservice = "${name}-jobservice";
    exporter = "${name}-exporter";
  };

  secretKeys = [
    "adminPassword" # initial admin login (HARBOR_ADMIN_PASSWORD)
    "secretKey" # 16 characters, encrypts credentials Harbor stores in the database
    "coreSecret" # CORE_SECRET: core, jobservice, and registryctl authenticate each other
    "jobserviceSecret" # JOBSERVICE_SECRET
    "csrfKey" # CSRF_KEY, 32 characters
    "registryHttpSecret" # REGISTRY_HTTP_SECRET, signs the registry's upload state
    "registryPassword" # core and jobservice log in to the registry with it
    "tokenPrivateKey" # RSA private key (PEM) that signs registry bearer tokens
  ];

  sel = s: ''namespace="${ns}",service="${s}"'';
  down = lib.concatMapStringsSep " or " (
    s: "sum by (namespace, service) (up{${sel s}}) == 0 or absent(up{${sel s}})"
  );

  alerts = {
    HarborHealthCheckFailed = {
      expr = "harbor_health{${sel svc.exporter}} == 0";
      "for" = "5m";
      severity = "critical";
      summary = "Harbor health check failed";
      description = "Harbor ${ns}/${name} reports an unhealthy component.";
    };
    HarborCoreHighInflightRequests = {
      expr = "harbor_core_http_inflight_requests{${sel svc.core}} > 100";
      "for" = "10m";
      severity = "warning";
      summary = "High number of inflight requests in Harbor core";
      description = "Harbor core pod {{ $labels.pod }} has more than 100 inflight requests.";
    };
    HarborCoreHighRequestDuration = {
      expr = "(sum by (namespace, service, method, pod) (rate(harbor_core_http_request_duration_seconds_sum{${sel svc.core}}[5m])) / sum by (namespace, service, method, pod) (rate(harbor_core_http_request_duration_seconds_count{${sel svc.core}}[5m]))) > 1";
      "for" = "10m";
      severity = "warning";
      summary = "High request duration in Harbor core";
      description = "Harbor core pod {{ $labels.pod }} has an average {{ $labels.method }} request duration above 1 second.";
    };
    # The floor of one request a second keeps a single error on a quiet
    # registry from firing it.
    HarborCoreHttp5xxRequestErrors = {
      expr = ''sum by (namespace, service) (rate(harbor_core_http_request_total{code=~"5..",${sel svc.core}}[5m])) / sum by (namespace, service) (rate(harbor_core_http_request_total{${sel svc.core}}[5m])) > 0.1 and sum by (namespace, service) (rate(harbor_core_http_request_total{${sel svc.core}}[5m])) > 1'';
      "for" = "10m";
      severity = "warning";
      summary = "High rate of HTTP 5xx errors in Harbor core";
      description = "{{ $value | humanizePercentage }} of Harbor ${ns}/${name} core requests return HTTP 5xx. Check the core pods' logs and the database.";
    };
    HarborProjectQuotaUsageHigh = {
      expr = "(harbor_project_quota_usage_byte{${sel svc.exporter}} / harbor_project_quota_byte{${sel svc.exporter}}) > 0.8";
      "for" = "10m";
      severity = "warning";
      summary = "High quota usage in Harbor project";
      description = "Quota usage in Harbor project {{ $labels.project_name }} is above 80%.";
    };
    HarborTaskQueueSizeHigh = {
      expr = "harbor_task_queue_size{${sel svc.exporter}} > 20";
      "for" = "10m";
      severity = "warning";
      summary = "High task queue size in Harbor";
      description = "Harbor ${ns}/${name} has more than 20 {{ $labels.type }} tasks queued.";
    };
    HarborTaskQueueLatencyHigh = {
      expr = "harbor_task_queue_latency{${sel svc.exporter}} > 60";
      "for" = "10m";
      severity = "warning";
      summary = "High task queue latency in Harbor";
      description = "Harbor ${ns}/${name} {{ $labels.type }} tasks wait more than 60 seconds in the queue.";
    };
    HarborTaskConcurrencyHigh = {
      expr = "harbor_task_concurrency{${sel svc.exporter}} > 10";
      "for" = "10m";
      severity = "warning";
      summary = "High task concurrency in Harbor";
      description = "Harbor ${ns}/${name} runs more than 10 {{ $labels.type }} tasks at once.";
    };
    # Every target of a component down, or none at all. One replica of
    # several down is left to the generic TargetDown.
    HarborDown = {
      expr = down [
        svc.core
        svc.registry
      ];
      "for" = "10m";
      severity = "critical";
      summary = "Harbor core or registry is down";
      description = "Prometheus has scraped no target of Harbor ${ns}/${name} Service {{ $labels.service }} for 10 minutes, so pushes and pulls fail. Check that component's pods.";
    };
    HarborComponentDown = {
      expr = down [
        svc.jobservice
        svc.exporter
      ];
      "for" = "10m";
      severity = "warning";
      summary = "A Harbor background component is down";
      description = "Prometheus has scraped no target of Harbor ${ns}/${name} Service {{ $labels.service }} for 10 minutes. Replication, garbage collection, and scans wait for the job service; the exporter's metrics and alerts stop. Check that component's pods.";
    };
  };

  forBuild =
    {
      self,
      config,
      database ? null,
      redis,
      harborSecrets,
      caBundle ? null,
      prometheus ? null,
      reloader ? null,
    }:
    rec {
      metricsEnabled = config.metrics.enabled && prometheus != null;

      # Every read of a secret dependency goes through these bindings, so
      # a missing key fails here with the secret's name, before any
      # `keyRef` throws.
      secrets = kix.contracts.secret.helpers.use {
        inherit who;
        arg = "harborSecrets";
        dep = harborSecrets;
        keys = secretKeys;
      };
      ca = kix.contracts.secret.helpers.use {
        inherit who;
        arg = "caBundle";
        dep = caBundle;
        keys = [ "ca.crt" ];
      };
      # Not kix.contracts.secret.helpers.use: its message suggests wiring another Secret
      # through deps.database, which takes a database.
      dbCredentials =
        let
          creds = database.out.credentials;
          declared = if creds.out.keys or null == null then [ ] else creds.out.keys;
        in
        if builtins.elem "username" declared && builtins.elem "password" declared then
          creds
        else
          throw "${who}: the database dependency's credentials Secret \"${creds.out.name}\" declares ${
            if declared == [ ] then "no keys" else lib.concatStringsSep ", " declared
          }; this package reads its `username` and `password` keys. Wire a database whose out.credentials declares both.";
      redisServer = kix.contracts.redis.helpers.requirePlaintext who redis;
      valkeySecret = redisServer.out.credentials or null;

      # A pod template annotation that changes with a Secret's content,
      # so the pods roll when it changes. A secret-ref has no content
      # hash and gets none; `reloadOn` covers it.
      checksumOf =
        key: s:
        lib.optionalAttrs (s != null && s.out ? identityHash) { "checksum/${key}" = s.out.identityHash; };

      # Names the secret-ref Secrets among `refs` in reloader's annotation
      # on Deployment builder args, when a reloader is wired.
      reloadOn =
        refs: args:
        let
          untracked = builtins.filter (s: s != null && !(s.out ? identityHash)) refs;
        in
        if reloader == null || untracked == [ ] then args else reloader.out.withReloadOn untracked args;

      # Database
      dbTls = database.out.tls or null;
      sslmode =
        if config.database.sslmode != null then
          config.database.sslmode
        else if dbTls == true then
          "require"
        else if dbTls == false then
          "disable"
        else
          throw "${who}: the database dependency does not say whether it serves TLS (it publishes no out.tls). Set database.sslmode to \"require\" for a server with TLS, or \"disable\" for one without.";
      dbLoginEnv =
        userVar: passwordVar:
        dbCredentials.out.mkEnv {
          ${userVar} = "username";
          ${passwordVar} = "password";
        };

      # `out.url` carries the endpoint fact: the consuming pod gets the
      # netpol egress and waits for the Service.
      coreUrl = self.coreService.out.url { };
      tokenServiceUrl = "${coreUrl}/service/token";
      portalUrl = self.portalService.out.url { };
      registryUrl = self.registryService.out.url { };
      registryCtlUrl = self.registryService.out.url { port = 8080; };
      jobserviceUrl = self.jobserviceService.out.url { };

      # Valkey. The password arrives as REDIS_PASSWORD from valkey's own
      # Secret and Kubernetes splices it into each URL through $(VAR)
      # expansion, so no ConfigMap carries it.
      redisAuth = valkeySecret != null;
      # With Sentinel on, the valkey Service also routes to read-only
      # replicas, so Harbor asks Sentinel for the primary: the
      # `redis+sentinel://<sentinels>/<primary set>/<db>` URL and the
      # registry's `sentinelMasterSet`, as harbor-helm writes them for an
      # external Sentinel.
      redisSentinel = kix.contracts.redis.helpers.usesSentinel redisServer;
      redisAddr =
        if redisSentinel then
          "${redisServer.out.host}:${redisServer.out.sentinel.port}"
        else
          "${redisServer.out.host}:${redisServer.out.port}";
      redisUrl =
        db:
        "${
          if redisSentinel then "redis+sentinel" else "redis"
        }://${lib.optionalString redisAuth ":$(REDIS_PASSWORD)@"}${redisAddr}${lib.optionalString redisSentinel "/${redisServer.out.sentinel.primarySet}"}/${toString db}";
      redisPasswordRef = var: valkeySecret.out.keyRef "password" // { name = var; };
      redisPasswordEnv = lib.optional redisAuth (redisPasswordRef "REDIS_PASSWORD");
      valkeyChecksum = checksumOf "valkey-password" valkeySecret;

      # Go's crypto/x509 on Linux reads the first bundle file it finds
      # (/etc/pki/tls/certs/ca-bundle.crt on Photon) plus every file in
      # each SSL_CERT_DIR directory. The first two entries are Go's
      # defaults; a directory that does not exist is skipped.
      caTrust.SSL_CERT_DIR = "/etc/ssl/certs:/etc/pki/tls/certs:/harbor_cust_cert";

      # A component's env list: the Secret references first (Kubernetes
      # expands $(VAR) only from entries earlier in the list), then the
      # tunables with the instance's `env` over them, then the variables
      # the package owns. `facts` are the keys of the component's
      # ConfigMap, which reaches the pod through envFrom; an `env` entry
      # of the same name would win over it, so `env` may not set one.
      componentEnv =
        {
          option,
          secretEnv,
          facts ? [ ],
          sslmodeVar ? null,
          vars ? { },
          tunables ? { },
          env ? { },
          owned ? [ ],
        }:
        secretEnv
        ++ kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            defaults = tunables;
            owned = [
              {
                names = lib.remove sslmodeVar facts;
                from = "a ConfigMap the package derives from its dependencies";
                fix = "Remove it from ${option}.";
              }
              {
                names = map (e: e.name) secretEnv;
                from = "a dependency's Secret";
                fix = "Remove it from ${option}; wire another Secret through deps.";
              }
              {
                inherit vars;
                from = "the package's dependencies";
                fix = "Remove it from ${option}.";
              }
              {
                vars = caTrust;
                from = "the package, which adds the caBundle dependency to Go's certificate search path";
                fix = "Remove it from ${option}; wire a caBundle dependency to trust another CA.";
              }
            ]
            ++ lib.optional (sslmodeVar != null) {
              names = [ sslmodeVar ];
              from = "database.sslmode";
              fix = "Set database.sslmode instead.";
            }
            ++ owned;
          } env
        );

      componentSelector =
        component: scope.selectorLabels // { "app.kubernetes.io/component" = component; };
      coreSelector = componentSelector "core";
      jobserviceSelector = componentSelector "jobservice";
      componentLabels = component: {
        "app.kubernetes.io/component" = component;
      };

      containerSecurityContext = {
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        privileged = false;
        # Each container mounts an emptyDir at every path it writes: /tmp,
        # plus /etc/core/ca and /etc/core/token for core. The Go
        # components' image entrypoints run install_cert.sh first, which
        # writes to /etc/pki/tls/certs/ca-bundle.crt in the image and so
        # fails on this read-only root. Their `command` and `args` are the
        # exec line of that entrypoint script instead, and SSL_CERT_DIR has
        # the binaries read /harbor_cust_cert directly. Recheck the exec
        # lines when the release changes.
        readOnlyRootFilesystem = true;
        runAsNonRoot = true;
        seccompProfile.type = "RuntimeDefault";
      };
      caBundleMount =
        if ca == null then
          null
        else
          kix.mount.secret ca {
            name = "ca-bundle-certs";
            mountPath = "/harbor_cust_cert/custom-ca.crt";
            subPath = "ca.crt";
          };

      # The kubelet evicts a pod whose emptyDir grows past its sizeLimit,
      # so a runaway temp file cannot fill the node's disk.
      tmpMount =
        mountName:
        kix.mount.emptyDir {
          name = mountName;
          mountPath = "/tmp";
          sizeLimit = "1Gi";
        };

      harborPodDefaults = {
        securityContext = {
          runAsUser = 10000;
          fsGroup = 10000;
        };
        automountServiceAccountToken = false;
        terminationGracePeriodSeconds = 120;
      };

      # Per-component probes: base holds shared thresholds, each component
      # overrides httpGet.
      probeBase = {
        httpGet = {
          scheme = "HTTP";
          port = 8080;
        };
        periodSeconds = 10;
        failureThreshold = 3;
        timeoutSeconds = 1;
      };
      coreProbe = lib.recursiveUpdate probeBase {
        httpGet.path = "/api/v2.0/ping";
        failureThreshold = 2;
      };
      portalProbe = lib.recursiveUpdate probeBase { httpGet.path = "/"; };
      registryProbe = lib.recursiveUpdate probeBase {
        httpGet = {
          path = "/";
          port = 5000;
        };
      };
      registryCtlProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/health"; };
      jobserviceProbe = lib.recursiveUpdate probeBase { httpGet.path = "/api/v1/stats"; };
      exporterProbe = lib.recursiveUpdate probeBase {
        httpGet = {
          path = "/";
          port = metricsPort;
        };
      };

      metricsContainerPort = lib.optional metricsEnabled (kix.port "metrics" metricsPort);
      # Numeric targetPorts throughout: the netpol layer copies them
      # into consumers' egress rules, and Cilium drops a named one.
      metricsServicePort = lib.optional metricsEnabled {
        name = "http-metrics";
        port = metricsPort;
        targetPort = metricsPort;
        protocol = "TCP";
      };
    };
}
