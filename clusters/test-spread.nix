# clusters/test-spread.nix: the availability level and derived pod spread
# on a multi-zone kind cluster.
#
# kind itself is one node per container, so zones are node labels set by
# the kind config (scripts/kind-spread.sh); the flavor's multiNode = false
# and availabilityZones = [ ] are overridden here to say so.
# Design: discussions/archive/145_availability_level.md (spread mechanism: archive/143).
#
# The descheduler instance restores zone spread once a zone returns: the
# "movable" fixture has no volumes, so the descheduler may evict it. The
# echo-server instances mount an emptyDir at /tmp, which the descheduler's
# default protections never evict, so they stay where they are.
#
# Build:  kix build spread
# Deploy: scripts/kind-spread.sh

{ kix, packages }:

kix.buildCluster {
  name = "spread";
  modules = [
    kix.flavors.kind

    {
      cluster.capabilities.multiNode = true;
      cluster.capabilities.availabilityZones = [
        "a"
        "b"
        "c"
      ];
      namespaces.echo = { };
      namespaces.descheduler = { };
      namespaces.monitoring = { };

      # Gives the descheduler its ServiceMonitor and alerts, which
      # test-spread.rules-test.yaml tests.
      instances.monitoring.prometheus-operator.package = packages.experimental.prometheus-operator;

      # Short interval so scripts/kind-spread.sh sees a rebalance within
      # minutes.
      instances.descheduler.descheduler = {
        package = packages.experimental.descheduler;
        config.deschedulingInterval = "30s";
      };

      instances.echo = {
        # cluster default, derived "zone": three replicas from the level,
        # hard on the zone key, soft on hosts, plus a PDB.
        zoned = {
          package = packages.echo-server;
        };
        # operator escape hatch: one replica from the level, so no spread
        # and no PDB.
        unspread = {
          package = packages.echo-server;
          availability = "none";
        };
        # "node" on a zoned cluster: hard on hosts, soft on the zone.
        pinned = {
          package = packages.echo-server;
          config.replicas = 3;
          availability = "node";
        };
        # No volumes, so the descheduler may move it: three replicas from
        # the level, one per zone.
        movable.package = {
          meta = {
            version = "test";
            owner = "platform";
            description = "HTTP test server with no volumes, which the descheduler may evict";
          };
          build =
            {
              self,
              scope,
              kix,
              availability,
              ...
            }:
            {
              deployment = scope.mkDeployment {
                name = scope.instanceName;
                spec = {
                  replicas = kix.availability.pick availability {
                    none = 1;
                    pod = 2;
                    node = 2;
                    zone = 3;
                  };
                  selector.matchLabels = scope.selectorLabels;
                  template = {
                    metadata.labels = scope.selectorLabels;
                    spec = {
                      terminationGracePeriodSeconds = 5;
                      securityContext = {
                        runAsNonRoot = true;
                        runAsUser = 65534;
                        seccompProfile.type = "RuntimeDefault";
                      };
                      containers = [
                        {
                          name = "netexec";
                          image = "registry.k8s.io/e2e-test-images/agnhost:2.66.1@sha256:6e2eef87d0dc77e070a7549bc5fdfa290c0fefe3359eb33c2ad1eda692fe66a4";
                          args = [
                            "netexec"
                            "--http-port=8080"
                          ];
                          ports = [ (kix.port "http" 8080) ];
                          livenessProbe.httpGet = {
                            path = "/healthz";
                            port = "http";
                          };
                          readinessProbe.httpGet = {
                            path = "/healthz";
                            port = "http";
                          };
                          resources = {
                            requests = {
                              cpu = "10m";
                              memory = "16Mi";
                            };
                            limits = {
                              cpu = "100m";
                              memory = "64Mi";
                            };
                          };
                          securityContext = {
                            allowPrivilegeEscalation = false;
                            readOnlyRootFilesystem = true;
                            capabilities.drop = [ "ALL" ];
                          };
                        }
                      ];
                    };
                  };
                };
              };
              service =
                self.deployment |> kix.service.fromWorkload { name = scope.instanceName; } |> scope.mkResource;
              root = self.service;
            };
        };
      };
    }
  ];
}
