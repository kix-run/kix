# Consumer builders exposed on `root.out` of the tailscale package.
{
  lib,
  kix,
  ns,
  managedLabels,
  config,
  self,
}:
let
  inherit (import ../../../lib/core/error.nix { inherit lib; }) fail;

  isTracked = v: builtins.isString v && builtins.hasContext v;
  trackedFix = "pass <resource>.out.name, which also orders the custom resource after it, or kix.untrackedRef \"<name>\" for an object Kix does not build.";

  callSite =
    builder: consumerScope: subject:
    "${builder} ${subject}, called by ${consumerScope.namespaceName}/${consumerScope.instanceName}";

  # Return the Service ports matching `refs` (by port number or name), or all
  # ports when `refs` is null.
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
          fail {
            package = "tailscale";
            message = "${what}: Service ${service.name} has no port ${toString ref}. Its ports are ${
              builtins.toJSON (map (p: p.port or null) declared)
            }.";
          }
        else
          matched;
    in
    if refs == null then declared else lib.unique (builtins.concatMap pick refs);

  # Require a non-empty Service selector so a backend policy never matches all
  # pods in the caller's namespace.
  selectorOf =
    what: service:
    let
      selector = service.rawManifest.spec.selector or null;
    in
    if selector == null || selector == { } then
      fail {
        package = "tailscale";
        message = "${what}: Service ${service.name} has no selector, so a policy over its pods would admit the proxies to every pod in its namespace.";
        fix = "Pass a Service that selects its backend pods.";
      }
    else
      selector;

  # Validate selector and ports regardless of whether an enforcer is present so
  # enabling network policy later cannot uncover a latent error. The policy is
  # ingress-only, so it is null where the cluster does not enforce ingress:
  # it would be the backend's first ingress policy and close it to every
  # other client.
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
        if enforcer == null || !consumerScope.networkPolicyEnforced.ingress then
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
      fail {
        package = "tailscale";
        message = "${what}: Service ${service.name} has ${toString (builtins.length declared)} ports.";
        fix = "Pass port.";
      };

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
          fail {
            package = "tailscale";
            message = "${what}: a path to Service ${serviceName} names no port.";
            fix = "Set backend.service.port.number or .name.";
          }
        else
          [ portRef ]
      ) (builtins.concatMap (rule: (rule.http or { }).paths or [ ]) (spec.rules or [ ]));
    in
    if refusal != null then
      fail {
        package = "tailscale";
        message = "${what}: ${refusal}";
      }
    else
      {
        ingress = consumerScope.mkResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "Ingress";
          inherit name labels annotations;
          spec = lib.recursiveUpdate spec {
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
        policy = backendPolicy what consumerScope {
          inherit service;
          refs = [ defaultPort ] ++ pathPorts;
          policyName = "${name}-ingress";
        };
      };

  refuseUntracked =
    what: field: value: fix:
    if value != null && !(isTracked value) then
      fail {
        package = "tailscale";
        message = "${what}: ${field} = \"${value}\" is a plain string.";
        inherit fix;
      }
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
        fail {
          package = "tailscale";
          message = "${what}: a kube-apiserver ProxyGroup runs in auth mode unless kubeAPIServer.mode is set. Auth mode needs the kube-apiserver-auth-proxy ServiceAccount and impersonation RBAC, which this package does not create.";
          fix = "Set spec.kubeAPIServer.mode = \"noauth\".";
        }
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
          fail {
            package = "tailscale";
            message = "${what}: ${field} names a Secret, which the operator reads from namespace ${ns}, so a Recorder with S3 credentials is built by an instance in ${ns}.";
            fix = "Call mkRecorder from an instance in ${ns} and pass the out.name of a Secret it builds or depends on, or kix.untrackedRef \"<name>\" for a Secret there that Kix does not build.";
          }
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
      name = "ts-dns";
      spec = lib.recursiveUpdate {
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
in
{
  inherit
    mkBackendPolicy
    mkIngress
    mkRecorder
    mkDNSConfig
    ;
  mkConnector = crBuilder "connectors" (proxyClassCheck "mkConnector");
  mkProxyGroup = crBuilder "proxyGroups" proxyGroupCheck;
}
