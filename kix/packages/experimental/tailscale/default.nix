# tailscale: the Tailscale Kubernetes operator, which puts Services and
# Ingresses on a tailnet and runs subnet routers, egress proxies, and API
# server proxies from tailscale.com custom resources.
#
# Renders the operator, its RBAC, the eight tailscale.com CRDs, IngressClass
# `tailscale`, and network policies for the operand pods the operator creates
# in this namespace.
#
# A cluster runs one instance. `meta.conflictsWith` gives the reason.
#
# Tailscale setup before first deploy:
#   - In the tailnet policy file, add `tag:k8s-operator` and `tag:k8s`, with
#     `tag:k8s-operator` owning `tag:k8s`.
#   - Create an OAuth client with write scope on General/Services,
#     Devices/Core, and Keys/Auth Keys, tagged `tag:k8s-operator`.
#   - Store its credentials under `client_id` and `client_secret` in a Secret
#     in this namespace and wire it as `oauthCredentials`.
#
# Dependencies:
#   oauthCredentials (required)  Secret with keys `client_id` and `client_secret`.
#   prometheus (optional)        Metrics Service, ServiceMonitor, and alerts.
#
# Alerts: with a prometheus dependency and `metrics.enabled`, a
# PrometheusRule `<instance>-alerts` selects the metrics Service's series,
# which are controller-runtime's (the operator registers no metrics of its
# own on that port).
#   TailscaleOperatorDown (warning)             the operator answers no
#                                               scrape. Running proxies keep
#                                               serving; new or changed
#                                               Services, Ingresses, and
#                                               tailscale.com resources are
#                                               not acted on.
#   TailscaleOperatorReconcileErrors (warning)  reconciles fail, such as a
#                                               refused OAuth client or a
#                                               tailnet API error.
# A proxy pod that crash-loops or stays unready is left to
# prometheus-default-rules (KubePodCrashLooping,
# KubeStatefulSetReplicasMismatch).
#
# Known limits:
#   - No workload identity federation (`env.CLIENT_ID` is refused).
#   - No API server proxy in auth mode (`env.APISERVER_PROXY` is refused;
#     `out.mkProxyGroup` requires `spec.kubeAPIServer.mode = "noauth"` for
#     `kube-apiserver` ProxyGroups).
#   - Not usable as the `ingress` dependency of `kix.expose`; use
#     `out.mkIngress`.
#   - The `proxies` ServiceAccount has full Secret access in this namespace;
#     keep unrelated Secrets in other namespaces.
#
# Upgrades: the operator keeps its tailnet device in the Secret
# `<instance>-state` and reads its settings from the tailscale.com
# resources, so a new release starts from what the old one left. It then
# moves every proxy it manages to its own proxy image, which restarts each
# proxy pod once. Going back to an older package works the same way. The
# older CRDs do not know fields that the newer release added, such as
# PeerRelay `service.port` and `staticEndpoints` from 1.104. While they are
# installed, the API server leaves those fields out when it serves a
# resource, and drops them when it writes one.
#
# Exposes (`root.out`):
#   out.loadBalancerClass  "tailscale", carrying a dependency on the operator.
#   out.mkBackendPolicy    Network policy admitting proxies to a Service's pods.
#   out.mkIngress          `{ ingress; policy; }` for a tailscale Ingress.
#   out.mkConnector        Connector CR builder checking `spec.proxyClass`.
#   out.mkProxyGroup       ProxyGroup CR builder checking `spec.proxyClass` and
#                          `kube-apiserver` mode.
#   out.mkDNSConfig        Cluster-singleton `ts-dns` DNSConfig CR builder.
#   out.mkRecorder         Recorder CR builder defaulting the recorder image.
#   out.crds.<Kind>        CRD handles for `scope.mkCR`.
#   out.ingressClass       The `tailscale` IngressClass.
#   out.podSelector        Labels of proxy pods managed by the operator.
#   out.podNamespace       Namespace of proxy pods managed by the operator.
#   out.extraImages        Digest-pinned operand image references.
#   out.version            The Tailscale operator version `image.tag` names.

