# Tests for single sign-on through an OIDC provider: the contract
# (kix/lib/vocab/oidc-provider.nix), keycloak's `out` under it, and the
# `oidc` option of grafana, harbor, and immich.
#
# The applications bind a kix.mkImport stand-in aliased `oidcProvider`,
# except where a test needs keycloak itself (the derived egress). tryEval
# drops a throw's message, so each evalFails sits beside the enabled
# instance that evaluates (`oidc-*-renders`), which is its positive control,
# and assertion text is checked by calling the package's `assertions`.

{
  lib,
  eval,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  hasName,
  evalFails,
  netpolOn,
  ...
}:

let
  contract = kixlib.contracts.oidcProvider;
  secretPackage = import ../../../packages/stable/secret;
  keycloakPackage = import ../../../packages/stable/keycloak;
  grafanaPackage = import ../../../packages/stable/grafana;
  harborPackage = import ../../../packages/stable/harbor;
  oidcClientPackage = import ../../../packages/stable/oidc-client;
  clientContract = kixlib.contracts.oidc;
  immichPackage = import ../../../packages/stable/immich;

  issuer = realm: "https://auth.example.com/realms/${realm}";
  providerOut = {
    issuerUrl = issuer;
    endpoints = realm: {
      authorizationUrl = "${issuer realm}/protocol/openid-connect/auth";
      tokenUrl = "http://keycloak.auth.svc:8080/realms/${realm}/protocol/openid-connect/token";
      userinfoUrl = "http://keycloak.auth.svc:8080/realms/${realm}/protocol/openid-connect/userinfo";
    };
  };

  depOf = out: {
    inherit out;
    _meta = {
      namespaceName = "auth";
      instanceName = "sso";
    };
  };
  messagesOf = assertions: map (a: a.message) (builtins.filter (a: !a.assertion) assertions);
  checks =
    out: (builtins.tryEval (builtins.deepSeq (contract.check "provider auth/sso" out) true)).success;

  # The instances an application needs to sign in: the provider stand-in in
  # `auth`, and in the application's namespace an oidc-client for realm
  # `main` with the client secret beside it.
  ssoInstances = ns: clientData: {
    instances.auth.sso = {
      package = eval.mkImport { out = providerOut; };
      aliases = [ "oidcProvider" ];
    };
    instances.${ns} = {
      oidc = {
        package = oidcClientPackage;
        config.realm = "main";
      };
      app-oidc = {
        package = secretPackage;
        aliases = [ "oidcClient" ];
        config.stringData = clientData;
      };
    };
  };
  clientData = {
    clientId = "app";
    clientSecret = "test-client-secret";
  };

  # Single sign-on is on when the application has an `oidc` dependency, so
  # the `oidc` option only tunes it.
  oidcOn = { };

  # Grafana

  grafanaCluster =
    {
      config ? { },
      sso ? true,
      client ? clientData,
      env ? { },
    }:
    mkCluster [
      {
        instances.monitoring = {
          grafana = {
            package = grafanaPackage;
            config = {
              settings.server.root_url = "https://grafana.example.com";
              inherit env;
            }
            // config;
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
      (lib.optionalAttrs sso (ssoInstances "monitoring" client))
    ];
  grafanaIni = c: (byName "grafana-config" (ofKind "ConfigMap" (manifests c))).data."grafana.ini";
  grafanaEnv =
    c:
    let
      d = byName "grafana" (ofKind "Deployment" (manifests c));
    in
    lib.listToAttrs (
      map (e: {
        inherit (e) name;
        value = e.value or e.valueFrom;
      }) (builtins.head d.spec.template.spec.containers).env
    );

  # Grafana with its own client secret and, when `sso` is set, an
  # oidc-client with `deps`, for clusters with keycloak instances.
  grafanaWith = sso: deps: {
    instances.monitoring = {
      grafana = {
        package = grafanaPackage;
        config.settings.server.root_url = "https://grafana.example.com";
      };
      ${if sso then "oidc" else null} = {
        package = oidcClientPackage;
        config.realm = "main";
        inherit deps;
      };
      grafana-admin = {
        package = secretPackage;
        aliases = [ "grafanaAdmin" ];
        config.stringData = {
          admin-user = "admin";
          admin-password = "pw";
        };
      };
      grafana-oidc = {
        package = secretPackage;
        aliases = [ "oidcClient" ];
        config.stringData = clientData;
      };
    };
  };

  # Keycloak in `ns` with a database stub, for the derived egress.
  keycloakIn = ns: {
    instances.${ns} = {
      keycloak = {
        package = keycloakPackage;
        config.env.KC_HOSTNAME = "https://${ns}.example.com";
      };
      keycloak-db.package =
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
                  username = "keycloak";
                  password = "pw";
                };
              };
              root = {
                resource = self.credentials;
                out = {
                  host = "db.${ns}.svc";
                  port = "5432";
                  database = "keycloak";
                  credentials = self.credentials;
                };
              };
            };
        };
      keycloak-admin = {
        package = secretPackage;
        aliases = [ "bootstrapAdmin" ];
        config.stringData = {
          username = "admin";
          password = "pw";
        };
      };
    };
  };

  keycloakInstances = keycloakIn "auth";

  # Immich

  immichCluster =
    {
      config ? { },
      sso ? true,
    }:
    mkCluster [
      {
        instances.photos = {
          immich = {
            package = immichPackage;
            inherit config;
          };
          immich-db = {
            package = eval.mkImport {
              out = {
                host = "db.example.net";
                port = "5432";
                database = "immich";
                credentials.out.keyRef = key: {
                  valueFrom.secretKeyRef = {
                    name = kixlib.untrackedRef {
                      name = "immich-db";
                      kind = "Secret";
                    };
                    inherit key;
                  };
                };
              };
            };
            aliases = [ "database" ];
          };
          valkey = {
            package = eval.mkImport {
              out = {
                host = "valkey.example.net";
                port = "6379";
              };
            };
            aliases = [ "valkey" ];
          };
          library = {
            package = eval.mkImport {
              out = {
                name = kixlib.untrackedRef {
                  name = "library";
                  kind = "PersistentVolumeClaim";
                };
                size = "100Gi";
              };
            };
            aliases = [ "storage" ];
          };
        };
      }
      (lib.optionalAttrs sso (ssoInstances "photos" clientData))
    ];
  immichDeployment = c: byName "immich-server" (ofKind "Deployment" (manifests c));
  immichConfig =
    c:
    builtins.fromJSON
      (byName "immich-config" (ofKind "ConfigMap" (manifests c))).data."immich-config.json";

  # Harbor

  harborCluster =
    {
      config ? { },
      sso ? true,
    }:
    mkCluster [
      {
        instances.registry = {
          harbor = {
            package = harborPackage;
            config = {
              externalURL = "https://harbor.example.com";
            }
            // config;
          };
          harbor-secrets = {
            package = secretPackage;
            aliases = [ "harborSecrets" ];
            config.stringData = lib.genAttrs [
              "adminPassword"
              "secretKey"
              "coreSecret"
              "jobserviceSecret"
              "csrfKey"
              "registryHttpSecret"
              "registryPassword"
              "tokenPrivateKey"
            ] (_: "test");
          };
          harbor-db.package =
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
                    name = "harbor-db-credentials";
                    keys = [
                      "username"
                      "password"
                    ];
                    stringData = {
                      username = "harbor";
                      password = "pw";
                    };
                  };
                  root = {
                    resource = self.credentials;
                    out = {
                      host = "db.registry.svc";
                      port = "5432";
                      database = "registry";
                      username = "harbor";
                      tls = false;
                      credentials = self.credentials;
                    };
                  };
                };
            };
          valkey = {
            package = eval.mkImport {
              out = {
                host = "valkey.example.net";
                port = "6379";
              };
            };
            aliases = [ "valkey" ];
          };
          blobs = {
            package = eval.mkImport {
              out.name = kixlib.untrackedRef {
                name = "blobs";
                kind = "PersistentVolumeClaim";
              };
            };
            aliases = [ "storage" ];
          };
        };
      }
      (lib.optionalAttrs sso (ssoInstances "registry" clientData))
    ];
  harborCoreEnv =
    c:
    let
      d = byName "harbor-core" (ofKind "Deployment" (manifests c));
    in
    builtins.head d.spec.template.spec.containers |> (x: x.env);
  harborOverwrite =
    c:
    builtins.fromJSON
      (builtins.head (builtins.filter (e: e.name == "CONFIG_OVERWRITE_JSON") (harborCoreEnv c))).value;
  harborAssertions =
    config:
    messagesOf (
      (harborPackage {
        scope = {
          instanceName = "harbor";
          namespaceName = "registry";
        };
        inherit lib;
        kix = kixlib;
        availability = "none";
      }).assertions
        { inherit config; }
    );
