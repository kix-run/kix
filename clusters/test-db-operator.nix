# clusters/test-db-operator.nix: the DB Operator packages under Cilium
# default-deny, with every option the packages read turned on.
#
# db-operator runs in db-operator with metrics (a ServiceMonitor through
# prometheus-operator), a `settings` entry, and an extra variable for each
# workload, and cert-manager issues its webhook certificate. In `data`,
# `pg` is a one-instance cnpg-cluster with `enableSuperuserAccess`, so
# CloudNativePG writes the Secret `pg-superuser`, which the secret-ref
# `pg-superuser` names. `pg-instance` is a db-operator-instance on `pg`
# that signs in with that login, limited to the namespace `apps` by the
# anchored filter `extraSpec.namespaceFilters = [ "^apps$" ]`. In `apps`, `app-db` is a
# db-operator-database on it with an extension, an extra Secret key from a
# template, and an extraSpec schema. `psql-check` stands in for an
# application: it reads `app-db` through `deps.database` and
# `kix.contracts.postgresDatabase`, which under default deny gives it
# egress to the PostgreSQL pods on TCP 5432, and runs `select 1` as the
# generated role every ten seconds.
#
# A server outside the cluster (`out.external = true`) is not deployed
# here, because its DbInstance would never become ready on kind. The unit
# tests in kix/lib/tests/units/db-operator.nix cover its policy.
#
# What a deploy should show beyond ready objects: the webhook check Job
# completes under default deny (the API server reaches the webhook pods on
# TCP 9443); `pg-instance` reports `status.ready` (the controller reached
# `pg` on TCP 5432 and signed in); the Secret `apps/app-db-credentials`
# holds POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, username, password,
# and DATABASE_URL; and `psql-check` logs one row a loop:
#   kubectl -n apps logs deploy/psql-check
#
# Build:  kix build db-operator
# Deploy: kix deploy db-operator --context <kind context>
#         on a kind cluster created with `disableDefaultCNI: true`.

{ kix, packages }:

let
  # A stand-in PostgreSQL client: psql runs `select 1` as the database's
  # role every ten seconds, and exits when it fails, so the pod restarts.
  psqlCheckPackage =
    { scope, kix, ... }:
    {
      meta = {
        description = "psql loop as a stand-in PostgreSQL consumer";
        owner = "app-team";
      };
      # The consumer holds the database to the contract every PostgreSQL
      # database provider answers.
      deps.database.assertions = dep: kix.contracts.postgresDatabase.assertions "psql-check" dep;
      build =
        {
          self,
          database,
          ...
        }:
        let
          labels = scope.selectorLabels;
          # psql reads the libpq variables. The server serves TLS, so the
          # client asks for it without checking the certificate.
          env = kix.mkEnvVars {
            PGHOST = database.out.host;
            PGPORT = database.out.port;
            PGDATABASE = database.out.database;
            PGSSLMODE = if database.out.tls or null == true then "require" else "prefer";
            PGUSER = database.out.credentials.out.keyRef "username";
            PGPASSWORD = database.out.credentials.out.keyRef "password";
          };
        in
        {
          deployment = scope.mkDeployment {
            name = scope.instanceName;
            availability.max = "none";
            spec = {
              replicas = 1;
              selector.matchLabels = labels;
              template = {
                metadata.labels = labels;
                spec = {
                  # The Kubernetes default; the loop needs no longer to stop.
                  terminationGracePeriodSeconds = 30;
                  securityContext = {
                    runAsNonRoot = true;
                    # The `postgres` user of the official Alpine images.
                    runAsUser = 70;
                    runAsGroup = 70;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    {
                      name = "psql";
                      image = "docker.io/library/postgres:18.6-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873";
                      inherit env;
                      command = [
                        "sh"
                        "-c"
                        "while psql -Atc 'select 1'; do sleep 10; done"
                      ];
                      readinessProbe = {
                        exec.command = [
                          "psql"
                          "-Atc"
                          "select 1"
                        ];
                        periodSeconds = 10;
                      };
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits = {
                          cpu = "100m";
                          memory = "64Mi";
                        };
                      };
                      securityContext = {
                        allowPrivilegeEscalation = false;
                        capabilities.drop = [ "ALL" ];
                        readOnlyRootFilesystem = true;
                      };
                    }
                  ];
                };
              };
            };
          };
          root = self.deployment;
        };
    };
in
kix.buildCluster {
  name = "test-db-operator";
  modules = [
    kix.flavors.kind
    (
      { ref, ... }:
      {
        networkPolicy.enable = true;

        # kind runs with the default CNI disabled, so the managed cilium
        # instance fills the cni role.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        instances.kube-system.cilium.package = packages.experimental.cilium;
        instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;
        instances.cert-manager.cert-manager.package = packages.experimental.cert-manager;
        instances.cnpg-system.cnpg-operator.package = packages.cnpg-operator;

        # region:dbOperatorInstance
        instances.db-operator.db-operator = {
          package = packages.experimental.db-operator;
          config = {
            metrics.enabled = true;
            settings.serverVersionTTL = "30m";
            env.DBO_RECONCILE_INTERVAL = "30s";
            webhook.env.DBO_LOG_LEVEL = "info";
          };
        };
        # endregion:dbOperatorInstance

        instances.data = {
          pg = {
            package = packages.cnpg-cluster;
            config = {
              storage.size = "1Gi";
              # CloudNativePG writes the superuser's login into the Secret
              # pg-superuser.
              extraSpec.enableSuperuserAccess = true;
            };
          };
          # region:dbOperatorServer
          pg-superuser = {
            package = packages.secret-ref;
            config = {
              type = "kubernetes.io/basic-auth";
              keys = [
                "username"
                "password"
              ];
            };
          };
          pg-instance = {
            package = packages.experimental.db-operator-instance;
            deps = {
              postgres = ref.data.pg;
              adminCredentials = ref.data.pg-superuser;
            };
            # A Go regular expression, matched anywhere in the namespace name.
            config.extraSpec.namespaceFilters = [ "^apps$" ];
          };
          # endregion:dbOperatorServer
        };

        instances.apps = {
          # region:dbOperatorDatabase
          app-db = {
            package = packages.experimental.db-operator-database;
            deps.dbInstance = ref.data.pg-instance;
            config = {
              extensions = [ "citext" ];
              templates.DATABASE_URL = "postgresql://{{ .Username }}:{{ .Password }}@{{ .Hostname }}:{{ .Port }}/{{ .Database }}";
              extraSpec.postgres.schemas = [ "app" ];
            };
          };
          # endregion:dbOperatorDatabase
          psql-check = {
            package = psqlCheckPackage;
            deps.database = ref.apps.app-db;
          };
        };
      }
    )
  ];
}
