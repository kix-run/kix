# Tests for the SMTP relay contract (kix/lib/vocab/smtp-relay.nix): the
# contract fields and `requireRelay`, which consumer packages call on their
# `smtp` and `smtpCredentials` dependencies, and the vaultwarden and grafana
# mappings. Plausible's mapping is tested in units/plausible.nix.
#
# The relay is a kix.mkImport in namespace `mail`, as one relay for the
# whole cluster would be. tryEval drops a throw's message, so each
# evalFails sits beside a cluster that evaluates.

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
  ...
}:

let
  contract = kixlib.contracts.smtpRelay;
  secretPackage = import ../../../packages/secret;
  pvcPackage = import ../../../packages/persistent-volume-claim;
  vaultwardenPackage = import ../../../packages/vaultwarden;
  grafanaPackage = import ../../../packages/grafana;

  relayInstances = out: {
    instances.mail.smtp.package = eval.mkImport { inherit out; };
  };
  credentialInstances = ns: {
    instances.${ns}.app-smtp = {
      package = secretPackage;
      aliases = [ "smtpCredentials" ];
      config.stringData = {
        username = "app";
        password = "smtp-pw";
      };
    };
  };

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
      config ? { },
      netpol ? false,
    }:
    mkCluster (
      [
        {
          instances.vault = {
            vaultwarden = {
              package = vaultwardenPackage;
              config = {
                domain = "https://vault.example.org";
              }
              // config;
            };
            vaultwarden-db.package = databasePackage;
            storage = {
              package = pvcPackage;
              config = {
                size = "1Gi";
                storageClassName = "standard";
              };
            };
            standard-class = storageClassImport "standard";
          };
        }
      ]
      ++ lib.optional (relay != null) (relayInstances relay)
      ++ lib.optional credentials (credentialInstances "vault")
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
      ++ lib.optional (relay != null) (relayInstances relay)
      ++ lib.optional credentials (credentialInstances "monitoring")
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

  require =
    {
      out ? relayOut,
      credentials ? null,
      from ? null,
    }:
    contract.requireRelay {
      who = "app apps/app";
      smtp = depOf out;
      inherit credentials from;
    };
  fails = args: !(builtins.tryEval (builtins.deepSeq (require args) true)).success;
  messagesOf = assertions: map (a: a.message) (builtins.filter (a: !a.assertion) assertions);
in
{
  # The contract accepts a string or integer port and the three TLS modes,
  # and refuses a port out of range, an unknown mode, and a host with a port.
  smtp-relay-contract-fields =
    contract.problems relayOut == [ ]
    && contract.problems (relayOut // { port = 587; }) == [ ]
    && contract.problems (relayOut // { tls = "none"; }) == [ ]
    && contract.problems (relayOut // { port = "70000"; }) != [ ]
    && contract.problems (relayOut // { tls = "ssl"; }) != [ ]
    && contract.problems (relayOut // { host = "smtp.example.org:465"; }) != [ ]
    && contract.problems (relayOut // { from = "noreply"; }) != [ ]
    && contract.problems (removeAttrs relayOut [ "from" ]) == [ ]
    &&
      builtins.length (
        messagesOf (contract.assertions "app apps/app" (depOf (removeAttrs relayOut [ "tls" ])))
      ) == 1;

  # requireRelay returns the settings with the port as a string and as a
  # number, the relay's sender or the instance's, and the checked
  # credentials; with no relay it returns null.
  smtp-relay-require-settings =
    let
      r = require {
        out = relayOut // {
          port = 465;
        };
        credentials = credentialsWith [
          "username"
          "password"
        ];
      };
    in
    (
      r.port == "465"
      && r.portNumber == 465
      && r.external
      && r.from == "noreply@example.org"
      && r.credentials.out.name == "app-smtp"
      && (require { from = "app@example.org"; }).from == "app@example.org"
      &&
        contract.requireRelay {
          who = "app";
          smtp = null;
          credentials = null;
        } == null
    )
    || throw "smtp relay settings: ${builtins.toJSON (removeAttrs r [ "credentials" ])}";

  # Refused: tls = "none" outside the cluster (allowed with external =
  # false), no sender anywhere, credentials without both keys, and
  # credentials without a relay.
  smtp-relay-require-refusals =
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
    && fails { credentials = credentialsWith [ "password" ]; }
    && !(builtins.tryEval (
      contract.requireRelay {
        who = "app";
        smtp = null;
        credentials = credentialsWith [
          "username"
          "password"
        ];
      }
    )).success;

  # Vaultwarden gets the relay, its security mode, the sender, and the
  # login from the secret, and a mail egress policy under an enforcer.
  smtp-relay-vaultwarden-env =
    let
      env = envOf "vaultwarden" (vaultwardenCluster { });
      starttls = envOf "vaultwarden" (vaultwardenCluster {
        relay = relayOut // {
          port = "587";
          tls = "starttls";
        };
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
      && !(
        envOf "vaultwarden" (vaultwardenCluster {
          relay = null;
          credentials = false;
        }) ? SMTP_HOST
      )
      && policy != null
    )
    || throw "smtp relay vaultwarden: ${builtins.toJSON env}";

  # Vaultwarden refuses SMTP settings in env while a relay is wired, and
  # accepts them without one.
  smtp-relay-vaultwarden-env-owned =
    (
      evalFails (vaultwardenCluster {
        config.env.SMTP_HOST = "other.example.org";
      })
      && evalFails (vaultwardenCluster {
        config.env.SMTP_PASSWORD_FILE = "/run/x";
      })
      && !(evalFails (vaultwardenCluster {
        relay = null;
        credentials = false;
        config.env.SMTP_HOST = "other.example.org";
      }))
    )
    || throw "smtp relay vaultwarden: SMTP settings in env were not refused";

  # Grafana fills [smtp] in grafana.ini and passes the login through env;
  # it refuses [smtp] keys in settings and implicit TLS off port 465.
  smtp-relay-grafana =
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
          credentials = false;
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
    || throw "smtp relay grafana: ${ini}";
}
