# Tests for the SMTP contract (kix/lib/vocab/smtp.nix), the `ref` an
# import's `out` can carry (kix/lib/eval/import.nix), and their consumers:
# vaultwarden and grafana mail, and vaultwarden on an outside PostgreSQL
# such as RDS. Plausible's mail is tested in units/plausible.nix.
#
# Without a login, the SMTP server is one kix.mkImport in namespace `mail`
# that serves the cluster. With a login, the import sits in the consumer's
# namespace and names the secret with `ref`. tryEval drops a throw's
# message, so each evalFails sits beside a cluster that evaluates.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  netpolOn,
  storageClassImport,
  kixKeys,
  ...
}:

let
  contract = kixlib.contracts.smtp;
  secretPackage = import ../../../packages/stable/secret;
  pvcPackage = import ../../../packages/stable/persistent-volume-claim;
  vaultwardenPackage = import ../../../packages/stable/vaultwarden;
  grafanaPackage = import ../../../packages/stable/grafana;

  login = {
    username = "app";
    password = "smtp-pw";
  };

  # The SMTP server for namespace `ns`, with its login secret in `secretNs`.
  smtpModule =
    {
      ns,
      out,
      credentials,
      secretNs ? ns,
      secretData ? login,
    }:
    { ref, ... }:
    if credentials then
      {
        instances =
          lib.recursiveUpdate
            {
              ${secretNs}.app-smtp = {
                package = secretPackage;
                config.stringData = secretData;
              };
            }
            {
              ${ns}.smtp.package = eval.mkImport {
                scope = "namespace";
                out = out // {
                  credentials = ref.${secretNs}.app-smtp;
                };
              };
            };
      }
    else
      { instances.mail.smtp.package = eval.mkImport { inherit out; }; };

  # A `database` provider with the Postgres contract's out shape.
  databasePackage =
    { ... }:
    {
      meta = {
        version = "test";
        description = "database stub";
        owner = "test";
        defaultAliases = [ "database" ];
      };
      build =
        { self, scope, ... }:
        {
          credentials = scope.mkSecret {
            name = "db-credentials";
            keys = [
              "username"
              "password"
            ];
            stringData = {
              username = "vault";
              password = "pw";
            };
          };
          root = {
            resource = self.credentials;
            out = {
              host = "db.${scope.namespaceName}.svc";
              port = "5432";
              database = "vault";
              credentials = self.credentials;
            };
          };
        };
    };

  vaultwardenCluster =
    {
      relay ? relayOut,
      credentials ? true,
      secretNs ? "vault",
      secretData ? login,
      rds ? false,
      config ? { },
      netpol ? false,
    }:
    mkCluster (
      [
        (
          { ref, ... }:
          {
            instances.vault = {
              vaultwarden = {
                package = vaultwardenPackage;
                config = {
                  domain = "https://vault.example.org";
                }
                // config;
              };
              storage = {
                package = pvcPackage;
                config = {
                  size = "1Gi";
                  storageClassName = "standard";
                };
              };
              standard-class = storageClassImport "standard";
            }
            // (
              if rds then
                {
                  # An outside PostgreSQL: the import names its login with ref.
                  rds-login = {
                    package = secretPackage;
                    config.stringData = {
                      username = "vault";
                      password = "pw";
                    };
                  };
                  database.package = eval.mkImport {
                    scope = "namespace";
                    out = {
                      host = "vault.abc123.eu-west-1.rds.amazonaws.com";
                      port = "5432";
                      database = "vault";
                      tls = true;
                      credentials = ref.vault.rds-login;
                    };
                  };
                }
              else
                { vaultwarden-db.package = databasePackage; }
            );
          }
        )
      ]
      ++ lib.optional (relay != null) (smtpModule {
        ns = "vault";
        out = relay;
        inherit credentials secretNs secretData;
      })
      ++ lib.optional netpol netpolOn
    );

  grafanaCluster =
    {
      relay ? relayOut,
      credentials ? true,
      config ? { },
    }:
    mkCluster (
      [
        {
          instances.monitoring = {
            grafana = {
              package = grafanaPackage;
              inherit config;
            };
            grafana-admin = {
              package = secretPackage;
              aliases = [ "grafanaAdmin" ];
              config.stringData = {
                admin-user = "admin";
                admin-password = "pw";
              };
            };
          };
        }
      ]
      ++ lib.optional (relay != null) (smtpModule {
        ns = "monitoring";
        out = relay;
        inherit credentials;
      })
    );

  envOf =
    name: cluster:
    let
      d = byName name (ofKind "Deployment" (manifests cluster));
    in
    lib.listToAttrs (
      map (e: {
        inherit (e) name;
        value = e.value or e.valueFrom;
      }) (builtins.head d.spec.template.spec.containers).env
    );
  grafanaIni = c: (byName "grafana-config" (ofKind "ConfigMap" (manifests c))).data."grafana.ini";

  relayOut = {
    host = "smtp.example.org";
    port = "465";
    tls = "implicit";
    from = "noreply@example.org";
  };

  depOf = out: {
    inherit out;
    _meta = {
      namespaceName = "mail";
      instanceName = "smtp";
    };
  };

  credentialsWith = keys: {
    out = {
      name = "app-smtp";
      inherit keys;
      keyRef = key: {
        secretKeyRef = {
          name = "app-smtp";
          inherit key;
        };
      };
    };
  };

  settingsOf =
    {
      out ? relayOut,
      from ? null,
    }:
    contract.helpers.settings {
      who = "app apps/app";
      smtp = depOf out;
      inherit from;
    };
  fails = args: !(builtins.tryEval (builtins.deepSeq (settingsOf args) true)).success;
  messagesOf = assertions: map (a: a.message) (builtins.filter (a: !a.assertion) assertions);
