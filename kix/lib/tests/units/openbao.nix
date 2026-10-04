# Tests for kix/packages/openbao: the self-initialization config and the
# reconcile Job's role and policy, the Raft join addresses, the shamir mode,
# the package's refusals, and `out.externalSecretsProvider` with its
# refusals. OpenBao runs as instance `openbao` in namespace `secrets`, and
# the store's consumer in `app`.

{
  lib,
  kixKeys,
  kixlib,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  multiZone,
  netpolOn,
  ...
}:

let
  openbaoPackage = import ../../../packages/openbao;
  certManagerPackage = import ../../../packages/cert-manager;
  externalSecretsPackage = import ../../../packages/external-secrets;
  secretPackage = import ../../../packages/secret;

  # The instance config of the test cluster: one engine, one policy, and a
  # role bound to the consumer's ServiceAccount.
  declared = {
    secretsEngines = {
      secret = {
        type = "kv";
        options.version = "2";
      };
      pki.type = "pki";
    };
    policies.app-read = ''path "secret/data/app/*" { capabilities = ["read"] }'';
    kubernetesAuth.roles.app = {
      bound_service_account_names = [ "store" ];
      bound_service_account_namespaces = [ "app" ];
      token_policies = [ "app-read" ];
    };
  };

  # A ClusterSecretStore from `out.externalSecretsProvider` with `args`
  # over the arguments that match `declared`.
  mkConsumer = args: {
    meta = {
      description = "OpenBao store consumer";
      owner = "test";
    };
    build =
      {
        self,
        scope,
        externalSecrets,
        openbao,
        ...
      }:
      {
        sa = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = args.saName or "store";
        };
        store = externalSecrets.out.mkClusterSecretStore scope {
          name = "openbao";
          spec = {
            provider = openbao.out.externalSecretsProvider scope (
              {
                serviceAccount = self.sa;
                role = "app";
                mount = "secret";
              }
              // removeAttrs args [ "saName" ]
            );
            conditions = [ { namespaces = [ scope.namespaceName ]; } ];
          };
        };
        root = self.store;
      };
  };

  clusterWith =
    {
      config ? declared,
      consumer ? null,
      consumerNamespace ? "app",
      unsealKey ? true,
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.cert-manager.cert-manager.package = certManagerPackage;
          instances.secrets = {
            openbao = {
              package = openbaoPackage;
              inherit config;
            };
          }
          // lib.optionalAttrs unsealKey {
            openbao-unseal = {
              package = secretPackage;
              aliases = [ "unsealKey" ];
              config.stringData.key = "0123456789abcdef0123456789abcdef";
            };
          };
        }
      ]
      ++ lib.optional (consumer != null) {
        instances.external-secrets.external-secrets.package = externalSecretsPackage;
        instances.${consumerNamespace}.consumer.package = consumer;
      }
      ++ modules
    );

  find =
    cluster: kind: name:
    byName name (ofKind kind (manifests cluster));

  cluster = clusterWith { consumer = mkConsumer { }; };
  netpolCluster = clusterWith {
    consumer = mkConsumer { };
    modules = [ netpolOn ];
  };
  cnps = ofKind "CiliumNetworkPolicy" (manifests netpolCluster);
  cnpIn =
    ns: name:
    lib.findFirst (m: m.metadata.name == name && (m.metadata.namespace or null) == ns) null cnps;
  zoneCluster = clusterWith { modules = [ multiZone ]; };

  initOf = c: builtins.fromJSON (find c "ConfigMap" "openbao-init").data."init.json";
  bootstrapRequests =
    c: lib.foldl' (acc: r: acc // r) { } (builtins.head (initOf c).initialize).kix-bootstrap.request;
  serverConfigOf = c: builtins.fromJSON (find c "ConfigMap" "openbao-config").data."server.json";
  containerOf = c: builtins.head (find c "StatefulSet" "openbao").spec.template.spec.containers;
  pathsOf =
    policy:
    map builtins.head (
      builtins.filter (m: m != null) (
        map (builtins.match ''path "([^"]+)".*'') (lib.splitString "\n" policy)
      )
    );
  hashOf =
    nsName: inst: part:
    builtins.unsafeDiscardStringContext
      cluster.instances.${nsName}.${inst}.raw.${part}.out.identityHash;
  dependsOn = m: lib.splitString "," ((m.metadata.annotations or { }).${kixKeys.dependsOn} or "");

  # The package's assertions read only `config` and `lib`.
  assertionsOf =
    (openbaoPackage {
      inherit lib;
      scope = {
        instanceName = "openbao";
        namespaceName = "secrets";
      };
      kix = kixlib;
      availability = "none";
    }).assertions;
  defaultConfig = {
    image.tag = "2.7.1";
    seal.type = "static";
    policies = { };
    kubernetesAuth.roles = { };
    secretsEngines = { };
  };
  failedWith =
    over:
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (assertionsOf {
        config = lib.recursiveUpdate defaultConfig over;
      })
    );
  role = policies: {
    bound_service_account_names = [ "a" ];
    bound_service_account_namespaces = [ "b" ];
    token_policies = policies;
  };
  refusedOnlyBy =
    over: needle:
    let
      failed = failedWith over;
    in
    failedWith { } == [ ] && builtins.length failed == 1 && lib.hasInfix needle (builtins.head failed)
    || throw "openbao assertions for ${builtins.toJSON over}: ${builtins.toJSON failed}";
