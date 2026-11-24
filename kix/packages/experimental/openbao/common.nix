# Shared constants, option types, and helpers for the OpenBao package.

{
  lib,
  kix,
  scope,
}:

rec {
  release = "2.7.3";
  # The oldest release that reads every server option the package writes.
  minVersion = "2.7";

  name = scope.instanceName;
  ns = scope.namespaceName;

  ports = {
    api = 8200;
    cluster = 8201;
    metrics = 8202;
  };

  # The metrics Service, whose name the alerts select on.
  metricsServiceName = "${name}-metrics";

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

  containerSecurity = {
    runAsNonRoot = true;
    runAsUser = uid;
    runAsGroup = gid;
    allowPrivilegeEscalation = false;
    capabilities.drop = [ "ALL" ];
    readOnlyRootFilesystem = true;
  };

  headlessName = "${name}-headless";
  tlsSecretName = "${name}-tls";
  caSecretName = "${name}-ca";

  tlsSecret =
    self:
    kix.untrackedRef {
      kind = "Secret";
      name = tlsSecretName;
      by = self.serverCertificate;
    };

  # The same Secret for a resource in another namespace. The deploy looks
  # up an untrackedRef in the referring manifest's namespace, so a
  # ClusterSecretStore or another namespace's SecretStore would wait for
  # a Secret that is never there. The Certificate is named like its
  # Secret, and its out.name makes the reader wait until it is Ready.
  tlsSecretElsewhere = self: self.serverCertificate.out.name;

  serviceUrl = self: self.service.out.url { scheme = "https"; };

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
        ''path "sys/policies/acl/*" { capabilities = ["create", "update", "list"] }''
        "# Write every declared Kubernetes auth role, and list them for the drift report."
        ''path "auth/kubernetes/role/*" { capabilities = ["create", "update", "list"] }''
      ]
      ++ lib.optional (enginePaths != [ ]) "# Read and enable each declared secrets engine."
      ++ map (p: ''path "sys/mounts/${p}" { capabilities = ["create", "read", "update"] }'') enginePaths
    )
    + "\n";
}