in
{
  # The contract accepts a string or integer port, the three TLS modes, and
  # credentials with both keys, and refuses a port out of range, an unknown
  # mode, a host with a port, and credentials missing a key.
  smtp-contract-fields =
    contract.problems relayOut == [ ]
    && contract.problems (relayOut // { port = 587; }) == [ ]
    && contract.problems (relayOut // { tls = "none"; }) == [ ]
    &&
      contract.problems (
        relayOut
        // {
          credentials = credentialsWith [
            "username"
            "password"
          ];
        }
      ) == [ ]
    && contract.problems (relayOut // { credentials = credentialsWith [ "password" ]; }) != [ ]
    && contract.problems (relayOut // { port = "70000"; }) != [ ]
    && contract.problems (relayOut // { tls = "ssl"; }) != [ ]
    && contract.problems (relayOut // { host = "smtp.example.org:465"; }) != [ ]
    && contract.problems (relayOut // { from = "noreply"; }) != [ ]
    && contract.problems (removeAttrs relayOut [ "from" ]) == [ ]
    &&
      builtins.length (
        messagesOf (contract.assertions "app apps/app" (depOf (removeAttrs relayOut [ "tls" ])))
      ) == 1;

  # settings returns the port as a string and as a number, the server's
  # sender or the instance's, and the credentials; with no server, null.
  smtp-settings =
    let
      r = settingsOf {
        out = relayOut // {
          port = 465;
          credentials = credentialsWith [
            "username"
            "password"
          ];
        };
      };
    in
    (
      r.port == "465"
      && r.portNumber == 465
      && r.external
      && r.from == "noreply@example.org"
      && r.credentials.out.name == "app-smtp"
      && (settingsOf { }).credentials == null
      && (settingsOf { from = "app@example.org"; }).from == "app@example.org"
      &&
        contract.helpers.settings {
          who = "app";
          smtp = null;
        } == null
    )
    || throw "smtp settings: ${builtins.toJSON (removeAttrs r [ "credentials" ])}";

  # Refused: tls = "none" outside the cluster (allowed with external =
  # false), and no sender anywhere.
  smtp-settings-refusals =
    fails {
      out = relayOut // {
        tls = "none";
      };
    }
    && !(fails {
      out = relayOut // {
        tls = "none";
        external = false;
      };
    })
    && fails { out = removeAttrs relayOut [ "from" ]; }
    && !(fails {
      out = removeAttrs relayOut [ "from" ];
      from = "app@example.org";
    });

  # Vaultwarden gets the server, its security mode, the sender, and the
  # login from the secret the import names, and a mail egress policy under
  # an enforcer. Without a login, one import in `mail` serves it.
  smtp-vaultwarden-env =
    let
      env = envOf "vaultwarden" (vaultwardenCluster { });
      starttls = envOf "vaultwarden" (vaultwardenCluster {
        relay = relayOut // {
          port = "587";
          tls = "starttls";
        };
        credentials = false;
        config.mail.from = "vault@example.org";
      });
      policy = byName "vaultwarden-mail-egress" (
        manifests (vaultwardenCluster {
          netpol = true;
        })
      );
    in
    (
      env.SMTP_HOST == "smtp.example.org"
      && env.SMTP_PORT == "465"
      && env.SMTP_SECURITY == "force_tls"
      && env.SMTP_FROM == "noreply@example.org"
      && env.SMTP_USERNAME.secretKeyRef.name == "app-smtp"
      && env.SMTP_PASSWORD.secretKeyRef.key == "password"
      && starttls.SMTP_SECURITY == "starttls"
      && starttls.SMTP_FROM == "vault@example.org"
      && !(starttls ? SMTP_USERNAME)
      && !(
        envOf "vaultwarden" (vaultwardenCluster {
          relay = null;
        }) ? SMTP_HOST
      )
      && policy != null
    )
    || throw "smtp vaultwarden: ${builtins.toJSON env}";

  # Vaultwarden refuses SMTP settings in env while a server is wired, and
  # accepts them without one.
  smtp-vaultwarden-env-owned =
    (
      evalFails (vaultwardenCluster {
        config.env.SMTP_HOST = "other.example.org";
      })
      && evalFails (vaultwardenCluster {
        config.env.SMTP_PASSWORD_FILE = "/run/x";
      })
      && !(evalFails (vaultwardenCluster {
        relay = null;
        config.env.SMTP_HOST = "other.example.org";
      }))
    )
    || throw "smtp vaultwarden: SMTP settings in env were not refused";

  # An import's `ref` must name a secret the consumer can read: a secret in
  # another namespace fails at the workload, and one without the password
  # key fails the contract.
  smtp-import-ref-checked =
    (
      evalFails (vaultwardenCluster {
        secretNs = "other";
      })
      && evalFails (vaultwardenCluster {
        secretData = {
          username = "app";
        };
      })
      && !(evalFails (vaultwardenCluster { }))
    )
    || throw "smtp import ref: a secret in another namespace or without a key was accepted";

  # The import's marker waits for the secret its out names, so the deploy
  # applies the secret first. An import without a ref has no extra
  # dependency.
  smtp-import-marker-waits-for-ref =
    let
      dependsOn =
        ns: cluster:
        (lib.findFirst (
          r: r.kind == "PackageInstance" && r.metadata.name == "smtp" && r.metadata.namespace == ns
        ) null (manifests cluster)).metadata.annotations.${kixKeys.dependsOn};
      withRef = dependsOn "vault" (vaultwardenCluster { });
      withoutRef = dependsOn "mail" (vaultwardenCluster {
        credentials = false;
      });
    in
    (lib.hasInfix "extra:" withRef && !(lib.hasInfix "extra:" withoutRef))
    || throw "smtp import marker: ${withRef} / ${withoutRef}";

  # Vaultwarden on an outside PostgreSQL: a kix.mkImport whose out names the
  # login secret with ref honours the Postgres database contract.
  smtp-postgres-import-with-credentials =
    let
      env = envOf "vaultwarden" (vaultwardenCluster {
        rds = true;
        relay = null;
      });
    in
    (
      env.DB_PASSWORD.secretKeyRef.name == "rds-login"
      && env.DB_USERNAME.secretKeyRef.key == "username"
      && lib.hasInfix "rds.amazonaws.com:5432/vault" env.DATABASE_URL
    )
    || throw "postgres import: ${builtins.toJSON env}";

  # Grafana fills [smtp] in grafana.ini and passes the login through env;
  # it refuses [smtp] keys in settings and implicit TLS off port 465.
  smtp-grafana =
    let
      c = grafanaCluster { };
      ini = grafanaIni c;
      env = envOf "grafana" c;
    in
    (
      lib.hasInfix "[smtp]" ini
      && lib.hasInfix "host = smtp.example.org:465" ini
      && lib.hasInfix "from_address = noreply@example.org" ini
      && lib.hasInfix "startTLS_policy = MandatoryStartTLS" ini
      && env.GF_SMTP_USER.secretKeyRef.key == "username"
      && env.GF_SMTP_PASSWORD.secretKeyRef.name == "app-smtp"
      && !(lib.hasInfix "[smtp]" (
        grafanaIni (grafanaCluster {
          relay = null;
        })
      ))
      && evalFails (grafanaCluster {
        config.settings.smtp.host = "other.example.org:25";
      })
      && evalFails (grafanaCluster {
        config.env.GF_SMTP_PASSWORD__FILE = "/run/x";
      })
      && evalFails (grafanaCluster {
        relay = relayOut // {
          port = "2465";
        };
      })
      && evalFails (grafanaCluster {
        relay = relayOut // {
          tls = "starttls";
        };
      })
      && !(evalFails (grafanaCluster {
        relay = relayOut // {
          port = "587";
          tls = "starttls";
        };
      }))
    )
    || throw "smtp grafana: ${ini}";
}
