# openbao: OpenBao, a secrets manager (the MPL fork of HashiCorp Vault), as
# a StatefulSet on integrated Raft storage, with TLS from cert-manager and
# Kubernetes auth for external-secrets.
#
# Installs a StatefulSet with a volume per pod, a Service on port 8200, a
# headless Service for the Raft peers, the server's ServiceAccount and a
# ClusterRoleBinding to `system:auth-delegator` (Kubernetes auth reviews
# client tokens through the API server), a ConfigMap with the server
# configuration, and a cert-manager chain: a self-signed Issuer, a CA
# Certificate, a CA Issuer, and the server Certificate, whose Secret
# `<instance>-tls` carries the CA as `ca.crt`. OpenBao reloads a renewed
# server certificate itself (`tls_auto_reload`). With the default seal it
# also installs the reconcile Job, its ServiceAccount, and its ConfigMap.
#
# Dependencies:
#   certManager (required)     a managed cert-manager instance, for the
#                              Issuer and Certificate handles.
#   unsealKey (required with seal.type = "static", the default)
#                              a secret with key `key`: a 32-byte AES key,
#                              raw, hex (64 characters), or base64 (44, or
#                              43 unpadded URL-safe), with no trailing
#                              newline (`openssl rand -hex 32 | tr -d '\n'`).
#   storageClasses (optional)  the class of the volumes when
#                              `storage.storageClassName` is unset.
#
# Minimal instance (`clusters/test-openbao.nix` evaluates this shape with
# `stringData`):
#
#   instances.secrets = {
#     openbao.package = packages.openbao;
#     openbao-unseal = {
#       package = packages.secret;
#       aliases = [ "unsealKey" ];
#       config.source = ./secrets/openbao-unseal.sops.yaml;
#       config.keys = [ "key" ];
#       config.hash = "...";
#     };
#   };
#
# Unseal. With `seal.type = "static"` OpenBao unseals itself on every start
# with the key in `unsealKey`. Anyone who can read that Secret and a Raft
# volume can decrypt the data, so protection at rest is no stronger than
# the RBAC on Secrets in this namespace and the cluster's etcd encryption.
# `seal.type = "shamir"` keeps the unseal keys out of the cluster: a person
# runs `bao operator init` once and `bao operator unseal` on every pod after
# each start, and a deploy waits until they do. Transit and cloud KMS seals
# are not supported.
#
# Initialization. With the static seal, pod 0 initializes the cluster on its
# first start (OpenBao's declarative self-initialization). It enables
# Kubernetes auth and creates the policy and role `kix-reconcile`, bound
# only to the reconcile Job's ServiceAccount. The root token is revoked
# after that and no recovery keys exist. On every change to `policies`,
# `kubernetesAuth.roles`, or `secretsEngines`, the reconcile Job logs in
# through that role and writes them. It creates and updates and never
# deletes; its log lists the policies and roles OpenBao holds that are not
# declared. A secrets engine that already exists is left as it is. The Job
# can write any policy, its own included, so its ServiceAccount is as
# powerful as a root token: anyone who can run a pod under it in this
# namespace can take over OpenBao. People get access through a declared
# role and policy. With `seal.type = "shamir"` nothing is initialized, no
# Job runs, and the three options must stay empty.
#
# Replicas follow the cluster's availability level: one at `none`, three
# from `pod` up (two would lose quorum with either pod). Pods start in order
# and join pod 0 through `retry_join` over the headless Service. Standbys
# forward requests to the active pod, so the Service selects every pod.
# Scaling down leaves the removed pods in the Raft configuration until
# `bao operator raft remove-peer` removes them. Pod 0 started on an empty
# volume skips self-initialization and joins its peers when one of them
# answers within five seconds and reports an initialized cluster.
#
# `out`:
#   url, fqdn, port   the Service, as `https://<fqdn>:8200`.
#   caSecret          the Secret whose `ca.crt` signs the server certificate.
#   externalSecretsProvider scope { serviceAccount; role; mount; }
#       Returns `{ vault = ...; }` for the `spec.provider` of a
#       ClusterSecretStore built with external-secrets'
#       `out.mkClusterSecretStore`: the server, the CA from `caSecret`, the
#       mount `mount` as `path` with its KV version, and Kubernetes auth as
#       role `role` with a token of `serviceAccount` (a ServiceAccount
#       resource in the caller's scope). It refuses a role that is not
#       declared or that does not bind that ServiceAccount and namespace,
#       and a mount that is not a declared `kv` secrets engine. The store
#       is ordered after the reconcile Job. A namespaced SecretStore cannot
#       read the CA Secret from this namespace; set the ClusterSecretStore's
#       `conditions` to limit the namespaces that use it.
#
# Network policy: an intent opens egress to the API server for the server
# pods, for token reviews. Kix derives no policy between the
# external-secrets controller and OpenBao, because the address reaches the
# controller through a ClusterSecretStore. Under default deny, add policies
# (`namespaces.<ns>.networkPolicies`) that admit the controller's pods to
# port 8200 of this instance and let them leave their own namespace for it.
#
# Escape hatches: `settings` for server configuration keys the package does
# not set, `env`, and the instance's `partsOverlays`. Metrics, audit
# devices, and the web UI are not configured.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "2.7.1";
  # The oldest release that reads every server option the package writes.
  minVersion = "2.7";
  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "openbao ${ns}/${name}";

  ports = {
    api = 8200;
    cluster = 8201;
  };

  # The role and policy self-initialization creates for the reconcile Job.
  reconcileRole = "kix-reconcile";

  dirs = {
    config = "/openbao/kix";
    init = "/openbao/init";
    tls = "/openbao/tls";
    unseal = "/openbao/unseal";
    data = "/openbao/data";
  };

  labelsFor = component: scope.selectorLabels // { "app.kubernetes.io/component" = component; };

  # The image's `openbao` user and group.
  uid = 100;
  gid = 1000;

  # Names OpenBao accepts that are also valid ConfigMap keys, which the
  # reconcile Job reads them from.
  validName = n: builtins.match "[A-Za-z0-9][A-Za-z0-9_.-]*" n != null;
  validMountPath = p: builtins.match "[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*" p != null;
  # Paths OpenBao serves itself, which no secrets engine may take.
  reservedMount =
    p:
    builtins.any (r: p == r || lib.hasPrefix "${r}/" p) [
      "sys"
      "auth"
      "identity"
      "cubbyhole"
    ];

  # `ttl`-style options and any other role field pass through as written.
  roleType = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;
    options = {
      bound_service_account_names = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.nonEmptyStr;
        example = [ "external-secrets" ];
        description = "ServiceAccounts that may log in with this role; `*` allows any.";
      };
      bound_service_account_namespaces = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.nonEmptyStr;
        example = [ "app" ];
        description = "Namespaces of those ServiceAccounts; `*` allows any.";
      };
      token_policies = lib.mkOption {
        type = lib.types.listOf lib.types.nonEmptyStr;
        default = [ ];
        description = "Policies of the tokens this role issues: names from `policies`, or `default`.";
      };
    };
  };

  engineType = lib.types.submodule {
    freeformType = lib.types.attrsOf lib.types.anything;
    options = {
      type = lib.mkOption {
        type = lib.types.nonEmptyStr;
        example = "kv";
        description = "The secrets engine type, such as `kv` or `pki`.";
      };
      options = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          version = "2";
        };
        description = "Engine options; a `kv` engine takes `version`.";
      };
    };
  };

  # The KV version external-secrets' vault provider expects for an engine.
  kvVersion = engine: if (engine.options.version or "1") == "2" then "v2" else "v1";

  # Policy of the reconcile Job, from the declared engine paths.
  reconcilePolicy =
    enginePaths:
    lib.concatStringsSep "\n" (
      [
        "# Write every declared policy, this one included, and list them for the drift report."
        ''path "sys/policies/acl/*" { capabilities = ["create", "read", "update", "list"] }''
        "# Write every declared Kubernetes auth role, and list them for the drift report."
        ''path "auth/kubernetes/role/*" { capabilities = ["create", "read", "update", "list"] }''
      ]
      ++ lib.optional (enginePaths != [ ]) "# Read and enable each declared secrets engine."
      ++ map (p: ''path "sys/mounts/${p}" { capabilities = ["create", "read", "update"] }'') enginePaths
    )
    + "\n";
