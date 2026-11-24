# Tests for the DB Operator packages: the webhook check that every
# kinda.rocks custom resource waits for, the webhook entries and their
# order, the refusals of db-operator, db-operator-instance, and
# db-operator-database, each beside a positive control, the replica counts,
# the alert rules and what they are gated on, the DbInstance the instance
# renders and the network policy it yields for a server in the cluster and
# outside it, the Postgres database contract the database publishes, a
# Metabase that runs on it, and two instances in two namespaces.

{
  lib,
  eval,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  multiZone,
  singleNode,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  operatorPackage = import ../../../packages/experimental/db-operator;
  instancePackage = import ../../../packages/experimental/db-operator-instance;
  databasePackage = import ../../../packages/experimental/db-operator-database;
  certManagerPackage = import ../../../packages/experimental/cert-manager;
  ciliumPackage = import ../../../packages/experimental/cilium;
  secretPackage = import ../../../packages/stable/secret;
  serviceRefPackage = import ../../../packages/experimental/service-ref;
  metabasePackage = import ../../../packages/experimental/metabase;
  pvcPackage = import ../../../packages/stable/persistent-volume-claim;
  valkeyPackage = import ../../../packages/stable/valkey;

  # A package's failed assertion messages for `config`, evaluated against
  # its options.
  failedMessages =
    {
      package,
      instanceName,
      namespaceName ? "apps",
      config ? { },
    }:
    let
      attrs = eval.callPackagePhase1 {
        inherit package;
        scope = { inherit instanceName namespaceName; };
      };
      evaluated = eval.evaluateInstanceConfig {
        packageOptions = attrs.options;
        instCfg.config.imports = [ config ];
        inherit namespaceName instanceName;
      };
    in
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        attrs.assertions {
          config = evaluated;
          deps = { };
        }
      )
    );
  says = fragment: messages: builtins.any (m: lib.hasInfix fragment m) messages;

  # A consumer that reads the database's `out` into its environment and
  # holds it to the Postgres database contract.
  consumerPackage =
    { scope, kix, ... }:
    {
      meta = {
        description = "PostgreSQL consumer stand-in";
        owner = "app-team";
      };
      deps.database.assertions = dep: kix.contracts.postgresDatabase.assertions "consumer" dep;
      build =
        { self, database, ... }:
        {
          deployment = scope.mkDeployment {
            name = "consumer";
            availability.max = "none";
            spec = {
              replicas = 1;
              selector.matchLabels = scope.selectorLabels;
              template.spec.containers = [
                {
                  name = "consumer";
                  image = "example.com/consumer:1";
                  env = kix.mkEnvVars {
                    PGHOST = database.out.host;
                    PGPORT = database.out.port;
                    PGDATABASE = database.out.database;
                    PGUSER = database.out.credentials.out.keyRef "username";
                    PGPASSWORD = database.out.credentials.out.keyRef "password";
                  };
                }
              ];
            };
          };
          root = self.deployment;
        };
    };

  # A PostgreSQL server Kix does not run, in `data`.
  serverRef = {
    package = serviceRefPackage;
    config = {
      name = "pg";
      selector."app.kubernetes.io/name" = "pg";
      ports = [ { port = 5432; } ];
    };
  };
  adminCredentials = {
    package = secretPackage;
    config.stringData = {
      username = "postgres";
      password = "password";
    };
  };

  # The operator, cert-manager, a server `pg` and its admin login in
  # `data`, the DbInstance `pg-instance` on them, and, with `database`, a
  # database `app-db` in `apps` and a consumer of it. `server` replaces
  # the server. `modules` are added to the cluster.
  dbOperator =
    {
      operatorConfig ? { },
      instanceConfig ? { },
      databaseConfig ? { },
      server ? serverRef,
      database ? true,
      consumer ? database,
      modules ? [ ],
    }:
    mkCluster (
      [
        (
          { ref, ... }:
          {
            instances.cert-manager.cert-manager.package = certManagerPackage;
            instances.db-operator.db-operator = {
              package = operatorPackage;
              config = operatorConfig;
            };
            instances.data = {
              pg = server;
              pg-admin = adminCredentials;
              pg-instance = {
                package = instancePackage;
                deps = {
                  postgres = ref.data.pg;
                  adminCredentials = ref.data.pg-admin;
                };
                config = instanceConfig;
              };
            };
            instances.apps =
              lib.optionalAttrs database {
                app-db = {
                  package = databasePackage;
                  deps.dbInstance = ref.data.pg-instance;
                  config = databaseConfig;
                };
              }
              // lib.optionalAttrs consumer {
                consumer = {
                  package = consumerPackage;
                  deps.database = ref.apps.app-db;
                };
              };
          }
        )
      ]
      ++ modules
    );
  ms = cluster: manifests cluster;
  dependsOn = m: m.metadata.annotations.${kixKeys.dependsOn} or "";
  withPrometheus.instances.monitoring.prometheus.package = prometheusStub;

  # Cilium as the enforcer, as the environment's CNI.
  cilium = {
    cluster.roles.cni = {
      binding = "shadowable";
      provider = "cilium (environment)";
    };
    networkPolicy.enable = true;
    instances.net.cilium.package = ciliumPackage;
    instances.net.platform-cilium.package = eval.mkImport {
      roles = [ "cni" ];
      out.helmChartConfig = null;
    };
  };
  policy = all: name: (byName name (ofKind "CiliumNetworkPolicy" all));
  portsOf = rule: map (p: p.port) (builtins.head rule.toPorts).ports;

  # A server outside the cluster, as an import.
  externalServer = external: {
    package = eval.mkImport {
      out = {
        fqdn = "db.example.com";
        port = "6432";
        tls = true;
        inherit external;
      };
    };
  };

  hashOf = part: builtins.unsafeDiscardStringContext part.out.identityHash;
