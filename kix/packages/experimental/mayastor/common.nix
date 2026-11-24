# Values the mayastor build files share: the release, names and labels, the
# addresses components dial, and the helpers for images, flags, env, wait
# probes, and placement.
{
  lib,
  kix,
  scope,
}:

rec {
  # meta.version, the release check on each image tag, and the DiskPool CRD
  # version and RBAC in this package are written for this release.
  release = "2.12.2";

  name = scope.instanceName;
  ns = scope.namespaceName;

  # Each workload selects on its own component, so no selector claims
  # another component's pods.
  componentLabels = component: scope.selectorLabels // { "app.kubernetes.io/component" = component; };

  # io-engine's config file and its NVMe reservation state
  # (persist-through-power-loss) live here on each io-engine node. Upstream
  # uses the Helm release name, so an instance named like a release finds
  # the same directory.
  hostDir = "/var/local/${name}";

  # The Mayastor images are published for amd64 only.
  amd64 = {
    "kubernetes.io/arch" = "amd64";
  };

  # The labels of the nodes that run io-engine: `ioEngine.nodeSelector`, or
  # upstream's engine label when it is null.
  defaultIoEngineLabels = {
    "openebs.io/engine" = "mayastor";
  };
  ioEngineLabels =
    config:
    if config.ioEngine.nodeSelector == null then
      defaultIoEngineLabels
    else
      config.ioEngine.nodeSelector;

  # The poolEncryptionKey dependency with its key checked, or null when it
  # is not wired.
  poolKey =
    dep:
    kix.contracts.secret.helpers.use {
      inherit scope dep;
      arg = "poolEncryptionKey";
      keys = [ "encryption_parameters" ];
    };

  # Upstream's tolerations on the control plane: move off a lost node after
  # 5 seconds instead of the default 300.
  controlPlaneTolerations =
    map
      (key: {
        inherit key;
        operator = "Exists";
        effect = "NoExecute";
        tolerationSeconds = 5;
      })
      [
        "node.kubernetes.io/unreachable"
        "node.kubernetes.io/not-ready"
      ];

  # The addresses components dial. Each is built from a Service's
  # `out.fqdn` or `out.url`, which carry the endpoint that network policy
  # and ordering derive from. The binaries take an https URL for gRPC
  # endpoints whether or not TLS is on.
  endpoints = self: {
    etcdStore = "${self.etcdService.out.fqdn}:2379";
    etcdUrl = self.etcdService.out.url { port = 2379; };
    coreGrpc = self.agentCoreService.out.url {
      scheme = "https";
      port = 50051;
    };
    clusterAgent = self.agentCoreService.out.url {
      scheme = "https";
      port = 50052;
    };
    rest = self.apiRestService.out.url { port = 8081; };
  };

  # An init container that waits until `host` accepts connections on
  # `port`. Each container waits only for the Service it dials: a wait on
  # another Service would add a network-policy allow that exists only for
  # the wait. `trap` makes the shell exit on SIGTERM, which it ignores as
  # PID 1.
  waitFor = config: what: host: port: {
    name = "wait-${what}";
    image = kix.image.ref config.init.image;
    imagePullPolicy = config.init.image.pullPolicy;
    command = [
      "sh"
      "-ec"
      "trap 'exit 1' TERM; until nc -vzw 5 ${host} ${toString port}; do echo waiting for ${what}; sleep 1; done"
    ];
    resources = initResources;
    securityContext.readOnlyRootFilesystem = true;
  };

  initResources = {
    requests = {
      cpu = "10m";
      memory = "16Mi";
    };
    limits = {
      cpu = "50m";
      memory = "32Mi";
    };
  };

  # Package defaults for upstream tunables that `extraArgs` may replace. The
  # binaries refuse a single-value flag given twice, so a default is
  # dropped when `extraArgs` sets the same flag (`flag` or `flag=...`).
  dropOverridden =
    defaults: extraArgs:
    builtins.filter (
      d:
      let
        flag = builtins.head (lib.splitString "=" d);
      in
      !(builtins.any (a: a == flag || lib.hasPrefix "${flag}=" a) extraArgs)
    ) defaults;

  # A component's flags: the package's owned flags, the tunable defaults
  # `extraArgs` does not replace, then `extraArgs`. `owned` maps each owned
  # flag to the reason shown when `extraArgs` sets it.
  args =
    {
      option,
      base,
      owned,
      tunables ? [ ],
    }:
    extraArgs:
    base
    ++ dropOverridden tunables extraArgs
    ++ kix.guardArgs {
      inherit scope option owned;
    } extraArgs;

  fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };

  # A component's env: `defaults` the instance may override or remove,
  # then the instance's `env`, then the variables the package owns.
  # `option` is the instance's env option, which the refusal names.
  env =
    {
      option,
      defaults ? { },
      owned ? { },
    }:
    instanceEnv:
    kix.mkEnvVars (
      kix.mergeEnv {
        inherit scope option defaults;
        owned = lib.optional (owned != { }) {
          vars = owned;
          from = "the pod's Downward API fields, which the package's flags and the program read";
        };
      } instanceEnv
    );
}
