# coredns: runs CoreDNS as the cluster DNS server, answering Service and pod
# names under the cluster domain and forwarding other names upstream.
#
# Installs a ConfigMap holding the Corefile, built from typed server blocks
# (corefile.nix); a ServiceAccount with a read-only ClusterRole and binding;
# the Deployment; and the root Service at `clusterIP`. The instance claims
# the `dns` role, so workloads that dial an in-cluster Service order after
# it. The PodDisruptionBudget and the spread come from the availability
# level. Evaluation refuses a Corefile that CoreDNS would reject, that would
# not resolve Service names for pods, or that leaves a probe without a
# listener.
#
# Install it where nothing else serves cluster DNS: a kubeadm cluster with
# the CoreDNS addon skipped, k3s with `--disable coredns`, RKE2 without
# rke2-coredns, or Talos with its CoreDNS off. Where the platform runs its
# own DNS (stock kind, EKS, GKE, AKS), pods keep querying that server, so
# this one would answer nobody.
#
# Required config: `clusterIP`, which must equal the kubelet's `clusterDNS`,
# the address every pod's resolv.conf names. Run the instance in
# `kube-system`. The Service takes the instance name, so name the instance
# `kube-dns` where tooling addresses `kube-dns.kube-system` (an nginx
# `resolver`, NodeLocal DNSCache).
#
#   instances.kube-system.kube-dns = {
#     package = packages.experimental.coredns;
#     config.clusterIP = "10.96.0.10"; # the kubelet's clusterDNS
#   };
#
# Dependencies:
#   prometheus (optional)  the Service's metrics port, a ServiceMonitor, and
#                          three alerts scoped to the instance, with
#                          `metrics.enabled`.
#
# `out`: root is the Service, so `out.name`, `out.fqdn`, `out.selector`, and
# `out.port` (53) are the Service's. `out.scrapedByPrometheus` is true while
# the instance's own ServiceMonitor scrapes it. `out.version` is the CoreDNS
# version `image.tag` names.
#
# Escape hatches: `servers` takes any plugin with its arguments and block
# lines; `env` sets Go runtime variables such as GOMEMLIMIT; the instance's
# `partsOverlays` add files to `configmap` for the `file` and `hosts`
# plugins, change `service`, or place `deployment`.
#
# Upgrades: CoreDNS keeps no data, so a deploy replaces the pods one at a
# time and every replica reads the same Corefile. The default Corefile
# works unchanged on CoreDNS 1.13 to 1.15. Since 1.14.7 the `forward` plugin
# stops after twice as many connection attempts as it has upstreams; set
# `max_connect_attempts 0` in its block for the old behaviour. To go back,
# deploy an older Kix release or set `image.tag` and `image.digest` to the
# older image. CoreDNS starts on the same Corefile, and nothing else needs
# undoing.
#
# Known limits: the network intents allow DNS on port 53 only, in from every
# pod and out to resolvers outside the cluster; the `servers` description
# names the route for other traffic. Under `networkPolicy.enable` the
# instance must run in `kube-system`, because the DNS egress rule every
# workload gets selects kube-system pods labelled `k8s-app: kube-dns`;
# evaluation refuses another namespace. Zones with a scheme (tls://,
# https://, grpc://, or quic://) are refused, so `servers` builds plain DNS
# servers only.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  corefile = import ./corefile.nix { inherit lib; };

  release = "1.15.0";

  # The Service name, also the `service` label its scraped series carry.
  serviceName = scope.instanceName;

  dns53 = [
    {
      port = 53;
      protocol = "UDP";
    }
    {
      port = 53;
      protocol = "TCP";
    }
  ];

  inherit (scope.rbac) grant allow core;
  discovery = scope.rbac.group "discovery.k8s.io" [ "endpointslices" ];

  # renderServer appends `:<port>` to every zone, so a zone that carries its
  # own port renders `example.org:53:53`, which CoreDNS fails to parse. A
  # colon elsewhere stays legal for IPv6 reverse zones such as `fd00::/8`.
  zoneName =
    lib.types.addCheck lib.types.str (
      z: z != "" && !lib.hasInfix "://" z && builtins.match ".*:[0-9]+" z == null
    )
    // {
      description = "DNS zone name without a scheme or a :port suffix";
    };

  # The shape of a dotted quad (octets 0-255) or of an IPv6 literal (two to
  # seven colons). It catches typos and "None", not every malformed IPv6
  # address.
  ipLiteral =
    lib.types.strMatching (
      "((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
      + "|([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}"
    )
    // {
      description = "IPv4 or IPv6 address literal";
    };

  pluginType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        enabled = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether the directive is rendered.";
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          defaultText = lib.literalMD "the attribute name";
          description = "The plugin the directive runs. Set it to repeat a plugin under another attribute, for example `rewrite-a = { name = \"rewrite\"; args = [ ... ]; }`.";
        };
        args = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Arguments after the plugin name, one word each.";
        };
        block = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Lines inside the directive's `{ }` block. Empty renders no block.";
        };
      };
    }
  );

  serverType = lib.types.submodule {
    options = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the server block is rendered.";
      };
      zones = lib.mkOption {
        type = lib.types.nonEmptyListOf zoneName;
        default = [ "." ];
        description = ''
          Zones the block serves, such as `.` or `example.org`. The port goes
          in `port`, not in the zone. A zone with a scheme (`dns://`,
          `tls://`, `https://`, `grpc://`, or `quic://`) is refused: write a
          plain DNS zone without one. A TLS server needs a certificate in the
          pod and a Corefile block that `servers` does not build; add both
          with partsOverlays on `configmap` and `deployment`.
        '';
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 53;
        description = "Port the block listens on, for every zone in its header.";
      };
      plugins = lib.mkOption {
        type = lib.types.attrsOf pluginType;
        default = { };
        description = ''
          Directives of the block, keyed by a name of your choice, which is
          also the default plugin name. CoreDNS runs plugins in its
          compiled-in order whatever the Corefile says; repeats of one
          plugin run in attribute-name order.
        '';
      };
    };
  };