in
{
  # Every kinda.rocks custom resource waits for the webhook check, and the
  # check is a server-side dry-run create of a Database.
  db-operator-crd-handles-gated =
    let
      cluster = dbOperator { };
      all = ms cluster;
      operator = cluster.instances.db-operator.db-operator;
      jobHash = hashOf operator.raw.webhookCheck;
      customResources = builtins.filter (m: lib.hasPrefix "kinda.rocks/" m.apiVersion) all;
      ungated = map (m: "${m.kind}/${m.metadata.name}") (
        builtins.filter (m: !(lib.hasInfix jobHash (dependsOn m))) customResources
      );
      container = builtins.head (byName "db-operator-webhook-check" (ofKind "Job" all))
        .spec.template.spec.containers;
    in
    (
      ungated == [ ]
      &&
        lib.sort lib.lessThan (map (m: m.kind) customResources) == [
          "Database"
          "DbInstance"
        ]
      &&
        container.args == [
          "create"
          "--dry-run=server"
          "--output=name"
          "--filename=/check/database.json"
        ]
      && operator.out.crds.DbUser.out ? mkCR
    )
    || throw "webhook-check gate: ${
      builtins.toJSON {
        inherit ungated;
        inherit (container) args;
      }
    }";

  # The webhook entries are upstream's, call the package's Service, leave
  # caBundle to cainjector, and wait for the webhook Deployment. The
  # Certificate is issued for the name the API server calls.
  db-operator-webhooks =
    let
      cluster = dbOperator { database = false; };
      all = ms cluster;
      operator = cluster.instances.db-operator.db-operator;
      config = kind: byName "db-operator-db-operator" (ofKind kind all);
      entries = kind: (config kind).webhooks;
      inject = kind: (config kind).metadata.annotations."cert-manager.io/inject-ca-from";
      mutating = entries "MutatingWebhookConfiguration";
      validating = entries "ValidatingWebhookConfiguration";
      both = mutating ++ validating;
      certificate = byName "db-operator-webhook" (ofKind "Certificate" all);
      webhookHash = hashOf operator.raw.webhookDeployment;
    in
    (
      map (w: w.name) mutating == [
        "mdatabase-v1beta1.kb.io"
        "mdbinstance-v1.kb.io"
        "mdbinstance-v1beta1.kb.io"
      ]
      &&
        map (w: w.name) validating == [
          "vdatabase-v1beta1.kb.io"
          "vdbinstance-v1.kb.io"
          "vdbinstance-v1beta1.kb.io"
          "vdbuser-v1beta1.kb.io"
        ]
      && (builtins.head mutating).clientConfig.service.path == "/mutate-kinda-rocks-v1beta1-database"
      && (lib.last validating).clientConfig.service.path == "/validate-kinda-rocks-v1beta1-dbuser"
      && builtins.all (
        w:
        w.clientConfig.service.name == "db-operator-webhook"
        && w.failurePolicy == "Fail"
        && !(w.clientConfig ? caBundle)
      ) both
      && inject "MutatingWebhookConfiguration" == "db-operator/db-operator-webhook"
      && inject "ValidatingWebhookConfiguration" == "db-operator/db-operator-webhook"
      && lib.hasInfix webhookHash (dependsOn (config "MutatingWebhookConfiguration"))
      && lib.hasInfix webhookHash (dependsOn (config "ValidatingWebhookConfiguration"))
      && certificate.spec.dnsNames == [ "db-operator-webhook.db-operator.svc" ]
    )
    || throw "webhooks: ${
      builtins.toJSON {
        inherit both;
        inherit (certificate) spec;
      }
    }";

  # The controller runs leader-elected with its config file mounted, the
  # webhook server serves the Certificate's Secret, and only the controller
  # is bound to a role.
  db-operator-workloads =
    let
      all = ms (dbOperator {
        database = false;
        operatorConfig.settings.serverVersionTTL = "30m";
      });
      deployment = name: byName name (ofKind "Deployment" all);
      container = name: builtins.head (deployment name).spec.template.spec.containers;
      envOf =
        name:
        builtins.listToAttrs (map (e: lib.nameValuePair e.name (e.value or null)) (container name).env);
      controller = envOf "db-operator-controller";
      webhook = envOf "db-operator-webhook";
      configMap = byName "db-operator-config" (ofKind "ConfigMap" all);
      bindings = map (b: b.subjects) (ofKind "ClusterRoleBinding" all ++ ofKind "RoleBinding" all);
      subjects = map (s: s.name) (lib.flatten bindings);
    in
    (
      (container "db-operator-controller").args == [ "controller" ]
      && (container "db-operator-webhook").args == [ "webhook" ]
      && controller.DBO_ENABLE_LEADER_ELECTION == "true"
      && controller.DBO_CONFIG == "/run/config/config.yaml"
      && controller.DBO_METRICS_ADDR == ":60000"
      && webhook.DBO_PROBE_ADDR == ":8081"
      && !(webhook ? DBO_ENABLE_LEADER_ELECTION)
      &&
        builtins.fromJSON configMap.data."config.yaml" == {
          databaseAwareness = true;
          serverVersionTTL = "30m";
        }
      &&
        (deployment "db-operator-webhook").spec.template.spec.volumes == [
          {
            name = "webhook-certificates";
            secret.secretName = "db-operator-webhook-tls";
          }
        ]
      && builtins.elem "db-operator-controller" subjects
      && !(builtins.elem "db-operator-webhook" subjects)
    )
    || throw "workloads: ${builtins.toJSON { inherit controller webhook subjects; }}";

  # One replica of each on a single node (availability none); two of each
  # at zone.
  db-operator-replicas =
    let
      replicas =
        modules:
        map
          (
            n:
            (byName n (
              ofKind "Deployment" (
                ms (dbOperator {
                  database = false;
                  inherit modules;
                })
              )
            )).spec.replicas
          )
          [
            "db-operator-controller"
            "db-operator-webhook"
          ];
      none = replicas [ singleNode ];
      zone = replicas [ (lib.recursiveUpdate multiZone { cluster.availability.default = "zone"; }) ];
    in
    (
      none == [
        1
        1
      ]
      &&
        zone == [
          2
          2
        ]
    )
    || throw "replicas: ${builtins.toJSON { inherit none zone; }}";

  # An operator image of another minor than the vendored definitions is
  # refused; another patch of the release minor is not.
  db-operator-image-minor =
    let
      got = failedMessages {
        package = operatorPackage;
        instanceName = "db-operator";
        config.image.tag = "2.46.0";
      };
      fine = failedMessages {
        package = operatorPackage;
        instanceName = "db-operator";
        config.image.tag = "2.47.3";
      };
    in
    (says ''image.tag "2.46.0" is not a 2.47 release'' got && fine == [ ])
    || throw "db-operator image refusal: ${builtins.toJSON { inherit got fine; }}";

  # Variables the package owns or refuses fail the build; another variable
  # passes.
  db-operator-env-refusals =
    let
      withEnv =
        env:
        dbOperator {
          database = false;
          operatorConfig = { inherit env; };
        };
      withWebhookEnv =
        env:
        dbOperator {
          database = false;
          operatorConfig.webhook = { inherit env; };
        };
    in
    (
      evalFails (withEnv {
        DBO_WATCH_NAMESPACES = "apps";
      })
      && evalFails (withEnv {
        DBO_ENABLE_LEADER_ELECTION = "false";
      })
      && evalFails (withEnv {
        DBO_CONFIG = "/tmp/config.yaml";
      })
      && evalFails (withEnv {
        DBO_METRICS_ADDR = ":8080";
      })
      && evalFails (withWebhookEnv {
        DBO_ENABLE_LEADER_ELECTION = "true";
      })
      && evalFails (withWebhookEnv {
        DBO_PROBE_ADDR = ":9090";
      })
      && !evalFails (withEnv {
        DBO_RECONCILE_INTERVAL = "60s";
      })
      && !evalFails (withWebhookEnv {
        DBO_LOG_LEVEL = "debug";
      })
    )
    || throw "db-operator env refusals: one did not fail, or a control failed";

  # The vendored definitions and roles come from the package's release.
  db-operator-sources-match-release =
    let
      urls =
        file:
        builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
          map (l: builtins.head (lib.splitString " " (lib.trim l))) (
            lib.splitString "\n" (builtins.readFile file)
          )
        );
      release =
        (operatorPackage {
          scope = {
            instanceName = "db-operator";
            namespaceName = "db-operator";
          };
          inherit lib;
          kix = kixlib;
          availability = "none";
        }).meta.version;
      dir = ../../../packages/experimental/db-operator;
      stray = builtins.filter (u: !(lib.hasInfix "/${release}/" u)) (
        urls (dir + "/crds/sources.txt") ++ urls (dir + "/rbac/sources.txt")
      );
    in
    stray == [ ] || throw "sources.txt URLs not at ${release}: ${builtins.toJSON stray}";

  # The rules select the metrics Service and need a prometheus dependency
  # and metrics.enabled.
  db-operator-alerts =
    let
      rulesOf =
        {
          operatorConfig ? { },
          modules ? [ withPrometheus ],
        }:
        alertRulesOf "PrometheusRule" "db-operator" (
          ms (dbOperator {
            database = false;
            inherit operatorConfig modules;
          })
        );
      on = rulesOf { operatorConfig.metrics.enabled = true; };
      sel = ''namespace="db-operator",service="db-operator-metrics"'';
    in
    (
      allSelect sel on
      &&
        builtins.attrNames on == [
          "DbOperatorDatabaseFailing"
          "DbOperatorDown"
          "DbOperatorReconcileErrors"
        ]
      &&
        rulesOf {
          operatorConfig.metrics.enabled = true;
          modules = [ ];
        } == null
      && rulesOf { operatorConfig.metrics.enabled = false; } == null
    )
    || throw "db-operator alerts: ${
      builtins.toJSON (if on == null then null else builtins.attrNames on)
    }";

  # The DbInstance names the admin Secret in the instance's namespace, the
  # server's address and port, and TLS from the server's out.tls.
  # extraSpec may add a field but not replace one the package sets.
  db-operator-instance-spec =
    let
      specOf =
        args:
        (byName "pg-instance" (ofKind "DbInstance" (ms (dbOperator ({ database = false; } // args))))).spec;
      plain = specOf { instanceConfig.extraSpec.namespaceFilters = [ "^apps$" ]; };
      tls = specOf { server = externalServer false; };
      keys = specOf {
        instanceConfig.auth = {
          usernameKey = "user";
          passwordKey = "pass";
        };
        server = serverRef;
        modules = [
          {
            instances.data.pg-admin = lib.mkForce {
              package = secretPackage;
              config.stringData = {
                user = "postgres";
                pass = "password";
              };
            };
          }
        ];
      };
      withSpec =
        extraSpec:
        dbOperator {
          database = false;
          instanceConfig = { inherit extraSpec; };
        };
    in
    (
      plain.engine == "postgres"
      &&
        plain.auth.password.valueFrom.secret == {
          namespace = "data";
          name = "pg-admin";
          key = "password";
        }
      && lib.hasPrefix "pg.data.svc." plain.endpoint.host.value
      && plain.endpoint.port.value == "5432"
      &&
        plain.endpoint.sslConnection == {
          enabled = false;
          skip-verify = false;
        }
      && plain.namespaceFilters == [ "^apps$" ]
      && tls.endpoint.host.value == "db.example.com"
      && tls.endpoint.port.value == "6432"
      &&
        tls.endpoint.sslConnection == {
          enabled = true;
          skip-verify = true;
        }
      && keys.auth.username.valueFrom.secret.key == "user"
      && evalFails (withSpec {
        endpoint.host.value = "other";
      })
      && evalFails (withSpec {
        auth.password.value = "secret";
      })
      && evalFails (withSpec {
        engine = "mysql";
      })
      && !evalFails (withSpec {
        endpoint.sslConnection.skip-verify = false;
      })
    )
    || throw "DbInstance spec: ${builtins.toJSON { inherit plain tls keys; }}";

  # Refusals of db-operator-instance at build time, each beside a control.
  db-operator-instance-refusals =
    let
      control = dbOperator { database = false; };
      noFqdn = dbOperator {
        database = false;
        server.package = eval.mkImport { out.port = "5432"; };
      };
      badPort = dbOperator {
        database = false;
        server.package = eval.mkImport {
          out = {
            fqdn = "db.example.com";
            port = "postgres";
            external = true;
          };
        };
      };
      badExternal = dbOperator {
        database = false;
        server = externalServer "yes";
      };
      missingKey = dbOperator {
        database = false;
        modules = [
          {
            instances.data.pg-admin = lib.mkForce {
              package = secretPackage;
              config.stringData.password = "password";
            };
          }
        ];
      };
    in
    (
      !evalFails control
      && evalFails noFqdn
      && evalFails badPort
      && evalFails badExternal
      && evalFails missingKey
    )
    || throw "db-operator-instance refusals: ${
      builtins.toJSON {
        control = evalFails control;
        noFqdn = evalFails noFqdn;
        badPort = evalFails badPort;
        badExternal = evalFails badExternal;
        missingKey = evalFails missingKey;
      }
    }";

  # Under an enforcer, a server in the cluster gets the controller's egress
  # in the operator's namespace and its ingress in the server's namespace,
  # from the DbInstance's factBehavior. A consumer of the database gets
  # egress to the server too.
  db-operator-instance-network-policy =
    let
      all = ms (dbOperator {
        modules = [ cilium ];
      });
      egress = (policy all "data-pg-instance-dbinstance-pg-instance-egress").spec;
      ingress = (policy all "data-pg-instance-dbinstance-pg-instance-to-pg-ingress").spec;
      consumerEgress = (policy all "consumer-deployment-consumer-egress").spec.egress;
      controllerSelector = {
        "app.kubernetes.io/component" = "controller";
        "app.kubernetes.io/instance" = "db-operator";
        "app.kubernetes.io/name" = "db-operator";
      };
      webhookIngress = (policy all "db-operator-deployment-db-operator-webhook-ingress").spec.ingress;
      webhookApi = policy all "db-operator-deployment-db-operator-webhook-apiserver-egress";
    in
    (
      (policy all "data-pg-instance-dbinstance-pg-instance-egress").metadata.namespace == "db-operator"
      && egress.endpointSelector.matchLabels == controllerSelector
      && builtins.any (r: r ? toPorts && portsOf r == [ "5432" ]) egress.egress
      && (policy all "data-pg-instance-dbinstance-pg-instance-to-pg-ingress").metadata.namespace == "data"
      &&
        (builtins.head ingress.ingress).fromEndpoints == [
          {
            matchLabels = controllerSelector // {
              "k8s:io.kubernetes.pod.namespace" = "db-operator";
            };
          }
        ]
      && builtins.any (r: r ? toPorts && portsOf r == [ "5432" ]) consumerEgress
      && map portsOf webhookIngress == [ [ "9443" ] ]
      && webhookApi == null
    )
    || throw "network policy: ${builtins.toJSON { inherit egress ingress consumerEgress; }}";

  # A server with out.external = true gets a policy in the operator's
  # namespace that lets the controller reach any address on its port, and
  # the DbInstance waits for it. Without the flag there is none.
  db-operator-instance-external =
    let
      cluster =
        external:
        dbOperator {
          database = false;
          server = externalServer external;
          modules = [ cilium ];
        };
      all = ms (cluster true);
      egress = policy all "pg-instance-db-operator-egress";
      dbInstance = byName "pg-instance" (ofKind "DbInstance" all);
      egressHash = hashOf (cluster true).instances.data.pg-instance.raw.operatorEgress;
      worldPorts = map portsOf (builtins.filter (r: r ? toEntities) egress.spec.egress);
    in
    (
      egress.metadata.namespace == "db-operator"
      && egress.spec.endpointSelector.matchLabels."app.kubernetes.io/component" == "controller"
      && worldPorts == [ [ "6432" ] ]
      && lib.hasInfix egressHash (dependsOn dbInstance)
      && policy (ms (cluster false)) "pg-instance-db-operator-egress" == null
    )
    || throw "external server: ${builtins.toJSON egress}";

  # The database answers the Postgres database contract. Its Secret
  # reference declares the operator's keys, the contract's, and the
  # templates', and the consumer reads it by name and waits for it.
  db-operator-database-out =
    let
      cluster = dbOperator {
        databaseConfig = {
          extensions = [
            "citext"
            { name = "citext"; }
          ];
          templates.DATABASE_URL = "postgresql://{{ .Username }}@{{ .Hostname }}";
        };
      };
      all = ms cluster;
      out = cluster.instances.apps.app-db.out;
      database = byName "app-db" (ofKind "Database" all);
      deployment = byName "consumer" (ofKind "Deployment" all);
      env = builtins.listToAttrs (
        map (e: lib.nameValuePair e.name e) (builtins.head deployment.spec.template.spec.containers).env
      );
      templates = map (t: t.name) database.spec.credentials.templates;
      # A Secret reference's out.name carries the reference's identity
      # path, whose store hash depends-on lists.
      refHash = builtins.substring 11 32 (
        builtins.head (
          builtins.attrNames (builtins.getContext cluster.instances.apps.app-db.raw.credentials.out.name)
        )
      );
      instanceHash = hashOf cluster.instances.data.pg-instance.raw.dbInstance;
    in
    (
      lib.hasPrefix "pg.data.svc." out.host
      && out.port == "5432"
      && out.database == "apps-app-db"
      && out.username == "apps-app-db"
      && out.extensions == [ "citext" ]
      && out.tls == null
      &&
        out.credentials.out.keys == [
          "POSTGRES_DB"
          "POSTGRES_USER"
          "POSTGRES_PASSWORD"
          "password"
          "username"
          "DATABASE_URL"
        ]
      && database.spec.instance == "pg-instance"
      && database.spec.secretName == "app-db-credentials"
      && database.spec.deletionProtected
      && database.spec.postgres.extensions == [ "citext" ]
      &&
        templates == [
          "DATABASE_URL"
          "password"
          "username"
        ]
      &&
        env.PGUSER.valueFrom.secretKeyRef == {
          name = "app-db-credentials";
          key = "username";
        }
      && env.PGDATABASE.value == "apps-app-db"
      && lib.hasInfix refHash (dependsOn deployment)
      && lib.hasInfix instanceHash (dependsOn database)
    )
    || throw "database out: ${
      builtins.toJSON {
        inherit out templates env;
        spec = database.spec;
      }
    }";

  # db-operator-database's assertions, one message each, and none for a
  # config with a template, extensions by name, and a short name.
  db-operator-database-refusals =
    let
      messages =
        args:
        failedMessages (
          {
            package = databasePackage;
            instanceName = "app-db";
          }
          // args
        );
      long = messages { instanceName = lib.concatStrings (lib.replicate 60 "a"); };
      taken = messages { config.templates.POSTGRES_PASSWORD = "{{ .Password }}"; };
      contract = messages { config.templates.username = "{{ .Username }}"; };
      field = messages { config.templates.PGPASS = "{{ .Hostname }}:{{.Port}}:*:{{ .User }}"; };
      pinned = messages {
        config.extensions = [
          {
            name = "vector";
            version = "0.8.0";
          }
        ];
      };
      fine = messages {
        config = {
          templates = {
            DATABASE_URL = "postgresql://{{ .Username }}@{{ .Hostname }}";
            READ_URL = ''{{ .InstanceVar "READ_HOST" }}/{{ .Database }}'';
          };
          extensions = [
            "citext"
            { name = "pgcrypto"; }
          ];
        };
      };
    in
    (
      says "is 65 bytes long" long
      && says "templates uses reserved Secret keys (POSTGRES_PASSWORD)" taken
      && says "templates uses reserved Secret keys (username)" contract
      && says "PGPASS uses .User)" field
      && !(says "uses .Port" field)
      && says "extensions pins a version for vector" pinned
      && fine == [ ]
    )
    || throw "db-operator-database refusals: ${
      builtins.toJSON {
        inherit
          long
          taken
          contract
          pinned
          fine
          ;
      }
    }";

  # extraSpec cannot set a path the package owns; another path passes. A
  # dependency that is not a db-operator-instance is refused.
  db-operator-database-extra-spec-locks =
    let
      withSpec = extraSpec: dbOperator { databaseConfig = { inherit extraSpec; }; };
      notInstance = mkCluster [
        (
          { ref, ... }:
          {
            instances.cert-manager.cert-manager.package = certManagerPackage;
            instances.db-operator.db-operator.package = operatorPackage;
            instances.apps.app-db = {
              package = databasePackage;
              deps.dbInstance = ref.apps.pg;
            };
            instances.apps.pg = serverRef;
          }
        )
      ];
    in
    (
      evalFails (withSpec {
        instance = "other";
      })
      && evalFails (withSpec {
        secretName = "other";
      })
      && evalFails (withSpec {
        existingUser = "app";
      })
      && evalFails (withSpec {
        credentials.templates = [ ];
      })
      && evalFails (withSpec {
        postgres.extensions = [ "vector" ];
      })
      && !evalFails (withSpec {
        postgres.schemas = [ "app" ];
      })
      && !evalFails (withSpec {
        deletionProtected = false;
      })
      && evalFails notInstance
    )
    || throw "db-operator-database extraSpec locks: ${
      builtins.toJSON {
        instance = evalFails (withSpec {
          instance = "other";
        });
        secretName = evalFails (withSpec {
          secretName = "other";
        });
        existingUser = evalFails (withSpec {
          existingUser = "app";
        });
        templates = evalFails (withSpec {
          credentials.templates = [ ];
        });
        extensions = evalFails (withSpec {
          postgres.extensions = [ "vector" ];
        });
        schemas = evalFails (withSpec {
          postgres.schemas = [ "app" ];
        });
        protected = evalFails (withSpec {
          deletionProtected = false;
        });
        notInstance = evalFails notInstance;
      }
    }";

  # Metabase, a consumer written for stackgres-database and cnpg-database,
  # evaluates on a db-operator-database, and its citext request reaches the
  # Database.
  db-operator-database-metabase =
    let
      cluster = dbOperator {
        consumer = false;
        modules = [
          (
            { ref, ... }:
            {
              instances.apps = {
                metabase = {
                  package = metabasePackage;
                  deps.database = ref.apps.app-db;
                };
                metabase-key = {
                  package = secretPackage;
                  aliases = [ "encryptionKey" ];
                  config.stringData.key = "0123456789abcdef0123456789abcdef";
                };
              };
            }
          )
        ];
      };
      all = ms cluster;
      database = byName "app-db" (ofKind "Database" all);
    in
    (
      byName "metabase" (ofKind "Deployment" all) != null
      && database.spec.postgres.extensions == [ "citext" ]
    )
    || throw "metabase on db-operator-database: ${builtins.toJSON database.spec}";

  # The packages that take a `database` dependency, each on a
  # db-operator-database. Immich injects a pinned vchord version, which
  # this provider cannot create, so its build fails; the others evaluate.
  db-operator-database-consumers =
    let
      secret = alias: stringData: {
        package = secretPackage;
        aliases = [ alias ];
        config = { inherit stringData; };
      };
      storage = {
        package = pvcPackage;
        config.size = "1Gi";
      };
      valkeyPassword = secret "valkeyPassword" { password = "password"; };
      consumers = {
        keycloak = {
          package = import ../../../packages/experimental/keycloak;
          config.env.KC_HOSTNAME = "https://auth.example.com";
          extra.bootstrap-admin = secret "bootstrapAdmin" {
            username = "admin";
            password = "password";
          };
        };
        vaultwarden = {
          package = import ../../../packages/experimental/vaultwarden;
          config.domain = "https://vault.example.com";
          extra = { inherit storage; };
        };
        n8n = {
          package = import ../../../packages/experimental/n8n;
          extra = {
            valkey-password = valkeyPassword;
            valkey.package = valkeyPackage;
            n8n-encryption-key = secret "encryptionKey" { key = "0123456789abcdef0123456789abcdef"; };
          };
        };
        harbor = {
          package = import ../../../packages/stable/harbor;
          config.externalURL = "https://harbor.example.com";
          extra = {
            inherit storage;
            valkey-password = valkeyPassword;
            valkey.package = valkeyPackage;
            harbor-secrets = secret "harborSecrets" {
              adminPassword = "admin";
              secretKey = "0123456789abcdef";
              coreSecret = "core";
              jobserviceSecret = "jobservice";
              csrfKey = "0123456789abcdef0123456789abcdef";
              registryHttpSecret = "registry-http";
              registryPassword = "registry";
              tokenPrivateKey = "key";
            };
          };
        };
        immich = {
          package = import ../../../packages/experimental/immich;
          extra = {
            inherit storage;
            valkey-password = valkeyPassword;
            valkey.package = valkeyPackage;
          };
        };
      };
      clusterOf =
        name:
        let
          c = consumers.${name};
        in
        dbOperator {
          consumer = false;
          # A server that serves TLS, which harbor needs to know.
          server = externalServer false;
          modules = [
            {
              instances.kube-system.platform-storage.package = eval.mkImport {
                kind = "StorageClass";
                apiVersion = "storage.k8s.io/v1";
                roles = [ "storageClasses" ];
                out = {
                  name = "standard";
                  storageClassName = "standard";
                };
              };
            }
            (
              { ref, ... }:
              {
                instances.apps = {
                  ${name} = {
                    inherit (c) package;
                    config = c.config or { };
                    deps.database = ref.apps.app-db;
                  };
                }
                // (c.extra or { });
              }
            )
          ];
        };
      fails = name: evalFails (clusterOf name);
      results = lib.mapAttrs (name: _: fails name) consumers;
    in
    results == {
      keycloak = false;
      vaultwarden = false;
      n8n = false;
      harbor = false;
      immich = true;
    }
    || throw "consumers on db-operator-database (true = fails): ${builtins.toJSON results}";

  # Two databases of one name in two namespaces do not collide. Two
  # DbInstances of one name do, because a DbInstance is cluster-scoped.
  db-operator-two-namespaces =
    let
      second = dbOperator {
        modules = [
          (
            { ref, ... }:
            {
              instances.shop.app-db = {
                package = databasePackage;
                deps.dbInstance = ref.data.pg-instance;
              };
            }
          )
        ];
      };
      databases = map (m: "${m.metadata.namespace}/${m.metadata.name}") (ofKind "Database" (ms second));
      twoInstances = dbOperator {
        database = false;
        modules = [
          (
            { ref, ... }:
            {
              instances.other = {
                pg = serverRef;
                pg-admin = adminCredentials;
                pg-instance = {
                  package = instancePackage;
                  deps = {
                    postgres = ref.other.pg;
                    adminCredentials = ref.other.pg-admin;
                  };
                };
              };
            }
          )
        ];
      };
    in
    (
      lib.sort lib.lessThan databases == [
        "apps/app-db"
        "shop/app-db"
      ]
      && second.instances.shop.app-db.out.database == "shop-app-db"
      && evalFails twoInstances
    )
    || throw "two namespaces: ${builtins.toJSON databases}";
}
