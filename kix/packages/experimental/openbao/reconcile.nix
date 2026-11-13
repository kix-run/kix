# OpenBao reconcile Job (policies, Kubernetes auth roles, and secrets engines)
# and root outputs.

{
  self,
  config,
  scope,
  lib,
  kix,
  ...
}:

let
  c = import ./common.nix { inherit lib kix scope; };
  inherit (c)
    name
    ns
    ports
    reconcileRole
    dirs
    labelsFor
    uid
    gid
    containerSecurity
    kvVersion
    reconcilePolicy
    ;

  selfInit = config.seal.type == "static";
  enginePaths = builtins.attrNames config.secretsEngines;
  serviceUrl = c.serviceUrl self;
  tlsSecret = c.tlsSecret self;
  tlsSecretElsewhere = c.tlsSecretElsewhere self;

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
      scope.fail {
        package = "openbao";
        option = "config.kubernetesAuth.roles";
        message = "${what} names role \"${role}\", which kubernetesAuth.roles does not declare (declared: ${lib.concatStringsSep ", " (builtins.attrNames config.kubernetesAuth.roles)}).";
        fix = "Declare role \"${role}\" on the openbao instance.";
      }
    else if !(binds "bound_service_account_names" plainSa) then
      scope.fail {
        package = "openbao";
        option = "config.kubernetesAuth.roles.${role}.bound_service_account_names";
        message = "${what}: role \"${role}\" binds the ServiceAccounts ${builtins.toJSON r.bound_service_account_names}, not ${plainSa}, so OpenBao would refuse the login.";
        fix = "Add ${plainSa} to kubernetesAuth.roles.${role}.bound_service_account_names.";
      }
    else if !(binds "bound_service_account_namespaces" consumerNs) then
      scope.fail {
        package = "openbao";
        option = "config.kubernetesAuth.roles.${role}.bound_service_account_namespaces";
        message = "${what}: role \"${role}\" binds the namespaces ${builtins.toJSON r.bound_service_account_namespaces}, not ${consumerNs}, so OpenBao would refuse the login.";
        fix = "Add ${consumerNs} to kubernetesAuth.roles.${role}.bound_service_account_namespaces.";
      }
    else if engine == null then
      scope.fail {
        package = "openbao";
        option = "config.secretsEngines";
        message = "${what} names mount \"${mount}\", which secretsEngines does not declare.";
        fix = "Declare secretsEngines.${mount} = { type = \"kv\"; options.version = \"2\"; } on the openbao instance.";
      }
    else if engine.type != "kv" then
      scope.fail {
        package = "openbao";
        option = "config.secretsEngines";
        message = "${what} names mount \"${mount}\", a ${engine.type} engine; external-secrets' vault provider reads kv engines.";
        fix = "Name a kv engine from secretsEngines.";
      }
    else
      {
        vault = {
          server = serviceUrl;
          path = mount;
          version = kvVersion engine;
          caProvider = {
            type = "Secret";
            name = tlsSecretElsewhere;
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
              annotations."checksum/reconcile" = self.reconcileConfigMap.out.contentHash;
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
      self.metricsService
    ];
    out = {
      url = serviceUrl;
      fqdn = self.service.out.fqdn;
      port = toString ports.api;
      caSecret = tlsSecretElsewhere;
      inherit externalSecretsProvider;
      version = kix.image.version config.image;
    };
  };
}
