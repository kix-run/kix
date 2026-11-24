# Tests for the RabbitMQ packages: the refusals of rabbitmq-operator and
# rabbitmq-cluster, each beside a positive control, the rendered
# RabbitmqCluster, its placement and network policy, the broker `out` a
# consumer reads, the webhook check that every RabbitmqCluster waits for,
# the vendored sources' release, and the alert rules of both packages and
# what each is gated on.

{
  lib,
  eval,
  kixlib,
  kixKeys,
  mkCluster,
  manifests,
  ofKind,
  byName,
  evalFails,
  multiZone,
  singleNode,
  alertRulesOf,
  allSelect,
  prometheusStub,
  ...
}:

let
  operatorPackage = import ../../../packages/experimental/rabbitmq-operator;
  clusterPackage = import ../../../packages/experimental/rabbitmq-cluster;
  certManagerPackage = import ../../../packages/experimental/cert-manager;
  ciliumPackage = import ../../../packages/experimental/cilium;

  # A package's failed assertion messages for `config`, evaluated against
  # its options. Throws lose their message in tryEval, so the tests read
  # message text from assertions and check build throws with evalFails.
  failedMessages =
    {
      package,
      instanceName,
      namespaceName ? "messaging",
      config ? { },
    }:
    let
      attrs = eval.callPackagePhase1 {
        inherit package;
        scope = { inherit instanceName namespaceName; };
      };
      evaluated = eval.evaluateInstanceConfig {
        packageOptions = attrs.options;
        instCfg.config.imports = [ config ];
        inherit namespaceName instanceName;
      };
    in
    map (a: a.message) (
      builtins.filter (a: !a.assertion) (
        attrs.assertions {
          config = evaluated;
          deps = { };
        }
      )
    );
  says = fragment: messages: builtins.any (m: lib.hasInfix fragment m) messages;
  clusterMessages =
    config:
    failedMessages {
      package = clusterPackage;
      instanceName = "rabbitmq";
      inherit config;
    };

  # A consumer that reads the broker's `out` into its environment.
  consumerPackage = {
    meta = {
      description = "AMQP consumer stand-in";
      owner = "app-team";
    };
    build =
      {
        self,
        scope,
        kix,
        rabbitmq,
        ...
      }:
      {
        deployment = scope.mkDeployment {
          name = "consumer";
          availability.max = "none";
          spec = {
            replicas = 1;
            selector.matchLabels = scope.selectorLabels;
            template.spec.containers = [
              {
                name = "consumer";
                image = "example.com/consumer:1";
                env = kix.mkEnvVars {
                  AMQP_HOST = rabbitmq.out.host;
                  AMQP_PORT = rabbitmq.out.port;
                  AMQP_VHOST = rabbitmq.out.vhost;
                  AMQP_USERNAME = rabbitmq.out.credentials.out.keyRef "username";
                  AMQP_PASSWORD = rabbitmq.out.credentials.out.keyRef "password";
                };
              }
            ];
          };
        };
        root = self.deployment;
      };
  };

  # The operator, cert-manager, a cluster `rabbitmq`, and, with
  # `consumer`, a consumer of it. `modules` are added to the cluster.
  rabbitmq =
    {
      operatorConfig ? { },
      clusterConfig ? { },
      consumer ? false,
      modules ? [ ],
    }:
    mkCluster (
      [
        {
          instances.cert-manager.cert-manager.package = certManagerPackage;
          instances.rabbitmq-system.rabbitmq-operator = {
            package = operatorPackage;
            config = operatorConfig;
          };
          instances.messaging = {
            rabbitmq = {
              package = clusterPackage;
              config = clusterConfig;
            };
          }
          // lib.optionalAttrs consumer {
            consumer.package = consumerPackage;
          };
        }
      ]
      ++ modules
    );
  ms = cluster: manifests cluster;
  clusterOf = all: byName "rabbitmq" (ofKind "RabbitmqCluster" all);
  dependsOn = m: m.metadata.annotations.${kixKeys.dependsOn} or "";
  withPrometheus.instances.monitoring.prometheus.package = prometheusStub;

  # Cilium as the enforcer, as the environment's CNI.
  cilium = {
    cluster.roles.cni = {
      binding = "shadowable";
      provider = "cilium (environment)";
    };
    networkPolicy.enable = true;
    instances.net.cilium.package = ciliumPackage;
    instances.net.platform-cilium.package = eval.mkImport {
      roles = [ "cni" ];
      out.helmChartConfig = null;
    };
  };