in
{
  # The contract: a provider out with both fields passes `check` unchanged;
  # one without `endpoints`, with an issuer that is no URL, or with an
  # endpoint set missing a key is refused.
  oidc-contract-check-requires-every-field =
    builtins.deepSeq (contract.check "provider auth/sso" providerOut) true
    && !checks { inherit (providerOut) issuerUrl; }
    && !checks (providerOut // { issuerUrl = _: "auth.example.com"; })
    && !checks (providerOut // { issuerUrl = "https://auth.example.com"; })
    && !checks (
      providerOut
      // {
        endpoints = realm: builtins.removeAttrs (providerOut.endpoints realm) [ "tokenUrl" ];
      }
    );

  # A consumer accepts a stand-in with only `issuerUrl` and refuses one
  # without it, naming the consumer, the provider instance, and the field.
  oidc-contract-assertions-name-instance-and-field =
    let
      missing = messagesOf (
        contract.assertions "app apps/app" (depOf {
          url = "https://x";
        })
      );
    in
    messagesOf (
      contract.assertions "app apps/app" (depOf {
        inherit (providerOut) issuerUrl;
      })
    ) == [ ]
    && builtins.length missing == 1
    && lib.hasInfix "app apps/app" (builtins.head missing)
    && lib.hasInfix "auth/sso" (builtins.head missing)
    && lib.hasInfix "issuerUrl is missing" (builtins.head missing);

  # Keycloak's out honours the contract: the authorization URL is public
  # and the token and userinfo URLs are the Service's address.
  oidc-keycloak-out-endpoints =
    let
      out = (mkCluster [ keycloakInstances ]).instances.auth.keycloak.out;
      e = out.endpoints "main";
    in
    (
      out.issuerUrl "main" == "https://auth.example.com/realms/main"
      && e.authorizationUrl == "https://auth.example.com/realms/main/protocol/openid-connect/auth"
      && lib.hasPrefix "http://keycloak.auth.svc." e.tokenUrl
      && lib.hasSuffix ":8080/realms/main/protocol/openid-connect/token" e.tokenUrl
      && lib.hasSuffix ":8080/realms/main/protocol/openid-connect/userinfo" e.userinfoUrl
      && !(builtins.tryEval (out.endpoints "a/b").tokenUrl).success
    )
    || throw "keycloak endpoints: ${builtins.toJSON e}";

  # The client contract wants an issuer URL and credentials with both keys;
  # endpoints are optional but checked when present.
  oidc-client-contract-fields =
    let
      credentials = keys: {
        out = {
          inherit keys;
          keyRef = key: { secretKeyRef = { inherit key; }; };
        };
      };
      good = {
        issuerUrl = "https://login.example.com";
        credentials = credentials [
          "clientId"
          "clientSecret"
        ];
      };
    in
    clientContract.problems good == [ ]
    && clientContract.problems (removeAttrs good [ "credentials" ]) != [ ]
    && clientContract.problems (good // { credentials = credentials [ "clientId" ]; }) != [ ]
    && clientContract.problems (good // { issuerUrl = "login.example.com"; }) != [ ]
    && clientContract.problems (good // { endpoints.tokenUrl = "https://x"; }) != [ ];

  # A provider outside the cluster with one issuer: a kix.mkImport in the
  # application's namespace answers `oidc`, naming the client secret with
  # ref. Grafana reads the issuer's endpoints and the secret from it.
  oidc-grafana-import-client =
    let
      c = mkCluster [
        (grafanaWith false { })
        (
          { ref, ... }:
          {
            instances.monitoring.oidc.package = eval.mkImport {
              scope = "namespace";
              out = {
                issuerUrl = "https://login.example.com";
                endpoints = {
                  authorizationUrl = "https://login.example.com/authorize";
                  tokenUrl = "https://login.example.com/token";
                  userinfoUrl = "https://login.example.com/userinfo";
                };
                credentials = ref.monitoring.grafana-oidc;
              };
            };
          }
        )
      ];
      ini = grafanaIni c;
    in
    (
      lib.hasInfix "token_url = https://login.example.com/token" ini
      && (grafanaEnv c).GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET.secretKeyRef.name == "grafana-oidc"
    )
    || throw "grafana import client: ${ini}";

  # Grafana renders auth.generic_oauth from the provider and reads the
  # client from the secret through env; this instance is the positive
  # control for the Grafana refusals below. Role mapping stays in settings.
  oidc-grafana-renders =
    let
      c = grafanaCluster {
        config = {
          oidc = oidcOn // {
            autoLogin = true;
          };
          settings = {
            server.root_url = "https://grafana.example.com";
            "auth.generic_oauth".role_attribute_path = "'Admin'";
          };
        };
      };
      ini = grafanaIni c;
      env = grafanaEnv c;
    in
    (
      lib.hasInfix "[auth.generic_oauth]" ini
      && lib.hasInfix "auth_url = https://auth.example.com/realms/main/protocol/openid-connect/auth" ini
      && lib.hasInfix "token_url = http://keycloak.auth.svc:8080/realms/main/protocol/openid-connect/token" ini
      && lib.hasInfix "api_url = http://keycloak.auth.svc:8080/realms/main/protocol/openid-connect/userinfo" ini
      && lib.hasInfix "scopes = openid profile email" ini
      && lib.hasInfix "use_pkce = true" ini
      && lib.hasInfix "auto_login = true" ini
      && lib.hasInfix "role_attribute_path = 'Admin'" ini
      && !(lib.hasInfix "client_secret" ini)
      && env.GF_AUTH_GENERIC_OAUTH_CLIENT_ID.secretKeyRef.key == "clientId"
      && env.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET.secretKeyRef.key == "clientSecret"
    )
    || throw "grafana oidc: ${ini}";

  # Without an `oidc` dependency, a provider and a client secret change
  # nothing.
  oidc-grafana-off-ignores-provider =
    let
      c = mkCluster [
        (grafanaWith false { })
        keycloakInstances
      ];
    in
    !(lib.hasInfix "generic_oauth" (grafanaIni c))
    && !((grafanaEnv c) ? GF_AUTH_GENERIC_OAUTH_CLIENT_ID);

  # Grafana's token and userinfo requests go to keycloak's Service, so the
  # netpol plugin admits Grafana at keycloak.
  oidc-grafana-egress-to-keycloak = hasName "grafana-deployment-grafana-to-keycloak-ingress" (
    manifests (mkCluster [
      keycloakInstances
      netpolOn
      ({ ref, ... }: grafanaWith true { oidcProvider = ref.auth.keycloak; })
    ])
  );

  # keycloak answers no alias, so two instances bind no client by
  # themselves: Grafana without a client evaluates, and its oidc-client
  # names one with deps or fails for want of a provider.
  oidc-grafana-two-providers =
    let
      two =
        extra:
        mkCluster [
          (keycloakIn "auth")
          (keycloakIn "auth2")
          extra
        ];
    in
    !(evalFails (two (grafanaWith false { })))
    && !(evalFails (two ({ ref, ... }: grafanaWith true { oidcProvider = ref.auth2.keycloak; })))
    && evalFails (two (grafanaWith true { }));

  # An oidc-client without a provider fails.
  oidc-client-needs-provider = evalFails (mkCluster [ (grafanaWith true { }) ]);

  # The removed oidc.enabled and oidc.realm are refused, with or without a
  # client.
  oidc-removed-options-refused =
    evalFails (grafanaCluster {
      config.oidc.enabled = true;
    })
    && evalFails (grafanaCluster {
      sso = false;
      config.oidc.realm = "main";
    })
    && !(evalFails (grafanaCluster { }));
  oidc-grafana-needs-client-keys = evalFails (grafanaCluster {
    config.oidc = oidcOn;
    client.clientId = "app";
  });
  oidc-grafana-needs-root-url = evalFails (grafanaCluster {
    config = {
      oidc = oidcOn;
      settings = { };
    };
  });
  oidc-grafana-settings-locked = evalFails (grafanaCluster {
    config = {
      oidc = oidcOn;
      settings."auth.generic_oauth".token_url = "https://elsewhere.example.com/token";
      settings.server.root_url = "https://grafana.example.com";
    };
  });
  oidc-grafana-env-locked = evalFails (grafanaCluster {
    config.oidc = oidcOn;
    env.GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = "literal";
  });
  oidc-scopes-need-openid = evalFails (grafanaCluster {
    config.oidc = oidcOn // {
      scopes = [ "profile" ];
    };
  });

  # Immich: the ConfigMap carries the OAuth settings without the client,
  # and the container writes the client into a copy on a memory volume.
  oidc-immich-renders =
    let
      c = immichCluster {
        config = {
          oidc = oidcOn // {
            autoLogin = true;
          };
          settings.oauth.roleClaim = "immich_role";
        };
      };
      d = immichDeployment c;
      container = builtins.head d.spec.template.spec.containers;
      env = lib.listToAttrs (
        map (e: {
          inherit (e) name;
          value = e.value or e.valueFrom;
        }) container.env
      );
      oauth = (immichConfig c).oauth;
    in
    (
      oauth == {
        enabled = true;
        issuerUrl = "https://auth.example.com/realms/main";
        scope = "openid email profile";
        autoLaunch = true;
        roleClaim = "immich_role";
      }
      && env.IMMICH_CONFIG_FILE == "/run/immich/immich-config.json"
      && env.OAUTH_CLIENT_SECRET.secretKeyRef.key == "clientSecret"
      && lib.hasInfix "/config/immich-config.json /run/immich/immich-config.json" (
        builtins.head container.args
      )
      && lib.hasSuffix "exec start.sh\n" (builtins.head container.args)
      && builtins.any (
        v: v.name == "runtime-config" && v.emptyDir.medium == "Memory"
      ) d.spec.template.spec.volumes
    )
    || throw "immich oidc: ${builtins.toJSON oauth}";

  # A client secret in settings would land in the ConfigMap, with or
  # without oidc; the issuer is settable only while oidc is off.
  oidc-immich-settings-secret-refused = evalFails (immichCluster {
    sso = false;
    config.settings.oauth.clientSecret = "literal";
  });
  oidc-immich-settings-issuer-free-when-off =
    !(evalFails (immichCluster {
      sso = false;
      config.settings.oauth.issuerUrl = "https://elsewhere.example.com";
    }));
  oidc-immich-settings-locked = evalFails (immichCluster {
    config = {
      oidc = oidcOn;
      settings.oauth.issuerUrl = "https://elsewhere.example.com";
    };
  });

  # Harbor: CONFIG_OVERWRITE_JSON carries the auth mode and references to
  # the client env entries, which come before it.
  oidc-harbor-renders =
    let
      c = harborCluster {
        config = {
          oidc = oidcOn // {
            groupsClaim = "groups";
            adminGroup = "admins";
          };
          core.settings.oidc_auto_onboard = true;
        };
      };
      env = harborCoreEnv c;
      names = map (e: e.name) env;
      indexOf = n: lib.lists.findFirstIndex (x: x == n) null names;
      o = harborOverwrite c;
    in
    (
      o == {
        auth_mode = "oidc_auth";
        oidc_endpoint = "https://auth.example.com/realms/main";
        oidc_client_id = "$(OIDC_CLIENT_ID)";
        oidc_client_secret = "$(OIDC_CLIENT_SECRET)";
        oidc_scope = "openid,profile,email,offline_access";
        oidc_groups_claim = "groups";
        oidc_admin_group = "admins";
        oidc_name = "OpenID Connect";
        oidc_auto_onboard = true;
      }
      && indexOf "OIDC_CLIENT_SECRET" < indexOf "CONFIG_OVERWRITE_JSON"
    )
    || throw "harbor oidc: ${builtins.toJSON o}";

  oidc-harbor-settings-secret-refused = evalFails (harborCluster {
    sso = false;
    config.core.settings.oidc_client_secret = "literal";
  });
  oidc-harbor-settings-locked = evalFails (harborCluster {
    config = {
      oidc = oidcOn;
      core.settings.auth_mode = "db_auth";
    };
  });
  oidc-harbor-env-locked = evalFails (harborCluster {
    sso = false;
    config.core.env.CONFIG_OVERWRITE_JSON = "{}";
  });
  # core.settings alone also reaches CONFIG_OVERWRITE_JSON.
  # A `$` in a value is doubled, so Kubernetes' `$(VAR)` expansion hands
  # Harbor the value as written.
  oidc-harbor-settings-without-oidc =
    harborOverwrite (harborCluster {
      sso = false;
      config.core.settings = {
        robot_token_duration = 30;
        robot_name_prefix = "bot$(x)";
      };
    }) == {
      robot_token_duration = 30;
      robot_name_prefix = "bot$$(x)";
    };

  oidc-harbor-settings-ldap-password-refused = evalFails (harborCluster {
    sso = false;
    config.core.settings.ldap_search_password = "literal";
  });

  oidc-harbor-admin-group-needs-groups-claim =
    let
      bad = harborAssertions {
        oidc = {
          adminGroup = "admins";
          groupsClaim = null;
        };
      };
    in
    builtins.length bad == 1
    && lib.hasInfix "oidc.groupsClaim" (builtins.head bad)
    &&
      harborAssertions {
        oidc = {
          adminGroup = "admins";
          groupsClaim = "groups";
        };
      } == [ ];
}
