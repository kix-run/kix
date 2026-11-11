# clusters/test-kind-probe.nix: a kind cluster with Cilium enforcing
# network policy and one package whose health probe dials its own Service.
#
# The live proof for kix.healthCheck's egress edge (v2_discussions/136 item
# 4): under default-deny the probe passes only because the address it dials
# derived a CiliumNetworkPolicy for the probe pod. Set `refOnly = true` on
# the web instance and the same probe must time out.
#
# Bring up:  kind create cluster --name kix-probe --config <disableDefaultCNI>
# Deploy:    kix --flake ./clusters --context kind-kix-probe deploy kind-probe -y
#
{ kix, packages }:

kix.buildCluster {
  name = "kind-probe";
  modules = [
    kix.flavors.kind

    (
      { lib, ... }:
      {
        # kind runs with the default CNI disabled; the managed cilium
        # instance fills the cni role, as homelab-kind does.
        cluster.roles.cni = {
          binding = "absent";
          provider = null;
        };
        networkPolicy.enable = true;

        instances.kube-system.cilium = {
          package = packages.experimental.cilium;
        };

        namespaces.probe = { };

        instances.probe.web = {
          package = {
            meta.version = "test";
            options.refOnly = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Strip the dialing claim from the probe's address: the edge is not derived and the probe must fail.";
            };
            build = [
              (
                {
                  self,
                  scope,
                  kix,
                  ...
                }:
                {
                  root = self.svc;
                  deployment = scope.mkDeployment {
                    name = "web";
                    spec = {
                      selector.matchLabels = scope.selectorLabels;
                      template = {
                        metadata.labels = scope.selectorLabels;
                        spec.containers = [
                          {
                            name = "web";
                            image = "nginxinc/nginx-unprivileged:1.27-alpine";
                            securityContext.runAsNonRoot = true;
                            ports = [ (kix.port "http" 8080) ];
                            resources = {
                              requests = {
                                cpu = "10m";
                                memory = "16Mi";
                              };
                              limits.memory = "64Mi";
                            };
                          }
                        ];
                      };
                    };
                  };
                  svc = self.deployment |> kix.service.fromWorkload { name = "web"; } |> scope.mkResource;
                }
              )
              (kix.kixlib.healthCheck {
                env =
                  {
                    self,
                    config,
                    ...
                  }:
                  let
                    url = self.svc.out.url { };
                  in
                  {
                    APP_URL = if config.refOnly then kix.kixlib.facts.refOnly url else url;
                  };
                script = ''
                  import os, sys, time
                  from urllib.request import urlopen

                  url = os.environ["APP_URL"]
                  deadline = time.time() + int(os.environ["RETRY_FOR"])
                  while True:
                      try:
                          with urlopen(url, timeout=5) as r:
                              print("ok    GET", url, "->", r.status)
                              sys.exit(0)
                      except Exception as e:
                          print("FAIL  GET", url, "->", e)
                      if time.time() >= deadline:
                          print("gave up after", os.environ["RETRY_FOR"], "s")
                          sys.exit(1)
                      sys.stdout.flush()
                      time.sleep(5)
                '';
                retryFor = _: 30;
              })
            ];
          };
        };
      }
    )
  ];
}
