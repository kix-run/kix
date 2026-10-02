# tailscale: the Tailscale Kubernetes operator, which puts Services and
# Ingresses on a tailnet and runs subnet routers, egress proxies, and API
# server proxies from tailscale.com custom resources.
#
# The package renders the operator, its RBAC, the eight tailscale.com custom
# resource definitions, IngressClass `tailscale`, and the network policies
# for the pods the operator creates. The operator creates its proxies, the
# DNSConfig nameserver, and Recorder pods in this instance's namespace; the
# proxies run privileged.
#
# A cluster runs one instance: the custom resource definitions are
# cluster-wide, the operator serves loadBalancerClass `tailscale` by that
# literal name (cmd/k8s-operator/svc.go), and its DNS-record handler for
# Ingresses matches the class name `tailscale` literally
# (dnsRecordsReconcilerIngressHandler in cmd/k8s-operator/operator.go).
# `conflictsWith` refuses a second instance by alias and `annotationDomains`
# whatever its aliases. The proxies' ServiceAccount is named `proxies`
# because the operator's proxy template names it.
#
# Tailscale setup, before the first deploy (Tailscale's "Install the
# Kubernetes operator" guide):
#   - In the tailnet policy file, add the tags `tag:k8s-operator` and
#     `tag:k8s`, with `tag:k8s-operator` an owner of `tag:k8s`.
#   - Create an OAuth client with write scope on General/Services,
#     Devices/Core, and Keys/Auth Keys, tagged `tag:k8s-operator`.
#   - Store its ID and secret under the keys `client_id` and
#     `client_secret` in a Secret in this namespace, and wire it as
#     `oauthCredentials`. A Secret created outside Kix:
#
#       oauth-credentials = {
#         package = packages.secret-ref;
#         aliases = [ "oauthCredentials" ];
#         config.keys = [ "client_id" "client_secret" ];
#       };
#
#     A `packages.secret` with a `source` also works. Literal `stringData`
#     puts the client secret in the Nix store and the build output.
#
# Minimal instance, beside that Secret:
#
#   instances.tailscale.tailscale.package = packages.tailscale;
#
# DI deps:
#   oauthCredentials (required)  Secret with keys client_id and client_secret.
#   prometheus (optional)        metrics Service and ServiceMonitor.
#
# Network policy: the operator reaches Tailscale's control plane and DERP
# relays on TCP 443 and STUN on UDP 3478. With an enforcer, the package
# opens egress for the proxies (DNS, the API server, the cluster, and the
# internet), ingress from the cluster for egress proxies and the DNSConfig
# nameserver, and egress for Recorders. Proxies get no ingress from outside
# the cluster: they open their tailnet connections, the enforcer admits the
# replies, and a peer that cannot reach a proxy directly goes through DERP.
# A backend a proxy forwards to needs `out.mkBackendPolicy` (or
# `out.mkIngress`, which includes it).
#
# Known limits:
#   - No workload identity federation: `env.CLIENT_ID` is refused and the
#     operator gets no `serviceaccounts/token` permission, so a Tailnet
#     resource that authenticates that way does not work.
#   - No API server proxy in auth mode: `env.APISERVER_PROXY` is refused,
#     and out.mkProxyGroup builds a `kube-apiserver` ProxyGroup only with
#     `spec.kubeAPIServer.mode = "noauth"`.
#   - Not usable as the `ingress` dependency of `kix.expose`: a tailscale
#     Ingress takes its machine name from `tls[0].hosts[0]`, and the tailnet
#     name, and so the URL, is not in the build. Use out.mkIngress.
#   - The `proxies` ServiceAccount may read and change every Secret in this
#     namespace (upstream's proxy Role), including the OAuth client and any
#     Recorder S3 credentials. Keep other Secrets out of this namespace.
#   - Under default deny, a pod that calls an egress proxy (an ExternalName
#     Service the operator points at a proxy) gets no derived egress to the
#     proxy pod in this namespace, and no builder here opens it. The
#     client's package has to allow that egress itself.
#   - `labels."tailscale.com/proxy-class"` on an Ingress or Service and the
#     `tailscale.com/proxy-group` annotation take plain names. Kix neither
#     checks them nor orders the object after that ProxyClass or ProxyGroup.
#
# Escape hatches: `env` for the operator's own variables (owned ones are
# refused with the option that sets them); `partsOverlays`; full custom
# resource specs; `scope.mkCR tailscale.out.crds.<Kind>`.
#
# Exposes:
#   out.loadBalancerClass
#       "tailscale", with a dependency on the operator. A Service of type
#       LoadBalancer with this class goes on the tailnet. The cluster's
#       loadBalancer role does not apply to it, and derived policy gives it
#       no ingress from outside the cluster:
#
#         service = scope.mkResource { ...; spec = { type = "LoadBalancer";
#           loadBalancerClass = tailscale.out.loadBalancerClass; ... }; };
#         tailnetPolicy = tailscale.out.mkBackendPolicy scope { service = self.service; };
#
#   out.mkBackendPolicy scope { service; port ? null; name ? service.name; }
#       A policy `<name>-from-tailscale` in the caller's namespace that
#       admits the proxies to the Service's pods on the pod port behind
#       `port` (a Service port number or name; every port when null).
#       Null when the namespace has no enforcer. Refuses a Service without
#       a selector. A second policy on the same Service needs its own
#       `name`.
#   out.mkIngress scope { name; service; port ? null; hostname ? name;
#                         annotations ? { }; labels ? { }; spec ? { }; }
#       `{ ingress; policy; }`. Assign it to one part, which becomes a
#       folder of the two (a null policy is dropped). The Ingress
#       has class `tailscale`, `tls.hosts = [ hostname ]`, which makes the
#       machine `<hostname>.<tailnet>.ts.net`, and `service` as its default
#       backend. `spec` adds `rules[].http.paths`. The policy,
#       `<name>-ingress-from-tailscale`, covers the default backend and
#       every path to `service`; a path to another Service needs its own
#       `mkBackendPolicy`. `labels` carries `tailscale.com/proxy-class`,
#       `annotations` `tailscale.com/funnel` and `tailscale.com/proxy-group`.
#       Refuses a dotted hostname, `spec.tls`, `spec.ingressClassName`,
#       `spec.defaultBackend`, and `spec.rules[].host`.
#   out.mkConnector, out.mkProxyGroup scope { name; spec; }
#       Refuse a `spec.proxyClass` without a dependency: pass
#       `<ProxyClass>.out.name`, or `kix.untrackedRef "<name>"` for one Kix
#       does not build. mkProxyGroup also refuses a `kube-apiserver`
#       ProxyGroup unless `spec.kubeAPIServer.mode = "noauth"`: auth mode
#       needs a ServiceAccount and impersonation RBAC the package does not
#       create.
#   out.mkDNSConfig scope { spec ? { }; }
#       The cluster's one DNSConfig, named `ts-dns`, so a second one fails
#       the build. Defaults the nameserver image to
#       `operandImages.k8s-nameserver`.
#   out.mkRecorder scope { name; spec; }
#       Defaults the recorder image and pull policy to
#       `operandImages.tsrecorder`. The operator reads the S3 credentials
#       Secret from this instance's namespace (`out.podNamespace`), so a
#       Recorder that names one is built by an instance in that namespace,
#       and the builder refuses a Secret name without a dependency. Pass
#       the `out.name` of a Secret the caller builds or depends on, or
#       `kix.untrackedRef "<name>"` for a Secret there that Kix does not
#       build.
#   out.crds.{Connector,DNSConfig,PeerRelay,ProxyClass,ProxyGroup,
#             ProxyGroupPolicy,Recorder,Tailnet}
#       For `scope.mkCR`. A ProxyClass:
#
#         proxyClass = scope.mkCR tailscale.out.crds.ProxyClass {
#           name = "small";
#           spec.statefulSet.pod.tailscaleContainer.resources.requests.memory = "64Mi";
#         };
#
#   out.ingressClass       the IngressClass, for an Ingress built directly.
#   out.podSelector, out.podNamespace
#       Labels and namespace of every proxy this operator runs.
#   out.extraImages        the operand images, digest-pinned.
#
# root = the operator Deployment.