in
{
  meta = {
    version = release;
    description = "OpenBao, a secrets manager, on integrated Raft storage with Kubernetes auth";
    owner = "platform";
    lifecycle = "stateful";
    defaultAliases = [ "openbao" ];
    network.intents.tokenReview.egress = [ { to = "apiserver"; } ];
  };

  assertions =
    { config, ... }:
    let
      policyNames = builtins.attrNames config.policies;
      roleNames = builtins.attrNames config.kubernetesAuth.roles;
      enginePaths = builtins.attrNames config.secretsEngines;
      bad = pred: names: builtins.filter (n: !(pred n)) names;
      show = names: lib.concatMapStringsSep ", " builtins.toJSON names;
      unknownPolicies = lib.concatLists (
        lib.mapAttrsToList (
          role: r:
          map (p: "${role} -> ${p}") (
            builtins.filter (p: p != "default" && !(config.policies ? ${p})) r.token_policies
          )
        ) config.kubernetesAuth.roles
      );
      declared = policyNames ++ roleNames ++ enginePaths;
      tagVersion = builtins.match "v?([0-9]+\\.[0-9]+)(\\..*)?" config.image.tag;
    in
    [
      {
        assertion =
          tagVersion == null || builtins.compareVersions (builtins.head tagVersion) minVersion >= 0;
        message = "image.tag \"${config.image.tag}\" is older than OpenBao ${minVersion}, which added the tls_auto_reload listener option the package sets. Remove image.tag or set a ${minVersion} or later tag.";
      }
      {
        assertion = config.seal.type == "static" || declared == [ ];
        message = "seal.type is \"shamir\", and policies, kubernetesAuth.roles, or secretsEngines declare ${show declared}. They are applied by a Job that logs in through the role self-initialization creates, and self-initialization needs the static seal. Remove them and configure OpenBao through its API, or set seal.type = \"static\".";
      }
      {
        assertion = bad validName policyNames == [ ];
        message = "policies has the names ${show (bad validName policyNames)}; a name starts with a letter or digit and holds only letters, digits, '_', '.', and '-'.";
      }
      {
        assertion = !(builtins.elem reconcileRole policyNames) && !(config.policies ? root);
        message = "policies declares \"root\" or \"${reconcileRole}\"; OpenBao owns root, and ${reconcileRole} is the reconcile Job's own policy. Rename the policy.";
      }
      {
        assertion = bad validName roleNames == [ ];
        message = "kubernetesAuth.roles has the names ${show (bad validName roleNames)}; a name starts with a letter or digit and holds only letters, digits, '_', '.', and '-'.";
      }
      {
        assertion = !(builtins.elem reconcileRole roleNames);
        message = "kubernetesAuth.roles declares \"${reconcileRole}\", the reconcile Job's own role. Rename the role.";
      }
      {
        assertion = unknownPolicies == [ ];
        message = "kubernetesAuth.roles name policies that policies does not declare: ${lib.concatStringsSep ", " unknownPolicies}. Declare them in policies, or use \"default\".";
      }
      {
        assertion =
          bad validMountPath enginePaths == [ ] && builtins.filter reservedMount enginePaths == [ ];
        message = "secretsEngines has the paths ${
          show (bad validMountPath enginePaths ++ builtins.filter reservedMount enginePaths)
        }; a path is segments of letters, digits, '_', '.', and '-' joined by '/', without a leading or trailing '/', outside sys/, auth/, identity/, and cubbyhole/.";
      }
    ];

  options = {
    image = kix.options.image {
      repository = "quay.io/openbao/openbao";
      tag = release;
      digest = "sha256:6d2b93856e3fcf7b18ad855a0b51eaba474dc8b79cf554379ea32034797d2acf";
      description = "Image of the server and of the reconcile Job, which runs its `bao` CLI.";
    };

    resources = kix.options.resources {
      requests = {
        cpu = "250m";
        memory = "256Mi";
      };
      limits = {
        cpu = "2";
        memory = "1Gi";
      };
    };

    seal = {
      type = lib.mkOption {
        type = lib.types.enum [
          "static"
          "shamir"
        ];
        default = "static";
        description = ''
          `static`: OpenBao unseals itself with the key from the `unsealKey`
          dependency and initializes itself on its first start. Anyone who
          can read that Secret and a volume can decrypt the data.
          `shamir`: a person initializes OpenBao and unseals every pod after
          each start; `policies`, `kubernetesAuth.roles`, and
          `secretsEngines` must be empty.
        '';
      };
      keyId = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_.-]+";
        default = "1";
        description = "Identifier OpenBao records with data sealed by the static key (`current_key_id`). Keep it while the key is the same; the package does not rotate keys.";
      };
    };

    storage = {
      size = lib.mkOption {
        type = kix.types.quantity;
        default = "10Gi";
        description = "Volume requested for each pod, holding the Raft log and snapshots.";
      };
      storageClassName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "StorageClass of the volumes. Null takes the class from the storageClasses dependency, or with none the cluster default.";
      };
    };

    policies = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      example = {
        app-read = ''path "secret/data/app/*" { capabilities = ["read"] }'';
      };
      description = "ACL policies in HCL, by name, written by the reconcile Job. `root` and `kix-reconcile` are refused. A policy removed here stays in OpenBao, and the Job's log lists it.";
    };

    kubernetesAuth.roles = lib.mkOption {
      type = lib.types.attrsOf roleType;
      default = { };
      example = {
        external-secrets = {
          bound_service_account_names = [ "app-store" ];
          bound_service_account_namespaces = [ "app" ];
          token_policies = [ "app-read" ];
        };
      };
      description = "Roles of the Kubernetes auth method at `auth/kubernetes`, by name, as the body of `auth/kubernetes/role/<name>`, written by the reconcile Job. `kix-reconcile` is refused. A role removed here stays in OpenBao, and the Job's log lists it.";
    };

    secretsEngines = lib.mkOption {
      type = lib.types.attrsOf engineType;
      default = { };
      example = {
        secret = {
          type = "kv";
          options.version = "2";
        };
      };
      description = "Secrets engines by mount path, as the body of `sys/mounts/<path>`. The reconcile Job enables a missing engine and leaves an existing one of the same type unchanged; one of another type fails the Job.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        log_level = "debug";
      };
      description = "Server configuration keys merged over the package's, as JSON. The package sets `listener`, `storage`, `seal`, `api_addr`, `cluster_addr`, and `initialize`, and refuses them here.";
    };

    env = kix.options.env // {
      description = "Extra environment variables of the server container. The addresses, Raft, and seal variables are set by the package.";
    };
  };

  build =
    {
      self,
      config,
      clusterConfig,
      certManager,
      unsealKey ? null,
      storageClasses ? null,
      ...
    }:
    let
      selfInit = config.seal.type == "static";

      replicas = kix.availability.pick availability {
        none = 1;
        pod = 3;
        node = 3;
        zone = 3;
      };

      certCrds =
        certManager.out.crds
          or (throw "${who}: the certManager dependency has no out.crds, as with an import. Wire a managed cert-manager instance with deps.certManager = ref.<namespace>.<instance>.");

      unseal =
        if !selfInit then
          null
        else if unsealKey == null then
          throw "${who}: seal.type is \"static\" and there is no unsealKey dependency. Add a secret aliased unsealKey with key \"key\", a 32-byte key (`openssl rand -hex 32 | tr -d '\\n'`), or set seal.type = \"shamir\" to initialize and unseal OpenBao by hand."
        else
          kix.checkSecretKeys {
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

      headlessName = "${name}-headless";
      tlsSecretName = "${name}-tls";
      caSecretName = "${name}-ca";
      tlsSecret = kix.untrackedRef {
        kind = "Secret";
        name = tlsSecretName;
        by = self.serverCertificate;
      };

      headlessFqdn = self.headlessService.out.fqdn;
      podUrl = i: "https://${name}-${toString i}.${headlessFqdn}:${toString ports.api}";
      serviceUrl = self.service.out.url { scheme = "https"; };

      enginePaths = builtins.attrNames config.secretsEngines;

      # Top-level keys the package writes, with what derives each one.
      ownedSettings = {
        listener = "the Service, the probes, and the certificate paths";
        storage = "the volumes and the Raft join addresses of the StatefulSet";
        seal = "seal.type and seal.keyId";
        api_addr = "BAO_API_ADDR, derived from each pod's name";
        cluster_addr = "BAO_CLUSTER_ADDR, derived from each pod's name";
        initialize = "the self-initialization the reconcile Job depends on";
      };
      settingsOwned = builtins.filter (k: ownedSettings ? ${k}) (builtins.attrNames config.settings);
      serverConfig =
        if settingsOwned != [ ] then
          throw "${who}: settings sets ${lib.concatStringsSep ", " settingsOwned}, which the package sets from ${
            lib.concatMapStringsSep "; " (k: ownedSettings.${k}) settingsOwned
          }. Remove ${if builtins.length settingsOwned == 1 then "it" else "them"} from settings."
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
        ];
        storage.raft = {
          path = dirs.data;
          retry_join = map (i: {
            leader_api_addr = podUrl i;
            leader_ca_cert_file = "${dirs.tls}/ca.crt";
          }) (lib.range 0 (replicas - 1));
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
          inherit who;
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

      # Data the reconcile Job reads; see reconcile.sh.
      nameList = names: lib.concatMapStrings (n: "${n}\n") names;
      indexedEngines = lib.imap0 (i: path: {
        inherit i path;
        engine = config.secretsEngines.${path};
      }) enginePaths;
      reconcileData = {
        "reconcile.sh" = builtins.readFile ./reconcile.sh;
        "reconcile.hcl" = reconcilePolicy enginePaths;
        "policies.txt" = nameList (builtins.attrNames config.policies);
        "roles.txt" = nameList (builtins.attrNames config.kubernetesAuth.roles);
        "mounts.txt" = lib.concatMapStrings (
          e: "${toString e.i} ${e.path} ${e.engine.type}\n"
        ) indexedEngines;
      }
      // lib.mapAttrs' (n: text: lib.nameValuePair "policy.${n}.hcl" text) config.policies
      // lib.mapAttrs' (
        n: role: lib.nameValuePair "role.${n}.json" (builtins.toJSON role)
      ) config.kubernetesAuth.roles
      // builtins.listToAttrs (
        map (e: lib.nameValuePair "mount.${toString e.i}.json" (builtins.toJSON e.engine)) indexedEngines
      );

      containerSecurity = {
        runAsNonRoot = true;
        runAsUser = uid;
        runAsGroup = gid;
        allowPrivilegeEscalation = false;
        capabilities.drop = [ "ALL" ];
        readOnlyRootFilesystem = true;
      };

      # A role name carrying the reconcile Job's context, so a store that
      # names it is applied after the Job wrote the role.
      afterReconcile = s: if selfInit then lib.addContextFrom self.reconcile.out.name s else s;

      externalSecretsProvider =
        consumerScope:
        {
          serviceAccount,
          role,
          mount,
        }:
        let
          consumerNs = consumerScope.namespaceName;
          saName = serviceAccount.out.name;
          plainSa = builtins.unsafeDiscardStringContext saName;
          r = config.kubernetesAuth.roles.${role} or null;
          engine = config.secretsEngines.${mount} or null;
          binds = field: value: builtins.elem value r.${field} || builtins.elem "*" r.${field};
          what = "out.externalSecretsProvider for ServiceAccount ${consumerNs}/${plainSa}";
        in
        if r == null then
          throw "${who}: ${what} names role \"${role}\", which kubernetesAuth.roles does not declare (declared: ${lib.concatStringsSep ", " (builtins.attrNames config.kubernetesAuth.roles)}). Declare it on the openbao instance."
        else if !(binds "bound_service_account_names" plainSa) then
          throw "${who}: ${what}: role \"${role}\" binds the ServiceAccounts ${builtins.toJSON r.bound_service_account_names}, not ${plainSa}, so OpenBao would refuse the login. Add ${plainSa} to kubernetesAuth.roles.${role}.bound_service_account_names."
        else if !(binds "bound_service_account_namespaces" consumerNs) then
          throw "${who}: ${what}: role \"${role}\" binds the namespaces ${builtins.toJSON r.bound_service_account_namespaces}, not ${consumerNs}, so OpenBao would refuse the login. Add ${consumerNs} to kubernetesAuth.roles.${role}.bound_service_account_namespaces."
        else if engine == null then
          throw "${who}: ${what} names mount \"${mount}\", which secretsEngines does not declare. Declare secretsEngines.${mount} = { type = \"kv\"; options.version = \"2\"; } on the openbao instance."
        else if engine.type != "kv" then
          throw "${who}: ${what} names mount \"${mount}\", a ${engine.type} engine; external-secrets' vault provider reads kv engines. Name a kv engine from secretsEngines."
        else
          {
            vault = {
              server = serviceUrl;
              path = mount;
              version = kvVersion engine;
              caProvider = {
                type = "Secret";
                name = tlsSecret;
                key = "ca.crt";
                namespace = ns;
              };
              auth.kubernetes = {
                mountPath = "kubernetes";
                role = afterReconcile role;
                serviceAccountRef = {
                  name = saName;
                  namespace = consumerNs;
                };
              };
            };
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
                "checksum/config" = self.configMap.out.identityHash;
              }
              # A secret-ref has no identityHash. The key is read at start.
              // lib.optionalAttrs (unseal != null && unseal.out ? identityHash) {
                "checksum/unsealKey" = unseal.out.identityHash;
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
                    ];
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
                    secret.secretName = tlsSecret;
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

      reconcileServiceAccount =
        if selfInit then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "${name}-reconcile";
          }
        else
          null;

      reconcileConfigMap =
        if selfInit then
          scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            name = "${name}-reconcile";
            data = reconcileData;
          }
        else
          null;

      reconcile =
        if selfInit then
          {
            name = "${name}-reconcile";
            labels = labelsFor "reconcile";
            annotations.${kix.keys.rerun} = kix.keyValues.rerunOnChange;
            requires = [ self.statefulSet ];
            spec = {
              # The container restarts with the kubelet's back-off, so six
              # restarts cover a few minutes of an OpenBao that is still
              # electing a leader.
              backoffLimit = 6;
              template = {
                metadata = {
                  labels = labelsFor "reconcile";
                  annotations."checksum/reconcile" = self.reconcileConfigMap.out.identityHash;
                };
                spec = {
                  restartPolicy = "OnFailure";
                  serviceAccount = self.reconcileServiceAccount;
                  securityContext = {
                    runAsNonRoot = true;
                    runAsUser = uid;
                    runAsGroup = gid;
                    seccompProfile.type = "RuntimeDefault";
                  };
                  containers = [
                    {
                      name = "reconcile";
                      image = kix.image.ref config.image;
                      imagePullPolicy = config.image.pullPolicy;
                      command = [
                        "/bin/sh"
                        "/reconcile/reconcile.sh"
                      ];
                      workingDir = "/reconcile";
                      env = kix.mkEnvVars {
                        BAO_ADDR = serviceUrl;
                        BAO_CACERT = "${dirs.tls}/ca.crt";
                        RECONCILE_ROLE = reconcileRole;
                        HOME = "/tmp";
                      };
                      resources = {
                        requests = {
                          cpu = "10m";
                          memory = "32Mi";
                        };
                        limits = {
                          cpu = "200m";
                          memory = "128Mi";
                        };
                      };
                      securityContext = containerSecurity;
                      volumeMounts = [
                        {
                          name = "ca";
                          mountPath = dirs.tls;
                          readOnly = true;
                        }
                      ];
                    }
                  ];
                  volumes = [
                    {
                      name = "ca";
                      secret = {
                        secretName = tlsSecret;
                        items = [
                          {
                            key = "ca.crt";
                            path = "ca.crt";
                          }
                        ];
                      };
                    }
                  ];
                };
              };
            };
          }
          |> kix.withMounts [
            (kix.mount.configMap self.reconcileConfigMap {
              name = "reconcile";
              mountPath = "/reconcile";
              readOnly = true;
            })
            (kix.mount.emptyDir {
              name = "tmp";
              mountPath = "/tmp";
            })
          ]
          |> scope.mkJob
        else
          null;

      root = {
        resource = self.service;
        requires = builtins.filter (r: r != null) [
          self.headlessService
          self.authDelegator
          self.reconcile
        ];
        out = {
          url = serviceUrl;
          fqdn = self.service.out.fqdn;
          port = toString ports.api;
          caSecret = tlsSecret;
          inherit externalSecretsProvider;
        };
      };
    };
}