in
{
  # The role self-initialization creates for the reconcile Job binds that
  # Job's ServiceAccount in OpenBao's namespace and nothing else.
  openbao-reconcile-role-binds-only-job-sa =
    let
      data = (bootstrapRequests cluster).reconcile-role.data;
      jobSa = (find cluster "Job" "openbao-reconcile").spec.template.spec.serviceAccountName;
    in
    (
      data.bound_service_account_names == [ jobSa ]
      && data.bound_service_account_namespaces == [ "secrets" ]
      && data.token_policies == [ "kix-reconcile" ]
      && jobSa == "openbao-reconcile"
    )
    || throw "openbao reconcile role: ${builtins.toJSON data}, Job SA ${jobSa}";

  # The reconcile policy grants the policy and role paths and one mount path
  # per declared engine, in self-initialization and in the Job's ConfigMap.
  openbao-reconcile-policy-paths =
    let
      expected = [
        "sys/policies/acl/*"
        "auth/kubernetes/role/*"
        "sys/mounts/pki"
        "sys/mounts/secret"
      ];
      init = pathsOf (bootstrapRequests cluster).reconcile-policy.data.policy;
      job = pathsOf (find cluster "ConfigMap" "openbao-reconcile").data."reconcile.hcl";
    in
    (init == expected && job == expected)
    || throw "openbao reconcile policy paths: init ${builtins.toJSON init}, job ${builtins.toJSON job}";

  # Self-initialization enables Kubernetes auth before configuring it, and
  # writes the policy before the role that names it.
  openbao-self-init-order =
    let
      names =
        map (r: builtins.head (builtins.attrNames r))
          (builtins.head (initOf cluster).initialize).kix-bootstrap.request;
    in
    names == [
      "enable-kubernetes-auth"
      "configure-kubernetes-auth"
      "reconcile-policy"
      "reconcile-role"
    ]
    || throw "openbao self-init order: ${builtins.toJSON names}";

  # At level zone, three pods: every pod is a retry_join target, and pod 0
  # checks pods 1 and 2 before it initializes.
  openbao-retry-join-per-pod =
    let
      joins = map (j: j.leader_api_addr) (serverConfigOf zoneCluster).storage.raft.retry_join;
      env = builtins.listToAttrs (
        map (e: lib.nameValuePair e.name (e.value or null)) (containerOf zoneCluster).env
      );
      podUrl = i: "https://openbao-${toString i}.openbao-headless.secrets.svc.cluster.local:8200";
    in
    (
      (find zoneCluster "StatefulSet" "openbao").spec.replicas == 3
      &&
        joins == map podUrl [
          0
          1
          2
        ]
      && env.PEER_ADDRS == "${podUrl 1} ${podUrl 2}"
    )
    || throw "openbao retry_join: ${builtins.toJSON joins}, PEER_ADDRS ${env.PEER_ADDRS}";

  # Kubernetes expands $(POD_NAME) only in variables listed after it.
  openbao-pod-name-env-first =
    (builtins.head (containerOf cluster).env).name == "POD_NAME"
    || throw "openbao env order: ${builtins.toJSON (map (e: e.name) (containerOf cluster).env)}";

  # The store from the provider reads the CA from OpenBao's namespace, logs
  # in as the consumer's ServiceAccount, and is ordered after the reconcile
  # Job that writes the role and after the Certificate that writes the CA
  # Secret. It expects no Secret by name: the deploy would look for it in
  # the store's own namespace, and a ClusterSecretStore has none.
  openbao-external-secrets-provider =
    let
      store = find cluster "ClusterSecretStore" "openbao";
      vault = store.spec.provider.vault;
      job = hashOf "secrets" "openbao" "reconcile";
      certificate = hashOf "secrets" "openbao" "serverCertificate";
    in
    (
      vault.server == "https://openbao.secrets.svc.cluster.local:8200"
      && vault.path == "secret"
      && vault.version == "v2"
      &&
        vault.caProvider == {
          type = "Secret";
          name = "openbao-tls";
          key = "ca.crt";
          namespace = "secrets";
        }
      &&
        vault.auth.kubernetes == {
          mountPath = "kubernetes";
          role = "app";
          serviceAccountRef = {
            name = "store";
            namespace = "app";
          };
        }
      && lib.any (lib.hasInfix job) (dependsOn store)
      && lib.any (lib.hasInfix certificate) (dependsOn store)
      && !((store.metadata.annotations or { }) ? ${kixKeys.expects})
    )
    || throw "openbao provider: ${builtins.toJSON store}";

  # The store's address opens the external-secrets controller's egress to
  # OpenBao on 8200 in the controller's namespace, and OpenBao's ingress
  # from the controller's namespace.
  openbao-external-secrets-network-edge =
    let
      egress = cnpIn "external-secrets" "app-consumer-clustersecretstore-openbao-egress";
      ingress = cnpIn "secrets" "app-consumer-clustersecretstore-openbao-to-openbao-ingress";
      json = builtins.toJSON { inherit egress ingress; };
    in
    (
      egress != null
      && ingress != null
      && egress.spec.endpointSelector.matchLabels."app.kubernetes.io/component" == "controller"
      && lib.any (
        r: (r.namespace or null) == "secrets" && map (p: p.port) (r.ports or [ ]) == [ 8200 ]
      ) egress.spec.egress
      && lib.any (
        r:
        (r.callerNamespace or null) == "external-secrets"
        && (r.callerSelector."app.kubernetes.io/component" or null) == "controller"
        && map (p: p.port) (r.ports or [ ]) == [ 8200 ]
      ) ingress.spec.ingress
    )
    || throw "openbao network edge: ${json}; policies: ${
      builtins.toJSON (map (m: "${m.metadata.namespace or ""}/${m.metadata.name}") cnps)
    }";

  # Each refusal of the provider, beside the positive control above.
  openbao-provider-refuses-unknown-role =
    evalFails (clusterWith {
      consumer = mkConsumer { role = "other"; };
    })
    && !(evalFails cluster);
  openbao-provider-refuses-unbound-sa =
    evalFails (clusterWith {
      consumer = mkConsumer { saName = "other"; };
    })
    && !(evalFails cluster);
  openbao-provider-refuses-unbound-namespace =
    evalFails (clusterWith {
      consumer = mkConsumer { };
      consumerNamespace = "elsewhere";
    })
    && !(evalFails cluster);
  openbao-provider-refuses-non-kv-mount =
    evalFails (clusterWith {
      consumer = mkConsumer { mount = "pki"; };
    })
    && evalFails (clusterWith {
      consumer = mkConsumer { mount = "missing"; };
    })
    && !(evalFails cluster);
  # `*` binds any ServiceAccount and namespace.
  openbao-provider-wildcard-binds =
    !(evalFails (clusterWith {
      config = lib.recursiveUpdate declared {
        kubernetesAuth.roles.app = {
          bound_service_account_names = [ "*" ];
          bound_service_account_namespaces = [ "*" ];
        };
      };
      consumer = mkConsumer { saName = "other"; };
      consumerNamespace = "elsewhere";
    }));

  # Shamir: no self-initialization, no static seal, no reconcile Job.
  openbao-shamir-renders-no-init =
    let
      c = clusterWith {
        config.seal.type = "shamir";
        unsealKey = false;
      };
      ms = manifests c;
    in
    (
      byName "openbao-reconcile" (ofKind "Job" ms) == null
      && byName "openbao-init" (ofKind "ConfigMap" ms) == null
      && !((serverConfigOf c) ? seal)
      && find c "StatefulSet" "openbao" != null
    )
    || throw "openbao shamir: ${builtins.toJSON (serverConfigOf c)}";
  # Declared policies, roles, or engines need the Job, which shamir has none
  # of.
  openbao-shamir-refuses-declarations =
    evalFails (clusterWith {
      config = declared // {
        seal.type = "shamir";
      };
      unsealKey = false;
    })
    && refusedOnlyBy {
      seal.type = "shamir";
      policies.p = "";
    } "self-initialization needs the static seal";

  # The static seal needs the key.
  openbao-static-needs-unseal-key =
    evalFails (clusterWith {
      unsealKey = false;
    })
    && !(evalFails cluster);

  # Reserved and invalid names, and roles naming undeclared policies.
  openbao-refuses-reserved-policy =
    refusedOnlyBy { policies.kix-reconcile = ""; } "the reconcile Job's own policy"
    && refusedOnlyBy { policies.root = ""; } "OpenBao owns root";
  openbao-refuses-reserved-role = refusedOnlyBy {
    kubernetesAuth.roles.kix-reconcile = role [ ];
  } "the reconcile Job's own role";
  openbao-refuses-invalid-names =
    refusedOnlyBy { policies."a b" = ""; } "policies has the names"
    && refusedOnlyBy { kubernetesAuth.roles."-x" = role [ ]; } "kubernetesAuth.roles has the names";
  openbao-refuses-unknown-token-policy =
    refusedOnlyBy { kubernetesAuth.roles.r = role [ "missing" ]; } "r -> missing"
    && failedWith { kubernetesAuth.roles.r = role [ "default" ]; } == [ ];
  openbao-refuses-bad-engine-path =
    refusedOnlyBy { secretsEngines."sys/x".type = "kv"; } "secretsEngines has the paths"
    && refusedOnlyBy { secretsEngines."/x".type = "kv"; } "secretsEngines has the paths"
    && failedWith { secretsEngines."team/kv".type = "kv"; } == [ ];

  # The listener option tls_auto_reload needs 2.7; a tag that is not a
  # version is not checked.
  openbao-refuses-old-image =
    refusedOnlyBy { image.tag = "2.6.4"; } "older than OpenBao 2.7"
    && failedWith { image.tag = "2.10.0"; } == [ ]
    && failedWith { image.tag = "custom-build"; } == [ ];

  # `settings` cannot replace a key the package sets, and `env` cannot set
  # an owned variable.
  openbao-settings-locked =
    evalFails (clusterWith {
      config = declared // {
        settings.seal = { };
      };
    })
    && !(evalFails (clusterWith {
      config = declared // {
        settings.log_level = "debug";
      };
    }));
  openbao-env-owned =
    evalFails (clusterWith {
      config = declared // {
        env.BAO_SEAL_TYPE = "shamir";
      };
    })
    && !(evalFails (clusterWith {
      config = declared // {
        env.BAO_LOG_LEVEL = "debug";
      };
    }));
}