{
  scope,
  lib,
  kix,
}:
let
  # The upstream release: meta.version, image.tag, the CRD tag in
  # crds/sources.txt (checked by the tailscale-sources lib test), and the
  # rules in rbac.nix.
  release = "1.102.4";
  tag = "v${release}";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "tailscale ${ns}/${name}";

  # controller-runtime's metrics server. It opens only after the operator's
  # own tailnet node reaches Running, so it doubles as the readiness signal.
  metricsPort = 8080;

  # Multi-arch index digests at `tag`.
  operandDigests = {
    tailscale = "sha256:2667499ed87ae29218f292556ba062918402dd5e92e93637af14867e4df12dd3";
    k8s-proxy = "sha256:a43ae88f544dab66ffd690a9834ed38adf7cef39e9a4a6d0cbf0467ddaa02281";
    k8s-nameserver = "sha256:3676e2277ad16da948caee7952b2a27859a66b905edd981e1bb58b2626bc92a4";
    tsrecorder = "sha256:47b602ddee9e97d2060fb017496f7758551e7e619ebfd984e94fb8541f581aea";
  };
  # The operator sets the pull policy of the proxy and nameserver containers
  # itself.
  operatorPulled = [
    "tailscale"
    "k8s-proxy"
    "k8s-nameserver"
  ];

  rules = import ./rbac.nix { inherit (scope) rbac; };

  vendored = plural: (builtins.fromJSON (builtins.readFile ./crds/${plural}.tailscale.com.json)).spec;
  ready = type: {
    condition = {
      inherit type;
      status = "True";
    };
  };

  # Labels the operator puts on every proxy pod, and the label that says
  # which kind of object a proxy serves.
  managedLabels = {
    "tailscale.com/managed" = "true";
  };
  parentType = type: managedLabels // { "tailscale.com/parent-resource-type" = type; };

  # "v1.102.4" -> [ "1" "102" ".4" ]; null when the tag is not a version.
  versionParts = t: builtins.match "v?([0-9]+)\\.([0-9]+)(\\..*)?" t;
  releaseMinor = lib.take 2 (versionParts release);
  releaseMinorText = lib.concatStringsSep "." releaseMinor;

  # The operator's egress policy allows TCP 443 only, so a control server on
  # another port is unreachable.
  loginServerPattern = "https://[^/:]+(:443)?(/.*)?";

  declaredProxyClasses =
    config:
    let
      names = builtins.attrNames config.proxyClasses;
    in
    if names == [ ] then "none" else lib.concatStringsSep ", " names;

  fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };

  # A string carries context when it was read from a Kix resource's `out` or
  # from `kix.untrackedRef`.
  isTracked = v: builtins.isString v && builtins.hasContext v;
  trackedFix = "pass <resource>.out.name, which also orders the custom resource after it, or kix.untrackedRef \"<name>\" for an object Kix does not build.";

  # The prefix of an error raised by a builder in `out`, naming the
  # instance that called it.
  callSite =
    builder: consumerScope: subject:
    "${who}: ${builder} ${subject}, called by ${consumerScope.namespaceName}/${consumerScope.instanceName}";

  # Part folders drop entries keyed `root` or `meta`, so a ProxyClass or
  # Connector under either key would never be applied.
  reservedKeys = option: builder: keys: {
    assertion =
      !(builtins.any (k: builtins.elem k keys) [
        "root"
        "meta"
      ]);
    message = "${option} has an entry named root or meta. Kix drops parts with those names, so that object would not be applied. Use another name, or build it with ${builder} in a part of your own.";
  };
