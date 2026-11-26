# Tests for the standard NetworkPolicy enforcer (`plugins/netpol/standard.nix`)
# and the flavours that declare it: what each rule writes for the GKE and EKS
# platform facts, which rules allow more than Cilium and say so, which rules
# stop the build and name the option that fixes them, and the scorecard rule
# that reports the wider ones. Each refusal is paired with a passing case.

{
  lib,
  publicKix,
  manifests,
  byName,
  ofKind,
  evalFails,
  containerBase,
  ...
}:

let
  helpers = import ../caught.nix { inherit lib; };

  # The renderer loaded so that a refusal returns `{ thrown = <sentences>; }`.
  standard = helpers.loadCaught ../../plugins/netpol/standard.nix { inherit lib; };

  gkeFacts = {
    provider = "GKE Dataplane V2";
    ipBlockSelectsPods = false;
    ipBlockSelectsNodes = true;
    ipBlockSeesServiceAddress = false;
    podRangeHoldsOnlyPods = true;
    nodeRangeHoldsOnlyNodes = true;
  };
  eksFacts = {
    provider = "Amazon VPC CNI";
    ipBlockSelectsPods = true;
    ipBlockSelectsNodes = true;
    ipBlockSeesServiceAddress = true;
    podRangeHoldsOnlyPods = false;
    nodeRangeHoldsOnlyNodes = false;
    podStartsBeforePolicy = true;
  };

  emptyNetwork = {
    podCidr = null;
    serviceCidr = null;
    nodeCidrs = [ ];
    apiServer = {
      cidrs = [ ];
      port = 443;
      sources = [ ];
    };
  };

  # The enforcer for `platform` with `network` merged over an empty network.
  rulesFor =
    platform: network:
    standard.mkNetpol {
      inherit platform;
      network = lib.recursiveUpdate emptyNetwork network;
    };

  thrownHas = text: v: builtins.isAttrs v && lib.hasInfix text (v.thrown or "");

  exceptOf = r: (builtins.head r.to).ipBlock.except;

  # A Deployment that runs as ServiceAccount `web`, bound to a Role, behind a
  # Service of `serviceType`, with `network` as its `meta.network`.
  webPackage =
    {
      serviceType ? "ClusterIP",
      network ? { },
      role ? false,
    }:
    {
      meta = {
        version = "test";
        inherit network;
      };
      build =
        { self, scope, ... }:
        {
          sa = scope.mkResource {
            apiVersion = "v1";
            kind = "ServiceAccount";
            name = "web";
          };
          role =
            if role then
              scope.mkResource {
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "Role";
                name = "web";
                extra.rules = [
                  {
                    apiGroups = [ "" ];
                    resources = [ "configmaps" ];
                    verbs = [ "get" ];
                  }
                ];
              }
            else
              null;
          binding =
            if role then
              scope.mkResource {
                apiVersion = "rbac.authorization.k8s.io/v1";
                kind = "RoleBinding";
                name = "web";
                extra = {
                  roleRef = {
                    apiGroup = "rbac.authorization.k8s.io";
                    kind = "Role";
                    name = "web";
                  };
                  subjects = [
                    {
                      kind = "ServiceAccount";
                      name = self.sa.out.name;
                      namespace = "app";
                    }
                  ];
                };
              }
            else
              null;
          deployment = scope.mkDeployment {
            name = "web";
            spec = {
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata.labels = scope.selectorLabels;
                spec = {
                  serviceAccountName = self.sa.out.name;
                  containers = [
                    (
                      {
                        name = "web";
                        image = "example/web:1";
                      }
                      // containerBase
                    )
                  ];
                };
              };
            };
          };
          service = scope.mkResource {
            apiVersion = "v1";
            kind = "Service";
            name = "web";
            spec = {
              type = serviceType;
              selector = scope.selectorLabels;
              ports = [
                {
                  port = 80;
                  targetPort = 8080;
                }
              ];
            };
          };
          root = self.deployment;
        };
    };

  clusterWith =
    flavor: modules:
    publicKix.buildCluster {
      name = "test";
      modules = [
        flavor
        { networkPolicy.enable = true; }
      ]
      ++ modules;
    };

  gkeCluster = modules: clusterWith publicKix.flavors.gke modules;
  eksCluster = modules: clusterWith publicKix.flavors.eks modules;
  vpcCni = {
    cluster.flavor.eks.networkPolicy = "vpc-cni";
  };

  withWeb = args: { instances.app.web.package = webPackage args; };

  policiesOf = cluster: ofKind "NetworkPolicy" (manifests cluster);

  widenedOf = p: p.metadata.annotations."kix.run/network-policy-widened" or null;