{
  scope,
  lib,
  kix,
}:
let
  # Shared across meta.version, image.tag, crds/sources.txt, and rbac.nix.
  release = "1.104.7";
  tag = "v${release}";

  name = scope.instanceName;
  ns = scope.namespaceName;
  who = "tailscale ${ns}/${name}";

  metricsPort = 8080;

  operandDigests = {
    tailscale = "sha256:72c1e19e0aedca96b8533bbb0b4368564410ff20b17e53b804eb6c1f04a31be4";
    k8s-proxy = "sha256:bb86ef8c98ea071612926f766c6f461f3ac22788a3d862397012f423a581bcb8";
    k8s-nameserver = "sha256:9b0685a4dd89742043084affa56fbda04f56b348d6cd9a8a23105a24ed3ebb39";
    tsrecorder = "sha256:2d141b9088627d111bcae66c500d4e1afea46715f3dd40c007d1d8353a4afcc3";
  };
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

  managedLabels = {
    "tailscale.com/managed" = "true";
  };
  parentType = type: managedLabels // { "tailscale.com/parent-resource-type" = type; };

  loginServerPattern = "https://[^/:]+(:443)?(/.*)?";

  declaredProxyClasses =
    config:
    let
      names = builtins.attrNames config.proxyClasses;
    in
    if names == [ ] then "none" else lib.concatStringsSep ", " names;

  fieldRef = path: { valueFrom.fieldRef.fieldPath = path; };

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
    conflictsWith = [
      {
        key = "cluster:tailscale";
        reason = "The operator watches cluster-wide tailscale.com resources, Services with loadBalancerClass \"tailscale\", and Ingresses with IngressClass \"tailscale\" across all namespaces, so two instances would compete for the same objects.";
      }
    ];
    annotationDomains = [ "tailscale.com" ];
    podSecurity = "privileged";
    unsafe = [ "privileged" ];
    availability.max = "none";
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
    # Tailscale's compatibility page states Kubernetes 1.23.0 and later for
    # the operator, with no upper bound. The floor is 1.25 because five of
    # the vendored CRDs carry x-kubernetes-validations rules, which
    # Kubernetes runs from 1.25.
    k8s = {
      minVersion = "1.25";
      reason = "The Tailscale operator ${release} supports Kubernetes 1.23 and later, and its CRDs validate fields with rules that need Kubernetes 1.25";
    };
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
      (kix.image.checkRelease {
        inherit (config) image;
        inherit release;
        reason = "the CRDs in kix/packages/experimental/tailscale/crds and the RBAC rules in kix/packages/experimental/tailscale/rbac.nix come from ${tag}";
        fix = "To update this package to another version, change release in kix/packages/experimental/tailscale/default.nix and the tag in crds/sources.txt, run uv run scripts/vendor-crds.py tailscale, and compare rbac.nix against operator-rbac.yaml and proxy-rbac.yaml for that version.";
      })
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

  options = import ./options.nix {
    inherit
      lib
      kix
      tag
      operandDigests
      ;
  };

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

        creds = kix.contracts.secret.helpers.use {
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
          }
          {
            vars = {
              OPERATOR_SECRET = "${name}-state";
              XDG_CONFIG_HOME = "/config";
            };
            from = "the package: the operator keeps its tailnet state in a Secret its Role may write and its files in the writable /config volume";
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
            // (
              if config.defaultProxyClass != null then
                { vars.PROXY_DEFAULT_CLASS = config.defaultProxyClass; }
              else
                { names = [ "PROXY_DEFAULT_CLASS" ]; }
            )
          )
          {
            names = [ "CLIENT_ID" ];
            reason = "setting CLIENT_ID directly enables workload identity federation, and the operator has no serviceaccounts/token RBAC permissions.";
            fix = "Wire an OAuth client through deps.oauthCredentials.";
          }
          {
            names = [ "APISERVER_PROXY" ];
            reason = "the operator's in-process API server proxy requires impersonation RBAC permissions not granted to the operator.";
            fix = "Remove APISERVER_PROXY from env. To expose the API server on the tailnet, build a ProxyGroup with out.mkProxyGroup using spec.type = \"kube-apiserver\" and spec.kubeAPIServer.mode = \"noauth\".";
          }
          {
            names = [ "OPERATOR_DEFAULT_LOAD_BALANCER" ];
            reason = "Tailscale would claim every LoadBalancer Service without a loadBalancerClass, taking over Services meant for the cluster's default load balancer (the loadBalancer role).";
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
            inherit scope;
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

        builders = import ./builders.nix {
          inherit
            lib
            kix
            ns
            managedLabels
            config
            self
            ;
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
            # A class and a policy configure proxies; the ProxyGroup and
            # Connector that use them run the pods.
            usesAtLeast = _: { };
          };
          proxyGroupPolicies = scope.mkCRD {
            spec = vendored "proxygrouppolicies";
            usesAtLeast = _: { };
          };
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
                  (self.proxyClasses.${connector.proxyClass} or (scope.fail {
                    package = "tailscale";
                    option = "connectors.${cName}.proxyClass";
                    message = "connectors.${cName}.proxyClass = \"${connector.proxyClass}\" names no entry in proxyClasses (declared: ${declaredProxyClasses config}).";
                    fix = "Declare proxyClasses.${connector.proxyClass}, or build the Connector with out.mkConnector and a ProxyClass passed as <resource>.out.name.";
                  })
                  ).out.name;
              };
            requires = [ self.deployment ];
          }
        ) config.connectors;

        proxyPolicies = {
          proxies = operandPolicy "proxies" managedLabels {
            egress = [
              { to = "dns"; }
              { to = "apiserver"; }
              { to = "world"; }
              { to = "all-pods"; }
            ];
          };
          serviceProxies = operandPolicy "service-proxies" (parentType "svc") (fromCluster null);
          proxyGroups = operandPolicy "proxy-groups" (parentType "proxygroup") (fromCluster null);
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
            version = kix.image.version config.image;
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

            inherit (builders)
              mkBackendPolicy
              mkIngress
              mkRecorder
              mkDNSConfig
              mkConnector
              mkProxyGroup
              ;

            extraImages = map kix.image.ref (builtins.attrValues config.operandImages);
          };
        };
      }
    )

    (
      let
        sel = ''namespace="${ns}",service="${name}-metrics"'';
        operator = "Tailscale operator ${ns}/${name}";
      in
      kix.monitor {
        service = "metricsService";
        alerts = {
          TailscaleOperatorDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "10m";
            severity = "warning";
            summary = "The Tailscale operator is down.";
            description = "The ${operator} has not answered a scrape for 10 minutes. Running proxies keep serving, but new or changed Services, Ingresses, and tailscale.com resources are not acted on. Check the operator Deployment in ${ns}.";
          };
          TailscaleOperatorReconcileErrors = kix.reconcileErrorsAlert {
            selector = sel;
            operator = operator;
            summary = "The Tailscale operator fails to reconcile resources.";
            impact = "a proxy or tailnet device may not match its Kubernetes resource";
            nextStep = "Check the operator logs for the error. Common causes are rejected OAuth client credentials or tailnet API errors.";
          };
        };
      }
    )
  ];
}
