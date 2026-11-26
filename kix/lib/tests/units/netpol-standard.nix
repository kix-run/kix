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
  };
  eksFacts = {
    provider = "Amazon VPC CNI";
    ipBlockSelectsPods = true;
    ipBlockSelectsNodes = true;
    ipBlockSeesServiceAddress = true;
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

  # On EKS an ipBlock matches pods, nodes, and Services, so `world` leaves
  # out each declared range and names each one that is missing.
  netpol-standard-world-egress-eks =
    let
      unset = (rulesFor eksFacts { }).mkExternalEgressRule { };
      set =
        (rulesFor eksFacts {
          podCidr = "100.64.0.0/16";
          serviceCidr = "10.100.0.0/16";
          nodeCidrs = [ "192.168.0.0/16" ];
        }).mkExternalEgressRule
          { };
    in
    (
      unset._widened == [
        "world-egress-pods"
        "world-egress-nodes"
        "world-egress-services"
      ]
      &&
        exceptOf set == [
          "169.254.0.0/16"
          "100.64.0.0/16"
          "192.168.0.0/16"
          "10.100.0.0/16"
        ]
      && !(set ? _widened)
    )
    || throw "EKS world: unset ${builtins.toJSON unset}, set ${builtins.toJSON set}";

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

  # The scorecard reports each reason a policy is wider once, with a count,
  # and each policy as a detail at `info`.
  netpol-standard-widened-scorecard =
    let
      cluster = eksCluster [
        vpcCni
        (withWeb { serviceType = "LoadBalancer"; })
      ];
      findings = builtins.filter (f: lib.hasSuffix "networkPolicyWidened" f.rule) (
        cluster.scorecardReport.findings
      );
      summaries = builtins.filter (f: f.severity == "warning") findings;
      details = builtins.filter (f: f.severity == "info") findings;
      startup = lib.findFirst (f: lib.hasInfix "(pod-start-egress-open)" f.message) null summaries;
      gke = gkeCluster [ (withWeb { }) ];
      gkeFindings = builtins.filter (f: lib.hasSuffix "networkPolicyWidened" f.rule) (
        gke.scorecardReport.findings
      );
    in
    (
      startup != null
      && lib.hasPrefix "2 network policies" startup.message
      && builtins.any (f: f.resource == "NetworkPolicy/app-default-deny") details
      && builtins.any (f: lib.hasInfix "(world-ingress-pods)" f.message) summaries
      && gkeFindings == [ ]
    )
    || throw "widened findings: ${builtins.toJSON findings}; GKE ${builtins.toJSON gkeFindings}";
}