in
{
  meta = {
    version = release;
    description = "CoreDNS as the cluster DNS: a Corefile built from typed server blocks, a Service at the kubelet's clusterDNS address, and the dns role";
    owner = "platform";
    roles = [ "dns" ];
    network.intents = {
      # Every pod resolves through it, and so do node resolvers that forward
      # the cluster domain. The `cluster` entity names the nodes as well as
      # the pods.
      clients.ingress = [
        {
          from = "world";
          entities = [ "cluster" ];
          ports = dns53;
        }
      ];
      # Public resolvers, and resolvers on this or a peer node. `entities`
      # are Cilium entity names, read by the Cilium enforcer's external
      # egress rule.
      upstream.egress = [
        {
          to = "world";
          entities = [
            "world"
            "host"
            "remote-node"
          ];
          ports = dns53;
        }
      ];
    };
  };

  options = {
    image = kix.options.image {
      repository = "docker.io/coredns/coredns";
      tag = release;
      digest = "sha256:0a9d8c8ddf34347eb59aad9a8784f0710de88d6d112726d11d271f9bc6daca26";
    };

    clusterIP = lib.mkOption {
      type = ipLiteral;
      example = "10.96.0.10";
      description = ''
        Address of the Service. It must equal the kubelet's `clusterDNS`,
        which every pod's resolv.conf names: `clusterDNS` in the kubelet
        config (`kubectl -n kube-system get cm kubelet-config -o yaml` on
        kubeadm), `--cluster-dns` on k3s and RKE2. Typically 10.96.0.10 on
        kubeadm and 10.43.0.10 on k3s and RKE2.
      '';
    };

    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      # Every lookup in the cluster goes through these pods: two keep DNS up
      # across a pod restart or the loss of a node or zone.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };
      defaultText = lib.literalMD "from the availability level: 1 at none, 2 above";
      description = "CoreDNS replicas.";
    };

    # No CPU limit, as in kubeadm's CoreDNS manifest (requests 100m/70Mi,
    # memory limit 170Mi): a throttled DNS server delays every lookup in the
    # cluster.
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "70Mi";
      };
      limits.memory = "170Mi";
    };

    servers = lib.mkOption {
      type = lib.types.attrsOf serverType;
      default = { };
      defaultText = lib.literalMD ''
        One block, `servers.default`, as kubeadm writes it:

        ```
        .:53 {
            cache 30 {
                disable success <clusterDomain>
                disable denial <clusterDomain>
            }
            errors
            forward . <cluster.network.dnsUpstream, or /etc/resolv.conf> {
                max_concurrent 1000
            }
            health {
                lameduck 5s
            }
            kubernetes <clusterDomain> in-addr.arpa ip6.arpa {
                pods insecure
                fallthrough in-addr.arpa ip6.arpa
                ttl 30
            }
            loadbalance
            loop
            prometheus :9153
            ready
            reload
        }
        ```
      '';
      example = lib.literalExpression ''
        {
          default.plugins.forward.args = [ "." "192.0.2.53" ];
          "10-office" = {
            plugins.view.args = [ "office" ];
            plugins.view.block = [ "expr incidr(client_ip(), '192.0.2.0/24')" ];
            plugins.forward.args = [ "." "192.0.2.1" ];
          };
        }
      '';
      description = ''
        Corefile server blocks by name. Adding a block keeps `default`;
        `servers.default.plugins.<p>.enabled = false` removes one plugin
        from it, and `servers.default.enabled = false` removes the block.
        Each default directive is set field by field, so overriding
        `kubernetes.args` keeps its `block`.

        Blocks render with those that enable `view` first, then by name.
        CoreDNS answers from the first block sharing a zone and port whose
        view matches, so name blocks with a prefix such as `10-office` to
        order them.

        A plugin that reads a file (`file`, `hosts`) reads it from a key
        added to the ConfigMap with partsOverlays on `configmap`, at
        `/etc/coredns/<key>`.

        The package allows DNS (53) in from every pod and out to resolvers
        outside the cluster. Under network policy, a block on another port,
        an upstream that is a pod, or a DoT or DoH upstream needs a policy
        of its own: an entry in the cluster's `networkPolicy.platformIntents`
        that selects these pods (`k8s-app: kube-dns`), or a policy resource
        added with partsOverlays.
      '';
    };

    env = kix.options.env;

    metrics = kix.options.monitor;
  };

  config =
    { clusterConfig, ... }:
    let
      d = clusterConfig.clusterDomain;
      configured = clusterConfig.cluster.network.dnsUpstream;
      upstream = if configured == [ ] then [ "/etc/resolv.conf" ] else configured;
    in
    {
      # Every leaf is a default of its own, so an instance that sets one
      # field of a directive keeps the rest.
      servers.default.plugins = {
        errors.enabled = lib.mkDefault true;
        health.block = lib.mkDefault [ "lameduck 5s" ];
        ready.enabled = lib.mkDefault true;
        kubernetes = {
          args = lib.mkDefault [
            d
            "in-addr.arpa"
            "ip6.arpa"
          ];
          block = lib.mkDefault [
            "pods insecure"
            "fallthrough in-addr.arpa ip6.arpa"
            "ttl 30"
          ];
        };
        prometheus.args = lib.mkDefault [ ":9153" ];
        forward = {
          args = lib.mkDefault ([ "." ] ++ upstream);
          block = lib.mkDefault [ "max_concurrent 1000" ];
        };
        cache = {
          args = lib.mkDefault [ "30" ];
          block = lib.mkDefault [
            "disable success ${d}"
            "disable denial ${d}"
          ];
        };
        loop.enabled = lib.mkDefault true;
        reload.enabled = lib.mkDefault true;
        loadbalance.enabled = lib.mkDefault true;
      };
    };

  build = [
    (
      {
        self,
        config,
        clusterConfig,
        prometheus ? null,
        ...
      }:
      let
        facts = corefile.facts config.servers;
        scrape = config.metrics.enabled && prometheus != null;

        failures =
          corefile.checks {
            inherit (config) servers;
            inherit (clusterConfig) clusterDomain;
          }
          ++
            lib.optional (scrape && facts.metricsPort == null)
              "metrics are enabled and a Prometheus is wired, but no server block enables the prometheus plugin, so the ServiceMonitor would scrape nothing. Set servers.default.plugins.prometheus.enabled = true or metrics.enabled = false."
          # The enforcer's DNS egress rule reaches only kube-system pods
          # labelled k8s-app=kube-dns, whichever instance provides dns.
          ++
            lib.optional ((clusterConfig.networkPolicy.enable or false) && scope.namespaceName != "kube-system")
              "network policy is enabled and this instance is the cluster's dns provider, but it runs in namespace '${scope.namespaceName}'. The DNS egress rule every workload gets allows only kube-system pods labelled k8s-app=kube-dns, so no pod could reach it. Install it in kube-system.";

        # Every build renders this value (the Deployment's checksum hashes
        # the ConfigMap), so a refused Corefile fails evaluation.
        renderedCorefile = if failures != [ ] then scope.fail failures else corefile.render config.servers;

        dnsPorts = builtins.concatMap (
          p:
          let
            suffix = lib.optionalString (p != 53) "-${toString p}";
          in
          [
            {
              name = "dns${suffix}";
              containerPort = p;
              protocol = "UDP";
            }
            {
              name = "dns-tcp${suffix}";
              containerPort = p;
              protocol = "TCP";
            }
          ]
        ) facts.serverPorts;

        metricsPorts = lib.optional (facts.metricsPort != null) (kix.port "metrics" facts.metricsPort);

        envVars = kix.mkEnvVars (kix.mergeEnv { inherit scope; } config.env);
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = scope.instanceName;
        };

        configmap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = scope.instanceName;
          data.Corefile = renderedCorefile;
        };
      }
      // scope.rbac.mkClusterRoleSet scope {
        subjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        roles.${scope.instanceName} = grant [
          (
            [
              core.endpoints
              core.services
              core.pods
              core.namespaces
              discovery.endpointslices
            ]
            |> allow [
              "list"
              "watch"
            ]
          )
        ];
      }
      // {
        deployment =
          {
            name = scope.instanceName;
            spec = {
              replicas = config.replicas;
              selector.matchLabels = scope.selectorLabels;
              template = {
                metadata = {
                  # The network-policy enforcer's DNS egress rule and
                  # NodeLocal DNSCache's upstream Service select
                  # `k8s-app: kube-dns`.
                  labels = scope.selectorLabels // {
                    "k8s-app" = "kube-dns";
                  };
                  # A Corefile change rolls the pods, so the deploy waits for
                  # CoreDNS to load it. `reload` alone would keep the old
                  # config running if the new one fails to parse.
                  annotations."checksum/corefile" = self.configmap.out.contentHash;
                };
                spec = {
                  serviceAccount = self.serviceAccount;
                  priorityClassName = "system-cluster-critical";
                  # CoreDNS resolves upstream names through the node's
                  # resolv.conf, not through itself.
                  dnsPolicy = "Default";
                  # kubeadm's tolerations: cluster DNS runs on nodes tainted
                  # for add-ons only and on control-plane nodes.
                  tolerations = [
                    {
                      key = "CriticalAddonsOnly";
                      operator = "Exists";
                    }
                    {
                      key = "node-role.kubernetes.io/control-plane";
                      effect = "NoSchedule";
                    }
                  ];
                  securityContext.seccompProfile.type = "RuntimeDefault";
                  containers = [
                    (
                      {
                        name = "coredns";
                        image = kix.image.ref config.image;
                        imagePullPolicy = config.image.pullPolicy;
                        args = [
                          "-conf"
                          "/etc/coredns/Corefile"
                        ];
                        inherit (config) resources;
                        ports = dnsPorts ++ metricsPorts;
                        livenessProbe = {
                          httpGet = {
                            path = "/health";
                            port = facts.healthPort;
                          };
                          initialDelaySeconds = 60;
                          periodSeconds = 10;
                          timeoutSeconds = 5;
                          failureThreshold = 5;
                        };
                        readinessProbe = {
                          httpGet = {
                            path = "/ready";
                            port = facts.readyPort;
                          };
                          periodSeconds = 10;
                        };
                        securityContext = {
                          allowPrivilegeEscalation = false;
                          # The image runs as 65532:65532. Images before
                          # 1.14.7 name the user `nonroot`, and the kubelet
                          # refuses runAsNonRoot unless it can see a numeric
                          # user, so the uid and gid are stated here for an
                          # older `image.tag`.
                          runAsNonRoot = true;
                          runAsUser = 65532;
                          runAsGroup = 65532;
                          capabilities = {
                            add = [ "NET_BIND_SERVICE" ];
                            drop = [ "ALL" ];
                          };
                          readOnlyRootFilesystem = true;
                        };
                      }
                      // lib.optionalAttrs (envVars != [ ]) { env = envVars; }
                    )
                  ];
                };
              };
            };
          }
          # The whole ConfigMap, not a subPath, so a file-reading plugin finds
          # the keys an overlay adds beside the Corefile.
          |> kix.withMounts [
            (kix.mount.configMap self.configmap {
              mountPath = "/etc/coredns";
              readOnly = true;
            })
          ]
          |> scope.mkDeployment;

        service =
          self.deployment
          |> kix.service.fromWorkload {
            name = serviceName;
            ports = builtins.filter (p: (p.name or "") != "metrics" || scrape) (
              kix.service.extractPorts self.deployment
            );
            # The labels kubeadm puts on its DNS Service. `kubectl
            # cluster-info` lists Services labelled
            # kubernetes.io/cluster-service=true, by kubernetes.io/name.
            labels = {
              "k8s-app" = "kube-dns";
              "kubernetes.io/cluster-service" = "true";
              "kubernetes.io/name" = "CoreDNS";
            };
            spec.clusterIP = config.clusterIP;
          }
          |> scope.mkResource;

        root = {
          resource = self.service;
          # prometheus-default-rules reads it to skip its own CoreDNS
          # monitor, which would scrape these pods a second time.
          out.scrapedByPrometheus = scrape;
          out.version = kix.image.version config.image;
        };
      }
    )

    (kix.monitor {
      service = "service";
      port = "metrics";
      alerts =
        let
          sel = ''namespace="${scope.namespaceName}", service="${serviceName}"'';
          instance = "CoreDNS ${scope.namespaceName}/${scope.instanceName}";
        in
        {
          CoreDNSDown = {
            expr = "sum by (namespace, service) (up{${sel}}) == 0 or absent(up{${sel}})";
            "for" = "15m";
            severity = "critical";
            summary = "${instance} is down";
            description = "No ${instance} target has been up for 15 minutes; cluster DNS lookups fail. Check the Deployment's pods in ${scope.namespaceName}.";
          };
          CoreDNSLatencyHigh = {
            expr = "histogram_quantile(0.99, sum by (namespace, service, server, zone, le) (rate(coredns_dns_request_duration_seconds_bucket{${sel}}[5m]))) > 4";
            "for" = "10m";
            severity = "warning";
            summary = "${instance} answers slowly";
            description = "The 99th percentile of ${instance} request latency for server {{ $labels.server }} zone {{ $labels.zone }} is {{ $value }}s. Check the upstream servers it forwards to.";
          };
          # The floor of one response a second keeps a single SERVFAIL on a
          # quiet cluster from firing it.
          CoreDNSErrorsHigh = {
            expr = ''sum by (namespace, service) (rate(coredns_dns_responses_total{${sel}, rcode="SERVFAIL"}[5m])) / sum by (namespace, service) (rate(coredns_dns_responses_total{${sel}}[5m])) > 0.03 and sum by (namespace, service) (rate(coredns_dns_responses_total{${sel}}[5m])) > 1'';
            "for" = "10m";
            severity = "warning";
            summary = "${instance} returns SERVFAIL";
            description = "{{ $value | humanizePercentage }} of ${instance} responses are SERVFAIL. Check the upstream servers it forwards to and its log.";
          };
        };
    })
  ];
}