in
{
  # Every policy sets `policyTypes`, because a policy without it also
  # isolates ingress. A default deny names both directions.
  netpol-standard-policy-types =
    let
      np = rulesFor gkeFacts { };
      policy = np.mkPolicy {
        mkResource = x: x;
        selector.app = "web";
        egress = [ np.dnsEgressRule ];
        extraArgs.name = "web-egress";
      };
      deny = np.mkDefaultDenySpec {
        denyIngress = true;
        denyEgress = true;
      };
    in
    (
      policy.kind == "NetworkPolicy"
      && policy.apiVersion == "networking.k8s.io/v1"
      && policy.spec.policyTypes == [ "Egress" ]
      && policy.spec.podSelector.matchLabels == { app = "web"; }
      && !(policy.spec ? ingress)
      &&
        deny == {
          podSelector = { };
          policyTypes = [
            "Ingress"
            "Egress"
          ];
        }
    )
    || throw "policy ${builtins.toJSON policy}, deny ${builtins.toJSON deny}";

  # A Cilium `spec` is refused, and the spec `mkDefaultDenySpec` builds is
  # accepted.
  netpol-standard-legacy-spec-refused =
    let
      np = rulesFor gkeFacts { };
      build =
        spec:
        (np.mkPolicy {
          mkResource = x: x;
          extraArgs = {
            name = "legacy";
            inherit spec;
          };
        }).spec;
      legacy = build { endpointSelector.matchLabels.app = "web"; };
      deny = build (
        np.mkDefaultDenySpec {
          denyIngress = false;
          denyEgress = true;
        }
      );
    in
    (thrownHas "`selector`, `ingress`, and `egress`" legacy && deny.policyTypes == [ "Egress" ])
    || throw "legacy ${builtins.toJSON legacy}, deny ${builtins.toJSON deny}";

  # One DNS rule holds the pod peers and the address peers on UDP and TCP 53.
  netpol-standard-dns-peers =
    let
      rule =
        (standard.mkNetpol {
          platform = gkeFacts;
          network = emptyNetwork;
        }).withDnsPeers
          [
            {
              namespace = "kube-system";
              podSelector."k8s-app" = "node-local-dns";
            }
            { cidr = "169.254.20.10/32"; }
          ];
    in
    (
      rule.dnsEgressRule.to == [
        {
          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "kube-system";
          podSelector.matchLabels."k8s-app" = "node-local-dns";
        }
        { ipBlock.cidr = "169.254.20.10/32"; }
      ]
      &&
        map (p: p.protocol) rule.dnsEgressRule.ports == [
          "UDP"
          "TCP"
        ]
    )
    || throw "DNS rule ${builtins.toJSON rule.dnsEgressRule}";

  # A `world` rule always leaves out the link-local ranges. On GKE it
  # leaves out the node ranges once they are declared, and says it is wider
  # while they are not. An ipBlock never matches pods or Services there, so
  # those ranges stay in.
  netpol-standard-world-egress-gke =
    let
      unset = (rulesFor gkeFacts { }).mkExternalEgressRule { };
      set = (rulesFor gkeFacts { nodeCidrs = [ "10.128.0.0/20" ]; }).mkExternalEgressRule { };
    in
    (
      exceptOf unset == [ "169.254.0.0/16" ]
      && (builtins.elemAt unset.to 1).ipBlock.except == [ "fe80::/10" ]
      && unset._widened == [ "world-egress-nodes" ]
      &&
        exceptOf set == [
          "169.254.0.0/16"
          "10.128.0.0/20"
        ]
      && !(set ? _widened)
    )
    || throw "GKE world: unset ${builtins.toJSON unset}, set ${builtins.toJSON set}";

  # On EKS an ipBlock matches pods, nodes, and Services. Pods and nodes take
  # addresses from the VPC subnets, which also hold VPC endpoints such as
  # STS, so `world` keeps both ranges, names why, and never asks for
  # `podCidr`: an STS endpoint inside the subnets stays reachable on 443.
  # Only the Service range, which is not in the VPC, is left out. A platform
  # whose pod range holds only pods leaves it out and asks for it when unset.
  netpol-standard-world-egress-eks =
    let
      network = {
        podCidr = "192.168.0.0/16";
        serviceCidr = "10.100.0.0/16";
        nodeCidrs = [ "192.168.0.0/16" ];
      };
      unset = (rulesFor eksFacts { }).mkExternalEgressRule { };
      set = (rulesFor eksFacts network).mkExternalEgressRule { };
      dedicatedFacts = eksFacts // {
        podRangeHoldsOnlyPods = true;
      };
      dedicatedUnset = (rulesFor dedicatedFacts { }).mkExternalEgressRule { };
      dedicated =
        (rulesFor dedicatedFacts (network // { podCidr = "100.64.0.0/16"; })).mkExternalEgressRule
          { };
      # An STS interface endpoint in the VPC subnets.
      stsEndpoint = "192.168.12.34";
      inRange =
        cidr: ip:
        let
          parts = lib.splitString "/" cidr;
          octets = s: map lib.toInt (lib.splitString "." s);
          prefixOctets = lib.toInt (lib.last parts) / 8;
        in
        lib.take prefixOctets (octets (builtins.head parts)) == lib.take prefixOctets (octets ip);
    in
    (
      unset._widened == [
        "world-egress-pod-subnets"
        "world-egress-node-subnets"
        "world-egress-services"
      ]
      &&
        exceptOf set == [
          "169.254.0.0/16"
          "10.100.0.0/16"
        ]
      && !(builtins.any (c: inRange c stsEndpoint) (exceptOf set))
      &&
        set._widened == [
          "world-egress-pod-subnets"
          "world-egress-node-subnets"
        ]
      && builtins.elem "world-egress-pods" dedicatedUnset._widened
      && builtins.elem "100.64.0.0/16" (exceptOf dedicated)
    )
    || throw "EKS world: unset ${builtins.toJSON unset}, set ${builtins.toJSON set}, dedicated ${builtins.toJSON dedicated}";

  # Every "set this option" in a reason's fix is safe where the reason can be
  # printed: no reason that EKS can print asks for `podCidr` or
  # `nodeCidrs` to narrow `world`.
  netpol-standard-widening-advice-safe-on-eks =
    let
      widening = import ../../plugins/netpol/widening.nix;
      eksOnly = [
        "world-egress-pod-subnets"
        "world-egress-node-subnets"
      ];
      asksToSet = id: opt: lib.hasInfix "Set `cluster.network.${opt}`" widening.${id}.fix;
    in
    (builtins.all (id: !(asksToSet id "podCidr") && !(asksToSet id "nodeCidrs")) eksOnly)
    || throw "unsafe advice in ${builtins.toJSON (map (id: widening.${id}.fix) eksOnly)}";

  # API server egress needs its address. On EKS the first address of the
  # Service range is the `kubernetes` Service, so `serviceCidr` is enough.
  netpol-standard-apiserver-egress =
    let
      missing = (rulesFor gkeFacts { }).apiServerEgressRule;
      gke = (rulesFor gkeFacts { apiServer.cidrs = [ "10.0.0.2/32" ]; }).apiServerEgressRule;
      eks = (rulesFor eksFacts { serviceCidr = "172.20.0.0/16"; }).apiServerEgressRule;
      eksMissing = (rulesFor eksFacts { }).apiServerEgressRule;
    in
    (
      thrownHas "cluster.network.apiServer.cidrs" missing
      && thrownHas "endpointslices" missing
      && thrownHas "cluster.network.serviceCidr" eksMissing
      &&
        gke == {
          to = [ { ipBlock.cidr = "10.0.0.2/32"; } ];
          ports = [
            {
              port = 443;
              protocol = "TCP";
            }
          ];
        }
      && eks.to == [ { ipBlock.cidr = "172.20.0.1/32"; } ]
    )
    || throw "API server egress: missing ${builtins.toJSON missing}, gke ${builtins.toJSON gke}, eks ${builtins.toJSON eks}";

  # Webhook calls come from `apiServer.sources`. An address source on a
  # platform where an ipBlock matches pods is wider.
  netpol-standard-apiserver-ingress =
    let
      fromApiserver =
        platform: network:
        builtins.head
          ((rulesFor platform network).translateIntentRules {
            intents.webhook.ingress = [
              {
                from = "apiserver";
                ports = [ { port = 9443; } ];
              }
            ];
          }).ingressRules;
      konnectivity = {
        namespace = "kube-system";
        podSelector."k8s-app" = "konnectivity-agent";
      };
      missing = fromApiserver gkeFacts { };
      gke = fromApiserver gkeFacts { apiServer.sources = [ konnectivity ]; };
      eks = fromApiserver eksFacts { apiServer.sources = [ { cidr = "192.168.0.0/16"; } ]; };
      malformed = fromApiserver gkeFacts { apiServer.sources = [ { namespace = "kube-system"; } ]; };
    in
    (
      thrownHas "cluster.network.apiServer.sources" missing
      && thrownHas "cannot read" malformed
      &&
        gke.from == [
          {
            namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "kube-system";
            podSelector.matchLabels."k8s-app" = "konnectivity-agent";
          }
        ]
      &&
        gke.ports == [
          {
            port = 9443;
            protocol = "TCP";
          }
        ]
      && !(gke ? _widened)
      && eks._widened == [ "apiserver-sources-pods" ]
    )
    || throw "API server ingress: gke ${builtins.toJSON gke}, eks ${builtins.toJSON eks}";

  # A rule for the nodes uses `nodeCidrs`, which must be set. `host` alone
  # means one node to Cilium, so the rule says it allows every node.
  netpol-standard-node-entities =
    let
      withNodes = rulesFor gkeFacts { nodeCidrs = [ "10.128.0.0/20" ]; };
      hostOnly = withNodes.mkExternalEgressRule { entities = [ "host" ]; };
      both = withNodes.mkExternalEgressRule {
        entities = [
          "host"
          "remote-node"
        ];
      };
      hostNetwork = withNodes.mkHostNetworkEgressRule { ports = [ { port = 9100; } ]; };
      missing = (rulesFor gkeFacts { }).mkHostNetworkEgressRule { ports = [ { port = 9100; } ]; };
      noMatch =
        (rulesFor (gkeFacts // { ipBlockSelectsNodes = false; }) {
          nodeCidrs = [ "10.128.0.0/20" ];
        }).mkExternalEgressRule
          { entities = [ "remote-node" ]; };
      eksNodes = (rulesFor eksFacts { nodeCidrs = [ "192.168.0.0/16" ]; }).mkHostNetworkEgressRule {
        ports = [ { port = 9100; } ];
      };
    in
    (
      hostOnly.to == [ { ipBlock.cidr = "10.128.0.0/20"; } ]
      && hostOnly._widened == [ "host-all-nodes" ]
      && !(both ? _widened)
      &&
        hostNetwork.ports == [
          {
            port = 9100;
            protocol = "TCP";
          }
        ]
      && thrownHas "cluster.network.nodeCidrs" missing
      && thrownHas "cannot match node addresses" noMatch
      && eksNodes._widened == [ "node-range-pods" ]
    )
    || throw "node rules: host ${builtins.toJSON hostOnly}, missing ${builtins.toJSON missing}";

  # `cluster` holds pods, nodes, and the API server, so it needs both the
  # node ranges and the API server's address.
  netpol-standard-cluster-entity =
    let
      full = rulesFor gkeFacts {
        nodeCidrs = [ "10.128.0.0/20" ];
        apiServer.cidrs = [ "10.0.0.2/32" ];
      };
      rule = full.mkExternalEgressRule { entities = [ "cluster" ]; };
      noApiServer = (rulesFor gkeFacts { nodeCidrs = [ "10.128.0.0/20" ]; }).mkExternalEgressRule {
        entities = [ "cluster" ];
      };
    in
    (
      rule.to == [
        {
          namespaceSelector = { };
          podSelector = { };
        }
        { ipBlock.cidr = "10.128.0.0/20"; }
        { ipBlock.cidr = "10.0.0.2/32"; }
      ]
      && thrownHas "cluster.network.apiServer.cidrs" noApiServer
    )
    || throw "cluster entity: ${builtins.toJSON rule}";

  # Ports come out as numbers where they are numbers, and a named port is
  # kept, since a NetworkPolicy resolves it in both directions.
  netpol-standard-service-ports =
    let
      np = rulesFor gkeFacts { };
      rule = np.mkServiceEgressRule {
        selector.app = "db";
        namespace = "data";
        sourceNamespace = "app";
        ports = [
          { targetPort = "5432"; }
          {
            targetPort = "metrics";
            protocol = "TCP";
          }
        ];
      };
      local = np.mkServiceEgressRule {
        selector.app = "db";
        namespace = "app";
        sourceNamespace = "app";
        ports = [ ];
      };
    in
    (
      rule.ports == [
        {
          port = 5432;
          protocol = "TCP";
        }
        {
          port = "metrics";
          protocol = "TCP";
        }
      ]
      && (builtins.head rule.to).namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "data"
      && local == { to = [ { podSelector.matchLabels.app = "db"; } ]; }
    )
    || throw "service rule ${builtins.toJSON rule}, local ${builtins.toJSON local}";

  # A NetworkPolicy is namespaced, so a clusterwide platform intent is
  # refused and a namespaced one becomes a policy in its namespace.
  netpol-standard-platform-intent =
    let
      np = rulesFor gkeFacts { };
      intentOf =
        extra:
        {
          name = "agent";
          podSelector.app = "agent";
          egress = [ { to = "dns"; } ];
        }
        // extra;
      materialize =
        extra:
        np.materializePlatformIntent {
          intent = intentOf extra;
          mkResource = x: x;
          namespaceResource = "kube-system";
          clusterScoped = "cluster";
        };
      clusterwide = materialize { scope = "clusterwide"; };
      namespaced = materialize { };
    in
    (
      thrownHas "clusterwide" clusterwide
      && namespaced.kind == "NetworkPolicy"
      && namespaced.labels."kix.run/policy-type" == "platform-intent"
      && namespaced.spec.policyTypes == [ "Egress" ]
    )
    || throw "platform intent: ${builtins.toJSON namespaced}";

  # On GKE, Kix writes NetworkPolicy objects and no Cilium kind, puts no
  # default deny in kube-system, and admits load balancer traffic from
  # `world`, which it marks wider because an ipBlock matches the nodes.
  netpol-standard-gke-cluster =
    let
      cluster = gkeCluster [ (withWeb { serviceType = "LoadBalancer"; }) ];
      ms = manifests cluster;
      policies = policiesOf cluster;
      external = byName "web-deployment-web-external-ingress" policies;
    in
    (
      builtins.all (m: !(lib.hasInfix "cilium.io" (m.apiVersion or ""))) ms
      && byName "app-default-deny" policies != null
      && !(builtins.any (p: p.metadata.namespace == "kube-system") policies)
      && widenedOf external == "world-ingress-nodes"
    )
    || throw "GKE cluster policies: ${builtins.toJSON (map (p: p.metadata.name) policies)}";

  # On both GKE flavours, with nothing depending on `platform-dns`, the
  # NetworkPolicy DNS rule allows every DNS destination the flavour lists:
  # kube-dns and node-local-dns pods, and the two Cloud DNS addresses.
  netpol-standard-gke-dns-all-peers =
    let
      dnsTo =
        flavor:
        let
          egress = byName "web-deployment-web-egress" (policiesOf (clusterWith flavor [ (withWeb { }) ]));
        in
        (lib.findFirst (
          r: builtins.any (p: (p.port or null) == 53) (r.ports or [ ])
        ) { } egress.spec.egress).to or [ ];
      want = [
        {
          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "kube-system";
          podSelector.matchLabels."k8s-app" = "kube-dns";
        }
        {
          namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "kube-system";
          podSelector.matchLabels."k8s-app" = "node-local-dns";
        }
        { ipBlock.cidr = "169.254.169.254/32"; }
        { ipBlock.cidr = "169.254.20.10/32"; }
      ];
      standardTo = dnsTo publicKix.flavors.gke;
      autopilotTo = dnsTo publicKix.flavors.gke-autopilot;
    in
    (standardTo == want && autopilotTo == want)
    || throw "GKE DNS peers: standard ${builtins.toJSON standardTo}, autopilot ${builtins.toJSON autopilotTo}";

  # Traffic from a LoadBalancer reaches the pod on the Service's target
  # port, so the external ingress rule names that port on both enforcers.
  netpol-standard-external-ingress-ports =
    let
      external = byName "web-deployment-web-external-ingress" (
        policiesOf (gkeCluster [ (withWeb { serviceType = "LoadBalancer"; }) ])
      );
      rule = builtins.head external.spec.ingress;
      cilium = import ../../../packages/experimental/cilium/netpol-rules.nix { inherit lib; };
      ciliumRule = cilium.mkExternalIngressRule {
        entities = [ "world" ];
        ports = [
          {
            port = 80;
            targetPort = 8080;
          }
        ];
      };
      ciliumOpen = cilium.mkExternalIngressRule { entities = [ "world" ]; };
    in
    (
      rule.ports == [
        {
          port = 8080;
          protocol = "TCP";
        }
      ]
      &&
        ciliumRule.toPorts == [
          {
            ports = [
              {
                port = "8080";
                protocol = "TCP";
              }
            ];
          }
        ]
      && !(ciliumOpen ? toPorts)
    )
    || throw "external ingress ports: standard ${builtins.toJSON rule}, cilium ${builtins.toJSON ciliumRule}";

  # Every intent target and source that takes `ports` keeps them.
  netpol-standard-intent-ports-kept =
    let
      np = rulesFor gkeFacts {
        nodeCidrs = [ "10.128.0.0/20" ];
        apiServer = {
          cidrs = [ "10.0.0.2/32" ];
          sources = [ { cidr = "10.0.0.0/28"; } ];
        };
      };
      ports = [
        {
          port = 9000;
          protocol = "TCP";
        }
      ];
      translated = np.translateIntentRules {
        intents.all = {
          egress = map (r: r // { inherit ports; }) [
            { to = "apiserver"; }
            { to = "world"; }
            {
              to = "world";
              entities = [ "cluster" ];
            }
            { to = "all-pods"; }
            { to = "pods"; }
            {
              to = "node-local";
              cidr = "169.254.169.254/32";
            }
          ];
          ingress = map (r: r // { inherit ports; }) [
            { from = "all-pods"; }
            { from = "world"; }
            {
              from = "world";
              entities = [ "host" ];
            }
            { from = "apiserver"; }
          ];
        };
      };
      rules = translated.egressRules ++ translated.ingressRules;
      lacking = builtins.filter (r: (r.ports or null) != ports) rules;
    in
    (builtins.length rules == 10 && lacking == [ ])
    || throw "intent rules without their ports: ${builtins.toJSON lacking}";

  # Two intents that ask for the same rule give one rule in the policy.
  netpol-standard-duplicate-rules-written-once =
    let
      world443 = [
        {
          to = "world";
          ports = [
            {
              port = 443;
              protocol = "TCP";
            }
          ];
        }
      ];
      egress =
        (byName "web-deployment-web-egress" (
          policiesOf (gkeCluster [
            (withWeb {
              network.intents = {
                api.egress = world443;
                identity.egress = world443;
              };
            })
          ])
        )).spec.egress;
    in
    (builtins.length egress == 2) || throw "egress rules: ${builtins.toJSON egress}";

  # A workload bound to a Role needs the API server's address on GKE, and
  # builds once `cluster.network.apiServer.cidrs` names it.
  netpol-standard-gke-apiserver-required =
    let
      missing = gkeCluster [ (withWeb { role = true; }) ];
      set = gkeCluster [
        (withWeb { role = true; })
        { cluster.network.apiServer.cidrs = [ "10.0.0.2/32" ]; }
      ];
    in
    (evalFails missing && !(evalFails set))
    || throw "GKE API server: missing fails ${toString (evalFails missing)}, set fails ${toString (evalFails set)}";

  # The platform owns policy on GKE, so a `cilium` instance is refused.
  netpol-standard-gke-refuses-cilium =
    let
      packages = import ../../../packages { inherit lib; };
      withCilium = gkeCluster [
        (withWeb { })
        { instances.kube-system.cilium.package = packages.experimental.cilium; }
      ];
      without = gkeCluster [ (withWeb { }) ];
    in
    (evalFails withCilium && !(evalFails without))
    || throw "GKE with cilium fails ${toString (evalFails withCilium)}";

  # EKS creates clusters with network policy off in the VPC CNI, so
  # generated policy needs `cluster.flavor.eks.networkPolicy = "vpc-cni"`.
  netpol-standard-eks-needs-vpc-cni =
    let
      none = eksCluster [ (withWeb { }) ];
      on = eksCluster [
        vpcCni
        (withWeb { })
      ];
      off = publicKix.buildCluster {
        name = "test";
        modules = [
          publicKix.flavors.eks
          (withWeb { })
        ];
      };
    in
    (
      evalFails none
      && !(evalFails on)
      && !(evalFails off)
      && byName "app-default-deny" (policiesOf on) != null
      && byName "platform-network-policy" (manifests off) == null
    )
    || throw "EKS network policy option: none fails ${toString (evalFails none)}, on fails ${toString (evalFails on)}";

  # A reason a cluster setting removes is a warning; a platform limit is an
  # info finding, listed only under `kix check -v`. On EKS with every range
  # set, only platform limits remain, so no warning shows; with
  # `serviceCidr` unset, a `world` rule still warns. Raised to error, the rule
  # fails only on the fixable reason.
  netpol-standard-widened-scorecard =
    let
      worldEgress = {
        network.intents.api.egress = [
          {
            to = "world";
            ports = [
              {
                port = 443;
                protocol = "TCP";
              }
            ];
          }
        ];
        serviceType = "LoadBalancer";
      };
      findingsOf =
        cluster:
        builtins.filter (f: lib.hasSuffix "networkPolicyWidened" f.rule) cluster.scorecardReport.findings;
      eksWith =
        network:
        eksCluster [
          vpcCni
          { cluster.network = network; }
          (withWeb worldEgress)
        ];
      complete = findingsOf (eksWith {
        serviceCidr = "10.100.0.0/16";
      });
      noServiceCidr = findingsOf (eksWith {
        apiServer.cidrs = [ "10.100.0.1/32" ];
      });
      warnings = builtins.filter (f: f.severity == "warning");
      infos = builtins.filter (f: f.severity == "info");
      startup = lib.findFirst (f: lib.hasInfix "(pod-start-egress-open)" f.message) null (infos complete);
      asError =
        modules:
        eksCluster (
          [
            vpcCni
            (withWeb worldEgress)
            {
              # Only this rule, raised to error, so another rule's error
              # does not decide the outcome.
              scorecard.rules.security.networkPolicyWidened =
                (import ../../rules/security.nix { inherit lib; }).networkPolicyWidened;
              scorecard.maxSeverity = "error";
              scorecard.ruleOverrides.byRule."security.networkPolicyWidened".severity = "error";
            }
          ]
          ++ modules
        );
      gkeFindings = findingsOf (gkeCluster [ (withWeb { }) ]);
    in
    (
      warnings complete == [ ]
      && startup != null
      && lib.hasPrefix "2 network policies" startup.message
      && builtins.any (f: lib.hasInfix "(world-ingress-pods)" f.message) (infos complete)
      && builtins.any (f: f.resource == "NetworkPolicy/app-default-deny") (infos complete)
      && map (f: lib.hasInfix "(world-egress-services)" f.message) (warnings noServiceCidr) == [ true ]
      && !(evalFails (asError [ { cluster.network.serviceCidr = "10.100.0.0/16"; } ]))
      && evalFails (asError [ { cluster.network.apiServer.cidrs = [ "10.100.0.1/32" ]; } ])
      && gkeFindings == [ ]
    )
    || throw "widened findings: complete ${builtins.toJSON complete}; no serviceCidr ${builtins.toJSON noServiceCidr}";

  # The rule reads `fixable` alone: an unset `podCidr` on a platform whose pod
  # range holds only pods is a warning, and the shared pod range is info.
  netpol-standard-widened-fixable-field =
    let
      rule = (import ../../rules/security.nix { inherit lib; }).networkPolicyWidened;
      policy = name: ids: {
        kind = "NetworkPolicy";
        metadata = {
          inherit name;
          namespace = "app";
          annotations."kix.run/network-policy-widened" = ids;
        };
      };
      findings = rule.check {
        allResources = [
          (policy "a" "world-egress-pods")
          (policy "b" "world-egress-pod-subnets")
        ];
      };
      summary = id: lib.findFirst (f: lib.hasInfix "(${id}):" f.message) null findings;
      widening = import ../../plugins/netpol/widening.nix;
    in
    (
      !((summary "world-egress-pods").detail or false)
      && (summary "world-egress-pod-subnets").detail
      && builtins.all (r: builtins.isBool r.fixable) (builtins.attrValues widening)
      && !widening.node-range-pods.fixable
    )
    || throw "fixable field: ${builtins.toJSON findings}";
}