in
{
  # Every RabbitmqCluster waits for the webhook check, and the check is a
  # server-side dry-run create of a RabbitmqCluster.
  rabbitmq-operator-crd-handle-gated =
    let
      cluster = rabbitmq { };
      all = ms cluster;
      operator = cluster.instances.rabbitmq-system.rabbitmq-operator;
      jobHash = builtins.unsafeDiscardStringContext operator.raw.webhookCheck.out.identityHash;
      customResources = builtins.filter (m: lib.hasPrefix "rabbitmq.com/" m.apiVersion) all;
      ungated = map (m: "${m.kind}/${m.metadata.name}") (
        builtins.filter (m: !(lib.hasInfix jobHash (dependsOn m))) customResources
      );
      container = builtins.head (byName "rabbitmq-operator-webhook-check" (ofKind "Job" all))
        .spec.template.spec.containers;
    in
    (
      ungated == [ ]
      && map (m: m.kind) customResources == [ "RabbitmqCluster" ]
      &&
        container.args == [
          "create"
          "--dry-run=server"
          "--output=name"
          "--filename=/check/rabbitmqcluster.json"
        ]
    )
    || throw "webhook-check gate: ${
      builtins.toJSON {
        inherit ungated;
        inherit (container) args;
      }
    }";

  # The webhook entries call the package's Service, leave caBundle to
  # cainjector through the inject-ca-from annotation, and the Certificate is
  # issued for the name the API server calls.
  rabbitmq-operator-webhooks =
    let
      all = ms (rabbitmq { });
      config = kind: byName "rabbitmq-operator-rabbitmq-system" (ofKind kind all);
      entries = kind: (config kind).webhooks;
      inject = kind: (config kind).metadata.annotations."cert-manager.io/inject-ca-from";
      both = entries "MutatingWebhookConfiguration" ++ entries "ValidatingWebhookConfiguration";
      certificate = byName "rabbitmq-operator-webhook" (ofKind "Certificate" all);
    in
    (
      map (w: w.name) both == [
        "mrabbitmqcluster-v1beta1.kb.io"
        "vrabbitmqcluster-v1beta1.kb.io"
      ]
      &&
        map (w: w.clientConfig.service.name) both == [
          "rabbitmq-operator-webhook"
          "rabbitmq-operator-webhook"
        ]
      && builtins.all (w: w.failurePolicy == "Fail" && !(w.clientConfig ? caBundle)) both
      && inject "MutatingWebhookConfiguration" == "rabbitmq-system/rabbitmq-operator-webhook"
      && inject "ValidatingWebhookConfiguration" == "rabbitmq-system/rabbitmq-operator-webhook"
      && certificate.metadata.name == "rabbitmq-operator-webhook"
      && certificate.spec.dnsNames == [ "rabbitmq-operator-webhook.rabbitmq-system.svc" ]
    )
    || throw "webhooks: ${
      builtins.toJSON {
        inherit both;
        inherit (certificate) metadata spec;
      }
    }";

  # An operator image of another minor than the vendored definition is
  # refused; another patch of the release minor is not.
  rabbitmq-operator-image-minor =
    let
      got = failedMessages {
        package = operatorPackage;
        instanceName = "rabbitmq-operator";
        config.image.tag = "2.22.5";
      };
      fine = failedMessages {
        package = operatorPackage;
        instanceName = "rabbitmq-operator";
        config.image.tag = "2.23.1";
      };
    in
    (says ''image.tag "2.22.5" is not a RabbitMQ Cluster Operator 2.23 release'' got && fine == [ ])
    || throw "rabbitmq-operator image refusal: ${builtins.toJSON { inherit got fine; }}";

  # Operator variables the package owns or refuses fail the build; another
  # variable passes.
  rabbitmq-operator-env-refusals =
    let
      withEnv = env: rabbitmq { operatorConfig = { inherit env; }; };
    in
    (
      evalFails (withEnv {
        OPERATOR_NAMESPACE = "messaging";
      })
      && evalFails (withEnv {
        OPERATOR_SCOPE_NAMESPACE = "messaging";
      })
      && evalFails (withEnv {
        ENABLE_WEBHOOKS = "false";
      })
      && evalFails (withEnv {
        CONTROL_RABBITMQ_IMAGE = "true";
      })
      && !evalFails (withEnv {
        LEASE_DURATION = "30";
      })
    )
    || throw "rabbitmq-operator env refusals: one did not fail, or the control failed";

  # The vendored definition and roles come from the package's release.
  rabbitmq-operator-sources-match-release =
    let
      urls =
        file:
        builtins.filter (l: l != "" && !lib.hasPrefix "#" l) (
          map (l: builtins.head (lib.splitString " " (lib.trim l))) (
            lib.splitString "\n" (builtins.readFile file)
          )
        );
      release =
        (operatorPackage {
          scope = {
            instanceName = "rabbitmq-operator";
            namespaceName = "rabbitmq-system";
          };
          inherit lib;
          kix = kixlib;
          availability = "none";
        }).meta.version;
      dir = ../../../packages/experimental/rabbitmq-operator;
      stray = builtins.filter (u: !(lib.hasInfix "/v${release}/" u)) (
        urls (dir + "/crds/sources.txt") ++ urls (dir + "/rbac/sources.txt")
      );
    in
    stray == [ ] || throw "sources.txt URLs not at ${release}: ${builtins.toJSON stray}";

  # A volume under 5GB warns on storage.size. The default size does not.
  rabbitmq-cluster-small-volume-warns =
    let
      storageWarnings =
        clusterConfig:
        builtins.filter (w: (w.option or null) == "storage.size")
          (rabbitmq {
            modules = [ singleNode ];
            inherit clusterConfig;
          }).instances.messaging.rabbitmq._diagnostics.warnings;
    in
    (
      builtins.length (storageWarnings {
        storage.size = "2Gi";
      }) == 1
      && storageWarnings { } == [ ]
    )
    || throw "rabbitmq small volume warning";

  # The rendered RabbitmqCluster at availability none: one node, the image,
  # the volumes, settings as rabbitmq.conf lines, the operator's own spread
  # off, and no PodDisruptionBudget. At zone: three nodes spread over zones,
  # and a PodDisruptionBudget over the RabbitMQ pods.
  rabbitmq-cluster-spec =
    let
      oneAll = ms (rabbitmq {
        modules = [ singleNode ];
        clusterConfig.settings = {
          "vm_memory_high_watermark.relative" = "0.6";
          "log.console.level" = "info";
        };
      });
      one = clusterOf oneAll;
      zoneAll = ms (rabbitmq {
        modules = [ (lib.recursiveUpdate multiZone { cluster.availability.default = "zone"; }) ];
      });
      zone = (clusterOf zoneAll).spec;
      selector = {
        "app.kubernetes.io/name" = "rabbitmq";
        "app.kubernetes.io/component" = "rabbitmq";
        "app.kubernetes.io/part-of" = "rabbitmq";
      };
      pdbsIn =
        all: builtins.filter (m: m.metadata.namespace == "messaging") (ofKind "PodDisruptionBudget" all);
      pdbs = pdbsIn zoneAll;
      spread = zone.override.statefulSet.spec.template.spec.topologySpreadConstraints;
    in
    (
      lib.hasPrefix "docker.io/library/rabbitmq:4.4.1-management@sha256:" one.spec.image
      && one.spec.replicas == 1
      && one.spec.persistence.storage == "10Gi"
      &&
        one.spec.rabbitmq.additionalConfig
        == "log.console.level = info\nvm_memory_high_watermark.relative = 0.6\n"
      && one.metadata.annotations."rabbitmq.com/disable-default-topology-spread-constraints" == "true"
      && !(one.spec ? override)
      && pdbsIn oneAll == [ ]
      && zone.replicas == 3
      && builtins.all (c: c.labelSelector.matchLabels == selector) spread
      && builtins.any (c: c.topologyKey == "topology.kubernetes.io/zone") spread
      &&
        map (p: p.spec) pdbs == [
          {
            maxUnavailable = 1;
            selector.matchLabels = selector;
          }
        ]
    )
    || throw "RabbitmqCluster spec: ${
      builtins.toJSON {
        inherit one zone;
        pdbs = map (p: p.spec) pdbs;
      }
    }";

  # rabbitmq-cluster's assertions, one message each, and none for a config
  # that sets an odd replica count, an unowned key, and an extraSpec plugin.
  rabbitmq-cluster-refusals =
    let
      longName = failedMessages {
        package = clusterPackage;
        instanceName = "a" + lib.concatStrings (lib.replicate 45 "b");
      };
      even = clusterMessages { replicas = 2; };
      badKey = clusterMessages { settings."log level" = "info"; };
      multiline = clusterMessages {
        settings."log.console.level" = "info\nlisteners.tcp.default = 5673";
      };
      listener = clusterMessages { settings."listeners.tcp.default" = 5673; };
      listenerOff = clusterMessages { settings."listeners.tcp" = "none"; };
      formation = clusterMessages {
        settings."cluster_formation.peer_discovery_backend" = "classic_config";
      };
      defaultPass = clusterMessages { settings.default_pass = "secret"; };
      password = clusterMessages { settings."auth_ldap.dn_lookup_bind.password" = "secret"; };
      secretBackend = clusterMessages { extraSpec.secretBackend.externalSecret.name = "creds"; };
      tlsOnly = clusterMessages { extraSpec.tls.disableNonTLSListeners = true; };
      envPort = clusterMessages { extraSpec.rabbitmq.envConfig = "RABBITMQ_DIST_PORT=25000"; };
      fine = clusterMessages {
        replicas = 5;
        settings = {
          default_vhost = "app";
          collect_statistics_interval = 10000;
          "log.console" = true;
        };
        extraSpec.rabbitmq = {
          additionalPlugins = [ "rabbitmq_shovel" ];
          envConfig = "SERVER_ADDITIONAL_ERL_ARGS=\"+S 2:2\"";
        };
      };
    in
    (
      says "must be a DNS-1035 label of at most 45 characters" longName
      && says "replicas is 2" even
      && says ''settings key "log level" contains whitespace'' badKey
      && says ''settings."log.console.level" contains a line break'' multiline
      && says ''settings sets "listeners.tcp.default", which the package owns'' listener
      && says ''settings sets "listeners.tcp", which the package owns'' listenerOff
      && says ''settings sets "cluster_formation.peer_discovery_backend", which the package owns'' formation
      && says ''settings sets "default_pass", which the package owns'' defaultPass
      && says ''settings sets "auth_ldap.dn_lookup_bind.password". The operator writes settings into the ConfigMap'' password
      && says "extraSpec sets secretBackend" secretBackend
      && says "extraSpec sets tls.disableNonTLSListeners" tlsOnly
      && says "extraSpec.rabbitmq.envConfig sets RABBITMQ_DIST_PORT" envPort
      && fine == [ ]
    )
    || throw "rabbitmq-cluster refusals: ${
      builtins.toJSON {
        inherit
          longName
          even
          badKey
          multiline
          listener
          listenerOff
          formation
          defaultPass
          password
          secretBackend
          tlsOnly
          envPort
          fine
          ;
      }
    }";

  # extraSpec cannot set a path an option owns; another path passes.
  rabbitmq-cluster-extra-spec-locks =
    let
      withSpec = extraSpec: rabbitmq { clusterConfig = { inherit extraSpec; }; };
    in
    (
      evalFails (withSpec {
        replicas = 3;
      })
      && evalFails (withSpec {
        image = "rabbitmq:4";
      })
      && evalFails (withSpec {
        persistence.storage = "1Gi";
      })
      && evalFails (withSpec {
        override.statefulSet.spec.template.metadata.labels."app.kubernetes.io/part-of" = "other";
      })
      && !evalFails (withSpec {
        override.statefulSet.spec.template.metadata.labels."example.com/team" = "messaging";
      })
      && evalFails (withSpec {
        rabbitmq.additionalConfig = "default_user = admin";
      })
      && !evalFails (withSpec {
        rabbitmq.additionalPlugins = [ "rabbitmq_shovel" ];
      })
    )
    || throw "rabbitmq-cluster extraSpec locks: a locked path passed, or the control failed";

  # A consumer reads the client Service, the AMQP port, the vhost from
  # settings, and the default-user Secret by reference, and depends on the
  # Service and Secret references, which require the RabbitmqCluster.
  rabbitmq-cluster-out =
    let
      cluster = rabbitmq {
        consumer = true;
        clusterConfig.settings.default_vhost = "app";
      };
      all = ms cluster;
      deployment = byName "consumer" (ofKind "Deployment" all);
      env = builtins.listToAttrs (
        map (e: lib.nameValuePair e.name e) (builtins.head deployment.spec.template.spec.containers).env
      );
      # A Service or Secret reference's out.name carries the reference's
      # identity path, whose store hash depends-on lists.
      refHash =
        part:
        builtins.substring 11 32 (
          builtins.head (
            builtins.attrNames (builtins.getContext cluster.instances.messaging.rabbitmq.raw.${part}.out.name)
          )
        );
    in
    (
      lib.hasPrefix "rabbitmq.messaging.svc." env.AMQP_HOST.value
      && env.AMQP_PORT.value == "5672"
      && env.AMQP_VHOST.value == "app"
      &&
        env.AMQP_USERNAME.valueFrom.secretKeyRef == {
          name = "rabbitmq-default-user";
          key = "username";
        }
      && env.AMQP_PASSWORD.valueFrom.secretKeyRef.name == "rabbitmq-default-user"
      && lib.hasInfix (refHash "client") (dependsOn deployment)
      && lib.hasInfix (refHash "defaultUser") (dependsOn deployment)
    )
    || throw "broker out: ${
      builtins.toJSON {
        inherit env;
        dependsOn = dependsOn deployment;
      }
    }";

  # Without default_vhost, out.vhost is RabbitMQ's default vhost.
  rabbitmq-cluster-default-vhost =
    let
      vhost = (rabbitmq { }).instances.messaging.rabbitmq.out.vhost;
    in
    vhost == "/" || throw "default vhost: ${vhost}";

  # Under an enforcer: the RabbitMQ pods reach each other on epmd and
  # Erlang distribution, the operator reaches the management API from its
  # namespace at both ends, and a consumer gets AMQP. The pods get API
  # server egress only for an image tag below 4.1 or one with no version.
  rabbitmq-cluster-network-policy =
    let
      all = ms (rabbitmq {
        consumer = true;
        modules = [ cilium ];
      });
      policy = name: (byName name (ofKind "CiliumNetworkPolicy" all)).spec;
      portsOf = rule: map (p: p.port) (builtins.head rule.toPorts).ports;
      egress = (policy "rabbitmq-operand-egress").egress;
      ingress = (policy "rabbitmq-operand-ingress").ingress;
      operatorEgress = policy "messaging-rabbitmq-operator-egress";
      consumerEgress = (policy "consumer-deployment-consumer-egress").egress;
      # API server egress for the peer discovery backend only below 4.1.
      apiEgress =
        tag:
        builtins.any (r: r ? toEntities && builtins.elem "kube-apiserver" r.toEntities) (
          (byName "rabbitmq-operand-egress" (
            ofKind "CiliumNetworkPolicy" (
              ms (rabbitmq {
                clusterConfig.image.tag = tag;
                modules = [ cilium ];
              })
            )
          )).spec.egress
        );
    in
    (
      !(builtins.any (r: r ? toEntities && builtins.elem "kube-apiserver" r.toEntities) egress)
      && apiEgress "4.0.9-management"
      && apiEgress "management"
      && !apiEgress "4.1.0-management"
      && builtins.any (
        r:
        r ? toPorts
        &&
          portsOf r == [
            "4369"
            "25672"
          ]
      ) egress
      &&
        map portsOf ingress == [
          [
            "4369"
            "25672"
          ]
          [ "15672" ]
        ]
      &&
        (builtins.elemAt ingress 1).fromEndpoints == [
          {
            matchLabels = {
              "app.kubernetes.io/instance" = "rabbitmq-operator";
              "app.kubernetes.io/name" = "rabbitmq-operator";
              "k8s:io.kubernetes.pod.namespace" = "rabbitmq-system";
            };
          }
        ]
      && map portsOf operatorEgress.egress == [ [ "15672" ] ]
      && builtins.any (r: r ? toPorts && portsOf r == [ "5672" ]) consumerEgress
    )
    || throw "network policy: ${
      builtins.toJSON {
        inherit
          egress
          ingress
          operatorEgress
          consumerEgress
          ;
      }
    }";

  # An operator dependency without the operator's out (an import) is
  # refused; the managed operator (rabbitmq-cluster-out) evaluates. An
  # operator of another minor is refused by the dependency assertion.
  rabbitmq-cluster-operator-dependency =
    let
      imported = mkCluster [
        {
          instances.rabbitmq-system.rabbitmq-operator = {
            package = eval.mkImport { out.release = "2.23.0"; };
            aliases = [ "rabbitmqOperator" ];
          };
          instances.messaging.rabbitmq.package = clusterPackage;
        }
      ];
      depCheck =
        release:
        builtins.filter (a: !a.assertion) (
          (clusterPackage {
            scope = {
              instanceName = "rabbitmq";
              namespaceName = "messaging";
            };
            inherit lib;
            kix = kixlib;
            availability = "none";
          }).deps.rabbitmqOperator.assertions
            { out.release = release; }
        );
    in
    (
      evalFails imported
      && says "runs 2.22.5" (map (a: a.message) (depCheck "2.22.5"))
      && depCheck "2.23.4" == [ ]
    )
    || throw "rabbitmq-cluster operator dependency: the import passed, or the release check is wrong";

  # The rules select the PodMonitor's job, need a prometheus dependency and
  # metrics.enabled, and add the majority and identity rules from two
  # replicas, with the majority taken from `replicas`.
  rabbitmq-cluster-alerts =
    let
      rulesOf =
        {
          clusterConfig ? { },
          modules ? [ withPrometheus ],
        }:
        alertRulesOf "PrometheusRule" "rabbitmq" (
          ms (rabbitmq {
            inherit clusterConfig modules;
          })
        );
      one = rulesOf { clusterConfig.replicas = 1; };
      three = rulesOf { clusterConfig.replicas = 3; };
      five = rulesOf { clusterConfig.replicas = 5; };
      replicated = [
        "RabbitMQQuorumLost"
        "RabbitMQClusterIdentityMismatch"
        "RabbitMQDistributionLinksMissing"
      ];
      sel = ''namespace="messaging",job="messaging/rabbitmq"'';
    in
    (
      allSelect sel one
      && allSelect sel three
      && one ? RabbitMQDown
      && one ? RabbitMQMemoryAlarm
      && !lib.any (n: one ? ${n}) replicated
      && lib.all (n: three ? ${n}) replicated
      && lib.hasSuffix "< 2" three.RabbitMQQuorumLost.expr
      && lib.hasSuffix "< 3" five.RabbitMQQuorumLost.expr
      && lib.hasSuffix "< 4" five.RabbitMQDistributionLinksMissing.expr
      && rulesOf { modules = [ ]; } == null
      && rulesOf { clusterConfig.metrics.enabled = false; } == null
    )
    || throw "rabbitmq-cluster alerts: one ${builtins.toJSON (builtins.attrNames one)}, three ${builtins.toJSON (builtins.attrNames three)}";

  # The operator's rules select its metrics Service and need a prometheus
  # dependency and metrics.enabled.
  rabbitmq-operator-alerts =
    let
      rulesOf =
        {
          operatorConfig ? { },
          modules ? [ withPrometheus ],
        }:
        alertRulesOf "PrometheusRule" "rabbitmq-operator" (
          ms (rabbitmq {
            inherit operatorConfig modules;
          })
        );
      rules = rulesOf { };
    in
    (
      allSelect ''namespace="rabbitmq-system",service="rabbitmq-operator-metrics"'' rules
      &&
        builtins.attrNames rules == [
          "RabbitMQOperatorDown"
          "RabbitMQOperatorReconcileErrors"
        ]
      && rulesOf { modules = [ ]; } == null
      && rulesOf { operatorConfig.metrics.enabled = false; } == null
    )
    || throw "rabbitmq-operator alerts: ${builtins.toJSON (builtins.attrNames rules)}";
}