in
{
  meta = {
    version = release;
    description = "Tailscale Kubernetes operator: exposes Services and Ingresses on a tailnet and runs subnet routers, egress proxies, and API server proxies from tailscale.com resources";
    owner = "platform";
    defaultAliases = [ "tailscale" ];
    # One instance per cluster; see the header.
    conflictsWith = [ "cluster:tailscale" ];
    annotationDomains = [ "tailscale.com" ];
    # The proxy pods the operator creates in this namespace run privileged
    # (upstream's proxy template). The operator's own pod does not; the
    # grant is declared so that `architecture.unsafeGrants` lists it.
    podSecurity = "privileged";
    unsafe = [ "privileged" ];
    # The operator has no leader election, and two pods would share one
    # tailnet state Secret.
    availability.max = "none";
    # Control plane, API, and DERP on TCP 443, STUN on UDP 3478.
    # APISERVER_PROXY is refused, so the operator's own node carries no
    # proxied traffic.
    network.intents.tailnet.egress = [
      {
        to = "world";
        ports = [
          {
            port = 443;
            protocol = "TCP";
          }
          {
            port = 3478;
            protocol = "UDP";
          }
        ];
      }
    ];
    # Six of the vendored CRDs carry x-kubernetes-validations rules.
    k8s.minVersion = "1.25";
  };

  assertions =
    { config, ... }:
    let
      loginServer = config.env.OPERATOR_LOGIN_SERVER or null;
    in
    [
      {
        assertion = config.defaultProxyClass == null || config.proxyClasses ? ${config.defaultProxyClass};
        message = "defaultProxyClass = \"${toString config.defaultProxyClass}\" names no entry in proxyClasses (declared: ${declaredProxyClasses config}). The operator creates no proxies while their ProxyClass is missing. Declare proxyClasses.${toString config.defaultProxyClass}, or set defaultProxyClass = null.";
      }
      {
        assertion =
          !(builtins.isString loginServer) || builtins.match loginServerPattern loginServer != null;
        message = "env.OPERATOR_LOGIN_SERVER = \"${toString loginServer}\" is not an https URL on port 443 (${loginServerPattern}). The operator's egress policy allows TCP 443 and UDP 3478 only; serve the control server over https on 443.";
      }
      {
        assertion =
          versionParts config.image.tag != null && lib.take 2 (versionParts config.image.tag) == releaseMinor;
        message = "image.tag \"${config.image.tag}\" is not a ${releaseMinorText} release, and the CRDs under kix/packages/tailscale/crds and the rules in kix/packages/tailscale/rbac.nix come from ${release}. Remove image.tag or set a v${releaseMinorText} tag. To move to another release, change release in kix/packages/tailscale/default.nix and the tag in crds/sources.txt, run uv run scripts/vendor-crds.py tailscale, and compare rbac.nix with that release's operator-rbac.yaml and proxy-rbac.yaml.";
      }
      (reservedKeys "proxyClasses" "scope.mkCR tailscale.out.crds.ProxyClass" (
        builtins.attrNames config.proxyClasses
      ))
      (reservedKeys "connectors" "tailscale.out.mkConnector" (builtins.attrNames config.connectors))
    ]
    ++ map (n: {
      assertion = config.operandImages.${n}.pullPolicy == null;
      message = "operandImages.${n}.pullPolicy = \"${
        toString config.operandImages.${n}.pullPolicy
      }\" has no effect: the operator sets the pull policy of the containers it creates. ${
        if n == "k8s-nameserver" then
          "DNSConfig has no pull policy field; remove it."
        else
          "Set it per ProxyClass at spec.statefulSet.pod.tailscaleContainer.imagePullPolicy, and remove it here."
      }";
    }) operatorPulled;

  options = {
    image = kix.options.image {
      repository = "docker.io/tailscale/k8s-operator";
      inherit tag;
      digest = "sha256:3c8958c42fb3c46068e8553e11b944f2133b4671d4f36c86adc11f206746bf34";
      description = "Image of the operator. Its major.minor must match the vendored CRDs and RBAC. Each operand image defaults to this repository with its own last path segment (docker.io/tailscale/<name>) and to this tag.";
    };

    operandImages = {
      tailscale = kix.options.image {
        repository = "docker.io/tailscale/tailscale";
        inherit tag;
        digest = operandDigests.tailscale;
        tagText = "config.image.tag";
        pullPolicy = null;
        description = "Image of the proxies the operator creates (PROXY_IMAGE). Listed in out.extraImages. The operator sets their pull policy, so pullPolicy must stay null.";
      };
      k8s-proxy = kix.options.image {
        repository = "docker.io/tailscale/k8s-proxy";
        inherit tag;
        digest = operandDigests.k8s-proxy;
        tagText = "config.image.tag";
        pullPolicy = null;
        description = "Image of the kube-apiserver ProxyGroup proxies (K8S_PROXY_IMAGE). Listed in out.extraImages. The operator sets their pull policy, so pullPolicy must stay null.";
      };
      k8s-nameserver = kix.options.image {
        repository = "docker.io/tailscale/k8s-nameserver";
        inherit tag;
        digest = operandDigests.k8s-nameserver;
        tagText = "config.image.tag";
        pullPolicy = null;
        description = "Default nameserver image of out.mkDNSConfig. Listed in out.extraImages. DNSConfig has no pull policy field, so pullPolicy must stay null.";
      };
      tsrecorder = kix.options.image {
        repository = "docker.io/tailscale/tsrecorder";
        inherit tag;
        digest = operandDigests.tsrecorder;
        tagText = "config.image.tag";
        description = "Default image and pull policy of out.mkRecorder. Listed in out.extraImages.";
      };
    };

    # The tailscale-operator chart sets no resources. The requests are a
    # judgement for one idle controller.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "128Mi";
      };
      limits = {
        cpu = "2";
        memory = "1Gi";
      };
    };

    env = kix.options.env // {
      description = "Upstream operator variables such as OPERATOR_HOSTNAME, OPERATOR_INITIAL_TAGS, PROXY_TAGS, PROXY_FIREWALL_MODE, OPERATOR_LOGGING, TS_NO_LOGS_NO_SUPPORT and OPERATOR_LOGIN_SERVER (an https URL on port 443). A value is a string, a `fieldRef` source, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. The OAuth client comes from the oauthCredentials dependency. Variables the package sets or does not support are refused with the reason.";
    };

    metrics = kix.options.monitor;

    defaultProxyClass = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ProxyClass for proxies that name none (PROXY_DEFAULT_CLASS). Must be a key of proxyClasses.";
    };

    proxyClasses = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = "ProxyClass custom resources, as the `spec` of each, keyed by name. Each is applied once the operator runs.";
    };

    connectors = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options.proxyClass = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Key of proxyClasses whose ProxyClass the Connector uses.";
          };
        }
      );
      default = { };
      description = "Connector custom resources, as the `spec` of each, keyed by name. `proxyClass` names a key of proxyClasses; a Connector that uses a ProxyClass built elsewhere goes through out.mkConnector.";
    };
  };

  # The operand images follow the operator's repository and tag unless the
  # instance sets them. A moved tag drops their digests.
  config =
    { config, ... }:
    {
      operandImages = lib.genAttrs (builtins.attrNames operandDigests) (n: {
        repository = lib.mkDefault "${dirOf config.image.repository}/${n}";
        tag = lib.mkDefault config.image.tag;
      });
    };

  build = [
    (
      {
        self,
        config,
        oauthCredentials,
        prometheus ? null,
        ...
      }:
      let
        hasMetrics = config.metrics.enabled && prometheus != null;

        creds = kix.checkSecretKeys {
          inherit who;
          arg = "oauthCredentials";
          dep = oauthCredentials;
          keys = [
            "client_id"
            "client_secret"
          ];
        };

        ownedEnv = [
          {
            vars = {
              CLIENT_ID_FILE = "/oauth/client_id";
              CLIENT_SECRET_FILE = "/oauth/client_secret";
            };
            from = "the oauthCredentials dependency mounted at /oauth";
            fix = "Wire another Secret with deps.oauthCredentials.";
          }
          {
            vars = {
              OPERATOR_NAMESPACE = fieldRef "metadata.namespace";
              OPERATOR_SERVICE_ACCOUNT_NAME = fieldRef "spec.serviceAccountName";
              POD_NAME = fieldRef "metadata.name";
              POD_UID = fieldRef "metadata.uid";
            };
            from = "the pod's own metadata";
            fix = "Remove them from env.";
          }
          {
            vars = {
              OPERATOR_SECRET = "${name}-state";
              XDG_CONFIG_HOME = "/config";
            };
            from = "the package: the operator keeps its tailnet state in a Secret its Role may write and its files in the writable /config volume";
            fix = "Remove them from env.";
          }
          {
            vars.OPERATOR_INGRESS_CLASS_NAME = self.ingressClass.out.name;
            from = "the IngressClass this package creates, which must be named tailscale because the operator's DNS-record handler for Ingresses matches that name literally";
            fix = "Remove it and use tailscale.out.ingressClass.";
          }
          {
            vars = {
              PROXY_IMAGE = kix.image.ref config.operandImages.tailscale;
              K8S_PROXY_IMAGE = kix.image.ref config.operandImages.k8s-proxy;
            };
            from = "operandImages.tailscale and operandImages.k8s-proxy, which out.extraImages lists";
            fix = "Set those options.";
          }
          (
            {
              from = "defaultProxyClass, which is checked against proxyClasses";
              fix = "Set defaultProxyClass.";
            }
            # A plain string: a dependency on the ProxyClass would order the
            # operator after a resource whose readiness waits on the operator.
            // (
              if config.defaultProxyClass != null then
                { vars.PROXY_DEFAULT_CLASS = config.defaultProxyClass; }
              else
                { names = [ "PROXY_DEFAULT_CLASS" ]; }
            )
          )
          {
            names = [ "CLIENT_ID" ];
            from = "the oauthCredentials dependency in this package; CLIENT_ID selects workload identity federation, which needs serviceaccounts/token RBAC the package does not grant";
            fix = "Wire an OAuth client through deps.oauthCredentials.";
          }
          {
            names = [ "APISERVER_PROXY" ];
            from = "a kube-apiserver ProxyGroup in this package; the operator's in-process API server proxy needs impersonation RBAC the package does not grant";
            fix = "Build one with out.mkProxyGroup, spec.type = \"kube-apiserver\" and spec.kubeAPIServer.mode = \"noauth\".";
          }
          {
            names = [ "OPERATOR_DEFAULT_LOAD_BALANCER" ];
            from = "each Service's loadBalancerClass in this package; the variable makes the operator claim every LoadBalancer Service without a class, which is the cluster's loadBalancer role";
            fix = "Set loadBalancerClass = tailscale.out.loadBalancerClass on the Services you want on the tailnet.";
          }
          {
            names = [ "PROXY_PRIORITY_CLASS_NAME" ];
            from = "a ProxyClass in this package";
            fix = "Set spec.statefulSet.pod.priorityClassName in a ProxyClass and make it defaultProxyClass.";
          }
        ];

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit who;
            owned = ownedEnv;
          } config.env
        );

        subjectsOf = sa: [
          {
            kind = "ServiceAccount";
            name = sa.out.name;
            namespace = ns;
          }
        ];
        clusterRbac = scope.rbac.mkClusterRoleSet scope {
          subjects = subjectsOf self.serviceAccount;
          roles.${name} = rules.cluster;
        };
        operatorRbac = scope.rbac.mkRoleSet scope {
          subjects = subjectsOf self.serviceAccount;
          roles.${name} = rules.operator;
        };
        proxiesRbac = scope.rbac.mkRoleSet scope {
          subjects = subjectsOf self.proxiesServiceAccount;
          roles."${name}-proxies" = rules.proxies;
        };

        # Policies for the pods the operator creates. The spec is read only
        # when an enforcer exists.
        operandPolicy =
          suffix: labels: intents:
          kix.operandPolicy {
            inherit scope;
            name = "${name}-${suffix}";
            spec =
              let
                netpol = scope.networkPolicyEnforcer.netpol;
                translated = netpol.translateIntentRules { intents.operand = intents; };
              in
              netpol.mkEndpointSelector labels
              // lib.optionalAttrs (translated.egressRules != [ ]) { egress = translated.egressRules; }
              // lib.optionalAttrs (translated.ingressRules != [ ]) { ingress = translated.ingressRules; };
          };
        fromCluster = ports: {
          ingress = [ ({ from = "all-pods"; } // lib.optionalAttrs (ports != null) { inherit ports; }) ];
        };

        # The Service ports that `refs` name, each by port number or port
        # name; every port when `refs` is null. `what` prefixes the error.
        servicePorts =
          what: service: refs:
          let
            declared = service.rawManifest.spec.ports or [ ];
            pick =
              ref:
              let
                matched = builtins.filter (p: (p.port or null) == ref || (p.name or null) == ref) declared;
              in
              if matched == [ ] then
                throw "${what}: Service ${service.name} has no port ${toString ref}; its ports are ${
                  builtins.toJSON (map (p: p.port or null) declared)
                }."
              else
                matched;
          in
          if refs == null then declared else lib.unique (builtins.concatMap pick refs);

        # A policy over the pods of a Service without a selector would select
        # every pod in the namespace.
        selectorOf =
          what: service:
          let
            selector = service.rawManifest.spec.selector or null;
          in
          if selector == null || selector == { } then
            throw "${what}: Service ${service.name} has no selector, so a policy over its pods would admit the proxies to every pod in its namespace. Pass a Service that selects its backend pods."
          else
            selector;

        # The checks run with or without an enforcer, so a build does not
        # start failing when network policy is turned on.
        backendPolicy =
          what: consumerScope:
          {
            service,
            refs,
            policyName,
          }:
          let
            selector = selectorOf what service;
            ports = servicePorts what service refs;
            enforcer = consumerScope.networkPolicyEnforcer;
          in
          builtins.seq selector (
            builtins.deepSeq ports (
              if enforcer == null then
                null
              else
                enforcer.netpol.mkPolicy {
                  mkResource = consumerScope.mkResource;
                  extraArgs = {
                    name = "${policyName}-from-tailscale";
                    labels = {
                      ${kix.keys.derived} = "true";
                      ${kix.keys.policyType} = "ingress-controller";
                    };
                    spec = {
                      endpointSelector.matchLabels = selector;
                      ingress = [
                        (enforcer.netpol.mkCallerIngressRule {
                          callerSelector = managedLabels;
                          callerNamespace = ns;
                          inherit ports;
                        })
                      ];
                    };
                    # The selector above carries no context, so without this
                    # the policy is a part no dependency reaches.
                    extraDeps = [ service ];
                  };
                }
            )
          );

        mkBackendPolicy =
          consumerScope:
          {
            service,
            port ? null,
            name ? service.name,
          }:
          backendPolicy (callSite "mkBackendPolicy" consumerScope service.name) consumerScope {
            inherit service;
            refs = if port == null then null else [ port ];
            policyName = name;
          };

        # The Service port number of an Ingress's default backend.
        backendPort =
          what: service: port:
          let
            declared = service.rawManifest.spec.ports or [ ];
          in
          if port != null then
            (builtins.head (servicePorts what service [ port ])).port
          else if service ? out.port then
            builtins.fromJSON (builtins.unsafeDiscardStringContext service.out.port)
          else if builtins.length declared == 1 then
            (builtins.head declared).port
          else
            throw "${what}: Service ${service.name} has ${toString (builtins.length declared)} ports; pass port.";

        mkIngress =
          consumerScope:
          {
            name,
            service,
            port ? null,
            hostname ? name,
            annotations ? { },
            labels ? { },
            spec ? { },
          }:
          let
            what = callSite "mkIngress" consumerScope name;
            ruleHosts = builtins.filter (h: h != null) (map (r: r.host or null) (spec.rules or [ ]));
            refusal =
              if lib.hasInfix "." hostname then
                "hostname \"${hostname}\" has a dot. Tailscale uses only the first label as the machine name; pass that label."
              else if spec ? tls then
                "spec sets tls. The package sets tls.hosts from hostname, and the certificate comes from the tailnet; remove it."
              else if spec ? ingressClassName then
                "spec sets ingressClassName, which the package sets to the class tailscale; remove it."
              else if ruleHosts != [ ] then
                "spec.rules sets host ${lib.concatStringsSep ", " ruleHosts}. The operator ignores a rule unless its host equals the TLS host; leave host unset."
              else if spec ? defaultBackend then
                "spec sets defaultBackend, which the package sets from service and port; remove it."
              else
                null;
            defaultPort = backendPort what service port;
            serviceName = builtins.unsafeDiscardStringContext service.name;
            # Service ports of the paths that route to `service`, by number
            # or by name.
            pathPorts = builtins.concatMap (
              path:
              let
                backend = (path.backend or { }).service or null;
                portRef = (backend.port or { }).number or ((backend.port or { }).name or null);
              in
              if
                backend == null
                || builtins.unsafeDiscardStringContext (toString (backend.name or "")) != serviceName
              then
                [ ]
              else if portRef == null then
                throw "${what}: a path to Service ${serviceName} names no port; set backend.service.port.number or .name."
              else
                [ portRef ]
            ) (builtins.concatMap (rule: (rule.http or { }).paths or [ ]) (spec.rules or [ ]));
          in
          if refusal != null then
            throw "${what}: ${refusal}"
          else
            {
              ingress = consumerScope.mkResource {
                apiVersion = "networking.k8s.io/v1";
                kind = "Ingress";
                inherit name labels annotations;
                spec = lib.recursiveUpdate spec {
                  # The class name also carries a dependency on the operator,
                  # which handles the Ingress.
                  ingressClassName = builtins.appendContext self.ingressClass.out.name (
                    builtins.getContext self.deployment.out.name
                  );
                  tls = [ { hosts = [ hostname ]; } ];
                  defaultBackend.service = {
                    name = service.out.name;
                    port.number = defaultPort;
                  };
                };
              };
              # Named after the Ingress, so a Service can sit behind several
              # Ingresses and an out.mkBackendPolicy of its own.
              policy = backendPolicy what consumerScope {
                inherit service;
                refs = [ defaultPort ] ++ pathPorts;
                policyName = "${name}-ingress";
              };
            };

        # Refuses a reference given as a plain string, which names an object
        # without ordering this custom resource after it.
        refuseUntracked =
          what: field: value: fix:
          if value != null && !(isTracked value) then
            throw "${what}: ${field} = \"${value}\" is a plain string; ${fix}"
          else
            null;

        crBuilder =
          part: check: consumerScope: args:
          builtins.seq (check consumerScope args) (self.crds.${part}.out.mkCR consumerScope args);

        proxyClassCheck =
          builder: consumerScope: args:
          let
            what = callSite builder consumerScope (args.name or "?");
            proxyClass = (args.spec or { }).proxyClass or null;
          in
          refuseUntracked what "spec.proxyClass" proxyClass trackedFix;

        proxyGroupCheck =
          consumerScope: args:
          let
            spec = args.spec or { };
            what = callSite "mkProxyGroup" consumerScope (args.name or "?");
          in
          builtins.seq (proxyClassCheck "mkProxyGroup" consumerScope args) (
            if
              (spec.type or null) == "kube-apiserver" && ((spec.kubeAPIServer or { }).mode or "auth") != "noauth"
            then
              throw "${what}: a kube-apiserver ProxyGroup runs in auth mode unless kubeAPIServer.mode is set. Auth mode needs the kube-apiserver-auth-proxy ServiceAccount and impersonation RBAC, which this package does not create. Set spec.kubeAPIServer.mode = \"noauth\"."
            else
              null
          );

        recorderImage = config.operandImages.tsrecorder;
        mkRecorder =
          consumerScope: args:
          let
            what = callSite "mkRecorder" consumerScope (args.name or "?");
            field = "spec.storage.s3.credentials.secret.name";
            secretName =
              ((((args.spec or { }).storage or { }).s3 or { }).credentials or { }).secret.name or null;
            # Secret packages resolve only in their own namespace
            # (meta.scope = "namespace"), so a Secret a caller elsewhere
            # builds or depends on is outside the operator's namespace.
            otherNamespace = secretName != null && consumerScope.namespaceName != ns;
            container = {
              image = kix.image.ref recorderImage;
            }
            // lib.optionalAttrs (recorderImage.pullPolicy != null) {
              imagePullPolicy = recorderImage.pullPolicy;
            };
          in
          builtins.seq
            (refuseUntracked what field secretName
              "the operator reads it from namespace ${ns}. Pass kix.untrackedRef \"<name>\" for a Secret there that Kix does not build, or call mkRecorder from an instance in ${ns} and pass the out.name of a Secret it builds or depends on."
            )
            (
              if otherNamespace then
                throw "${what}: ${field} names a Secret, which the operator reads from namespace ${ns}, so a Recorder with S3 credentials is built by an instance in ${ns}. Call mkRecorder from an instance in ${ns} and pass the out.name of a Secret it builds or depends on, or kix.untrackedRef \"<name>\" for a Secret there that Kix does not build."
              else
                self.crds.recorders.out.mkCR consumerScope (
                  args
                  // {
                    spec = lib.recursiveUpdate { statefulSet.pod.container = container; } (args.spec or { });
                  }
                )
            );

        nameserverImage = config.operandImages.k8s-nameserver;
        mkDNSConfig =
          consumerScope:
          {
            spec ? { },
          }:
          self.crds.dnsConfigs.out.mkCR consumerScope {
            # The operator reconciles one DNSConfig per cluster. A fixed name
            # makes a second one a duplicate object, which fails the build.
            name = "ts-dns";
            spec = lib.recursiveUpdate {
              # The operator joins repo and tag with ":", so a pinned digest
              # rides on the tag.
              nameserver.image = {
                repo = nameserverImage.repository;
                tag =
                  if nameserverImage.digest != null then
                    "${nameserverImage.tag}@${nameserverImage.digest}"
                  else
                    nameserverImage.tag;
              };
            } spec;
          };

        policies = builtins.filter (p: p != null) (builtins.attrValues self.proxyPolicies);
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
        };
        proxiesServiceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "proxies";
        };

        clusterRole = clusterRbac.${name};
        clusterRoleBinding = clusterRbac."${name}-binding";
        operatorRole = operatorRbac.${name};
        operatorRoleBinding = operatorRbac."${name}-binding";
        proxiesRole = proxiesRbac."${name}-proxies";
        proxiesRoleBinding = proxiesRbac."${name}-proxies-binding";

        # The operator watches every kind at start, so its Deployment requires
        # all eight.
        crds = {
          connectors = scope.mkCRD {
            spec = vendored "connectors";
            readiness = ready "ConnectorReady";
          };
          dnsConfigs = scope.mkCRD {
            spec = vendored "dnsconfigs";
            readiness = ready "NameserverReady";
          };
          peerRelays = scope.mkCRD {
            spec = vendored "peerrelays";
            readiness = ready "PeerRelayReady";
          };
          proxyClasses = scope.mkCRD {
            spec = vendored "proxyclasses";
            readiness = ready "ProxyClassReady";
          };
          # The ProxyGroupPolicy reconciler sets no condition.
          proxyGroupPolicies = scope.mkCRD { spec = vendored "proxygrouppolicies"; };
          proxyGroups = scope.mkCRD {
            spec = vendored "proxygroups";
            readiness = ready "ProxyGroupReady";
          };
          recorders = scope.mkCRD {
            spec = vendored "recorders";
            readiness = ready "RecorderReady";
          };
          tailnets = scope.mkCRD {
            spec = vendored "tailnets";
            readiness = ready "TailnetReady";
          };
        };

        # The Ingress reconcilers read the class name from
        # OPERATOR_INGRESS_CLASS_NAME, but dnsRecordsReconcilerIngressHandler
        # in cmd/k8s-operator/operator.go matches the literal `tailscale`, so
        # any other name loses the DNS records of Ingress proxies.
        ingressClass = scope.mkClusterResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "IngressClass";
          name = "tailscale";
          spec.controller = "tailscale.com/ts-ingress";
        };

        deployment = scope.mkDeployment {
          inherit name;
          requires = builtins.attrValues self.crds ++ [
            self.clusterRoleBinding
            self.operatorRoleBinding
          ];
          spec = {
            replicas = 1;
            strategy.type = "Recreate";
            selector.matchLabels = scope.selectorLabels;
            template.spec = {
              serviceAccount = self.serviceAccount;
              nodeSelector."kubernetes.io/os" = "linux";
              terminationGracePeriodSeconds = 30;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65532;
                runAsGroup = 65532;
                fsGroup = 65532;
                seccompProfile.type = "RuntimeDefault";
              };
              containers = [
                {
                  name = "operator";
                  image = kix.image.ref config.image;
                  imagePullPolicy = config.image.pullPolicy;
                  inherit env;
                  ports = [ (kix.port "metrics" metricsPort) ];
                  # The port opens once the operator's tailnet node is
                  # Running, which can take minutes on first login.
                  startupProbe = {
                    tcpSocket.port = "metrics";
                    periodSeconds = 5;
                    failureThreshold = 60;
                  };
                  readinessProbe = {
                    httpGet = {
                      path = "/metrics";
                      port = "metrics";
                    };
                    periodSeconds = 10;
                  };
                  livenessProbe = {
                    tcpSocket.port = "metrics";
                    periodSeconds = 20;
                    failureThreshold = 3;
                  };
                  resources = config.resources;
                  securityContext = {
                    allowPrivilegeEscalation = false;
                    capabilities.drop = [ "ALL" ];
                    readOnlyRootFilesystem = true;
                  };
                  volumeMounts = [
                    {
                      name = "oauth";
                      mountPath = "/oauth";
                      readOnly = true;
                    }
                    {
                      name = "config";
                      mountPath = "/config";
                    }
                    {
                      name = "tmp";
                      mountPath = "/tmp";
                    }
                  ];
                }
              ];
              volumes =
                let
                  oauth = creds.out.volume "oauth";
                in
                [
                  (
                    oauth
                    // {
                      secret = oauth.secret // {
                        items = map (key: {
                          inherit key;
                          path = key;
                        }) creds.out.keys;
                        # 0440: readable by fsGroup 65532.
                        defaultMode = 288;
                      };
                    }
                  )
                  {
                    name = "config";
                    emptyDir = { };
                  }
                  {
                    name = "tmp";
                    emptyDir = { };
                  }
                ];
            };
          };
        };

        metricsService =
          if hasMetrics then
            self.deployment
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              ports = [
                {
                  name = "metrics";
                  port = metricsPort;
                  targetPort = metricsPort;
                  protocol = "TCP";
                }
              ];
            }
            |> scope.mkResource
          else
            null;

        proxyClasses = lib.mapAttrs (
          pcName: spec:
          self.crds.proxyClasses.out.mkCR scope {
            name = pcName;
            inherit spec;
            requires = [ self.deployment ];
          }
        ) config.proxyClasses;

        connectors = lib.mapAttrs (
          cName: connector:
          self.crds.connectors.out.mkCR scope {
            name = cName;
            spec =
              removeAttrs connector [ "proxyClass" ]
              // lib.optionalAttrs (connector.proxyClass != null) {
                proxyClass =
                  (self.proxyClasses.${connector.proxyClass}
                    or (throw "${who}: connectors.${cName}.proxyClass = \"${connector.proxyClass}\" names no entry in proxyClasses (declared: ${declaredProxyClasses config}). Declare proxyClasses.${connector.proxyClass}, or build the Connector with out.mkConnector and a ProxyClass passed as <resource>.out.name.")
                  ).out.name;
              };
            requires = [ self.deployment ];
          }
        ) config.connectors;

        # Null without an enforcer.
        proxyPolicies = {
          # Proxies write their state Secrets through the API server, run
          # WireGuard to peers on any UDP port, and forward to Services and
          # Connector routes.
          proxies = operandPolicy "proxies" managedLabels {
            egress = [
              { to = "dns"; }
              { to = "apiserver"; }
              { to = "world"; }
              { to = "all-pods"; }
            ];
          };
          # Egress proxies for ExternalName Services take traffic from the
          # cluster. Their labels do not separate them from LoadBalancer
          # proxies, which therefore also accept it.
          serviceProxies = operandPolicy "service-proxies" (parentType "svc") (fromCluster null);
          # Egress ProxyGroups take traffic from the cluster. Ingress
          # ProxyGroups carry the same labels, so they accept it too.
          proxyGroups = operandPolicy "proxy-groups" (parentType "proxygroup") (fromCluster null);
          # Cluster DNS forwards ts.net queries to the DNSConfig nameserver,
          # whose Service maps port 53 to 1053.
          nameservers = operandPolicy "nameservers" { app = "nameserver"; } (fromCluster [
            {
              port = 1053;
              protocol = "UDP";
            }
            {
              port = 1053;
              protocol = "TCP";
            }
          ]);
          # A Recorder joins the tailnet and writes recordings to S3.
          recorders =
            operandPolicy "recorders"
              {
                "app.kubernetes.io/name" = "recorder";
                "app.kubernetes.io/managed-by" = "tailscale-operator";
              }
              {
                egress = [
                  { to = "dns"; }
                  { to = "apiserver"; }
                  { to = "world"; }
                ];
              };
        };

        root = {
          resource = self.deployment;
          requires = [
            self.proxiesRoleBinding
          ]
          ++ lib.optional hasMetrics self.metricsService
          ++ builtins.attrValues self.proxyClasses
          ++ builtins.attrValues self.connectors
          ++ policies;

          out = {
            crds = {
              Connector = self.crds.connectors;
              DNSConfig = self.crds.dnsConfigs;
              PeerRelay = self.crds.peerRelays;
              ProxyClass = self.crds.proxyClasses;
              ProxyGroup = self.crds.proxyGroups;
              ProxyGroupPolicy = self.crds.proxyGroupPolicies;
              Recorder = self.crds.recorders;
              Tailnet = self.crds.tailnets;
            };

            loadBalancerClass = kix.providedLoadBalancerClass {
              class = "tailscale";
              by = self.deployment;
            };
            inherit (self) ingressClass;
            podSelector = managedLabels;
            podNamespace = ns;

            inherit
              mkBackendPolicy
              mkIngress
              mkRecorder
              mkDNSConfig
              ;
            mkConnector = crBuilder "connectors" (proxyClassCheck "mkConnector");
            mkProxyGroup = crBuilder "proxyGroups" proxyGroupCheck;

            # Includes the nameserver and recorder images before any
            # DNSConfig or Recorder exists, so a mirror can hold them.
            extraImages = map kix.image.ref (builtins.attrValues config.operandImages);
          };
        };
      }
    )

    (kix.monitor { service = "metricsService"; })
  ];
}
