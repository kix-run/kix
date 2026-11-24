# ingress-nginx: the NGINX Ingress controller, which serves the Ingresses of
# its IngressClass. Deprecated: Kubernetes retired the project in March 2026
# after v1.15.1, the release this package runs, and it gets no security
# fixes. Route through Gateway API instead, with the traefik or envoy-gateway
# package.
#
# Installs the controller Deployment, its Service, ConfigMap, ServiceAccount,
# and RBAC, an IngressClass, and a validating admission webhook whose
# certificate two certgen Jobs create and patch into the webhook
# configuration. `metrics.enabled` turns on the controller's Prometheus
# metrics; with the optional `prometheus` dep it also adds Service
# <name>-metrics and a ServiceMonitor.
#
# root = the Deployment, whose `out` adds `version`, the controller version
# `image.tag` names. The controller exits at startup when its
# `--publish-service` Service does not exist. The argument reads the
# Service's name, which orders the Service first, so the Service selects the
# pods through `rawSelector`, which does not wait for the Deployment.
#
# Defaults are upstream's: snippet annotations off, annotation risk level
# High, forwarded headers not trusted, and an IngressClass that is not the
# cluster default.
#
# Known limits:
# - The webhook configuration has failurePolicy Fail and matches every
#   Ingress in the cluster, whatever its class. While any instance's
#   controller is unavailable, every Ingress create and update fails.
# - IngressClass names are cluster-scoped, so instances in two namespaces
#   need different `ingressClassName` values.
# - The controller runs with a writable root filesystem, as upstream's
#   does, and has no default resource limits.
#
# No dependency or option is required:
#
#   instances.ingress-nginx.ingress-nginx.package = packages.experimental.ingress-nginx;
#
# `out`:
#   out.ingressClassName
#       The IngressClass name. A consumer that reads it orders its Ingress
#       after the controller is serving and the webhook has its CA.
#   out.podSelector, out.podNamespace
#       Where the controller pods run, for the policy that lets them reach
#       an exposed backend.
#
# Escape hatches: `settings` (the controller ConfigMap), `extraArgs`, `env`,
# `service.spec`, `service.annotations`, and the instance's `partsOverlays`.

{
  scope,
  lib,
  kix,
  availability,
}:

let
  release = "v1.15.1";
  # kube-webhook-certgen versions separately from the controller; v1.6.9 is
  # the release upstream deploys with controller v1.15.1.
  certgenRelease = "v1.6.9";

  name = scope.instanceName;
  # Cluster-scoped objects carry the namespace too, so instances with the
  # same name in two namespaces do not collide. Namespace `a-b` with
  # instance `c` and namespace `a` with instance `b-c` still give the same
  # name, and the build fails with a Duplicate resource error.
  clusterName = "${scope.namespaceName}-${name}";

  selectorLabels = {
    "app.kubernetes.io/name" = "ingress-nginx";
    "app.kubernetes.io/instance" = name;
    "app.kubernetes.io/component" = "controller";
  };
  labelsFor = component: selectorLabels // { "app.kubernetes.io/component" = component; };
  admissionLabels = labelsFor "admission-webhook";

  inherit (scope.rbac)
    group
    core
    grant
    watch
    emit
    allow
    restrictTo
    mkClusterRoleSet
    mkRoleSet
    ;
  net = group "networking.k8s.io" [
    "ingresses"
    "ingressclasses"
  ];
  disco = group "discovery.k8s.io" [ "endpointslices" ];
  coord = group "coordination.k8s.io" [ "leases" ];
  adm = group "admissionregistration.k8s.io" [ "validatingwebhookconfigurations" ];

  tcp = port: {
    inherit port;
    protocol = "TCP";
  };
in
{
  meta = {
    version = release;
    description = "NGINX Ingress controller (deprecated: retired by Kubernetes in March 2026, no security fixes; use traefik)";
    owner = "platform";
    deprecated = {
      message = "Kubernetes retired ingress-nginx in March 2026 after v1.15.1, so it no longer receives security fixes. Kix still builds this instance. Move Ingress routes to Gateway API";
      replacement = "packages.experimental.traefik";
    };
    defaultAliases = [ "ingressNginx" ];
    # One controller serves Ingress objects in every namespace, so consumers
    # in any namespace find it by name.
    scope = "cluster";
    k8s.minVersion = "1.25";
    network.intents = {
      # Ingress objects name their backends at runtime, on any port, so the
      # graph cannot see the controller's upstream connections.
      backends.egress = [ { to = "pods"; } ];
      # Clients outside the cluster, plus in-cluster clients and NodePort
      # traffic that arrives SNATed from a node.
      front-door.ingress = [
        {
          from = "world";
          ports = [
            (tcp 80)
            (tcp 443)
          ];
        }
        {
          from = "all-pods";
          ports = [
            (tcp 80)
            (tcp 443)
          ];
        }
      ];
      # The API server calls the admission webhook through the
      # ValidatingWebhookConfiguration, which is not a pod-to-pod edge.
      webhook.ingress = [
        {
          from = "apiserver";
          ports = [ (tcp 8443) ];
        }
      ];
    };
  };

  options = {
    image = kix.options.image {
      repository = "registry.k8s.io/ingress-nginx/controller";
      tag = release;
      digest = "sha256:594ceea76b01c592858f803f9ff4d2cb40542cae2060410b2c95f75907d659e1";
      description = "Image of the controller.";
    };
    certgen.image = kix.options.image {
      repository = "registry.k8s.io/ingress-nginx/kube-webhook-certgen";
      tag = certgenRelease;
      digest = "sha256:01038e7de14b78d702d2849c3aad72fd25903c4765af63cf16aa3398f5d5f2dd";
      description = "Image of the Jobs that create the admission webhook certificate and patch its CA into the webhook configuration.";
    };
    certgen.resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "20Mi";
      };
      description = ''
        Resource requests and limits for the two certgen Jobs, which run for
        a few seconds per deploy. Each field keeps its default until set,
        and null removes a default.
      '';
    };
    replicas = lib.mkOption {
      type = lib.types.ints.positive;
      # Two controllers once a pod restart must not drop ingress traffic,
      # spread so either survives a lost node or zone.
      default = kix.availability.pick availability {
        none = 1;
        pod = 2;
        node = 2;
        zone = 2;
      };
      defaultText = lib.literalMD "1, 2, 2, or 3 for the cluster's availability level `none`, `pod`, `node`, or `zone`";
      description = "Controller replicas. Every replica serves traffic; leader election only decides which one writes Ingress status.";
    };
    ingressClassName = lib.mkOption {
      # The API server's rule for an IngressClass name: a lowercase DNS-1123
      # subdomain. The length limit follows from the controller value.
      type = lib.types.strMatching "[a-z0-9]([-a-z0-9.]*[a-z0-9])?";
      default = name;
      defaultText = lib.literalExpression "scope.instanceName";
      description = ''
        Name of the IngressClass this controller serves, the name an Ingress
        sets in `spec.ingressClassName`: lowercase letters, digits, `-`, and
        `.`, starting and ending with a letter or digit. The class's
        controller value is `k8s.io/ingress-nginx/<namespace>/<name>`, which
        must fit in 250 characters. IngressClasses are cluster-scoped, so
        instances in different namespaces need different names.
      '';
    };
    isDefaultClass = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Mark the IngressClass as the cluster default, so Ingresses that name
        no class use this controller. Ingresses rendered by Kix always name
        their class. A cluster may have only one default class; with two,
        the API server rejects every Ingress that names none.
      '';
    };
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        proxy-body-size = "50m";
        ssl-protocols = "TLSv1.3";
      };
      description = ''
        Data of the controller's ConfigMap, with upstream's keys and string
        values (ingress-nginx "ConfigMap" documentation). Snippet
        annotations need both `allow-snippet-annotations = "true"` and
        `annotations-risk-level = "Critical"`. Trust `X-Forwarded-*`
        headers (`use-forwarded-headers`) only behind a proxy that sets them.
      '';
    };
    service = {
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Annotations on the controller Service, such as a cloud provider's load balancer settings.";
      };
      nodePorts = {
        http = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "nodePort of the Service's http port. Null lets Kubernetes choose. Needs `service.spec.type` NodePort or LoadBalancer.";
        };
        https = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "nodePort of the Service's https port. Null lets Kubernetes choose. Needs `service.spec.type` NodePort or LoadBalancer.";
        };
      };
      spec = lib.mkOption {
        default = { };
        description = ''
          Fields of the controller Service's `spec`, with Kubernetes field
          names (`loadBalancerClass`, `loadBalancerSourceRanges`,
          `ipFamilyPolicy`, ...). The package sets `selector` and `ports`;
          set node ports through `service.nodePorts`.
        '';
        type = lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.anything;
          options = {
            type = lib.mkOption {
              type = lib.types.enum [
                "ClusterIP"
                "NodePort"
                "LoadBalancer"
              ];
              default = "ClusterIP";
              description = "Service type. LoadBalancer needs a load balancer provider in the cluster.";
            };
            externalTrafficPolicy = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.enum [
                  "Cluster"
                  "Local"
                ]
              );
              default = null;
              description = "`Local` keeps client source addresses on NodePort and LoadBalancer Services. Null leaves the Kubernetes default, `Cluster`.";
            };
          };
        };
      };
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--watch-ingress-without-class=true" ];
      description = ''
        Flags appended to the controller's arguments. A flag the package
        sets or derives from (`--publish-service`, `--election-id`,
        `--controller-class`, `--ingress-class`, `--configmap`,
        `--enable-metrics`, the port flags `--http-port`, `--https-port`,
        and `--healthz-port`, and the `--validating-webhook*` flags) is
        refused, and the error says what to do instead.
      '';
    };
    env = kix.options.env // {
      description = ''
        Extra environment variables for the controller. A value is a string,
        a `fieldRef` source, or a `secretKeyRef` source naming a Secret
        managed outside Kix with `kix.untrackedRef`. The package sets
        `POD_NAME`, `POD_NAMESPACE`, and `LD_PRELOAD`.
      '';
    };
    resources = kix.options.resources {
      requests = {
        cpu = "100m";
        memory = "90Mi";
      };
      description = ''
        Resource requests and limits for the controller container. There is
        no default limit: nginx starts one worker per CPU, so memory use
        follows the node's CPU count. Each field keeps its default until
        set, and null removes a default.
      '';
    };
    metrics = kix.options.monitor;
  };

  build = [
    (
      {
        self,
        config,
        prometheus ? null,
        ...
      }:
      let
        # The namespace makes the value differ between instances in two
        # namespaces, so two IngressClasses with one name are reported as a
        # Duplicate resource instead of being merged into one object that
        # both controllers serve.
        controllerValue =
          let
            value = "k8s.io/ingress-nginx/${scope.namespaceName}/${config.ingressClassName}";
          in
          if builtins.stringLength value > 250 then
            scope.fail {
              option = "ingressClassName";
              message = "The IngressClass controller value \"${value}\" is longer than the API server's 250-character limit.";
              fix = "Shorten ingressClassName.";
            }
          else
            value;
        serviceType = config.service.spec.type;
        metricsOn = config.metrics.enabled && prometheus != null;

        # The controller parses booleans with Go's strconv.ParseBool, which
        # also accepts "1", "t", and "True". Other spellings are refused so
        # the Critical-risk check below cannot be bypassed. The controller
        # compares the risk level in lower case.
        snippets = config.settings."allow-snippet-annotations" or null;
        riskLevel = lib.toLower (config.settings."annotations-risk-level" or "");
        settings =
          if snippets != null && snippets != "true" && snippets != "false" then
            scope.fail {
              option = "settings.\"allow-snippet-annotations\"";
              message = "settings.\"allow-snippet-annotations\" is \"${snippets}\".";
              fix = "Use \"true\" or \"false\".";
            }
          else if snippets == "true" && riskLevel != "critical" then
            scope.fail {
              option = "settings.\"allow-snippet-annotations\"";
              message = "settings.\"allow-snippet-annotations\" is \"true\", but snippet annotations are Critical risk and the admission webhook rejects them unless settings.\"annotations-risk-level\" is \"Critical\".";
              fix = "Set both, or neither.";
            }
          else
            config.settings;

        nodePortsSet = lib.filterAttrs (_: p: p != null) config.service.nodePorts;
        # mergeGuarded below refuses these keys too, but its message cannot
        # name the option to use instead.
        serviceSpecOwned = {
          selector = "selects the controller pods. Remove it.";
          ports = "defines ports http and https. Set node ports with service.nodePorts.http and service.nodePorts.https, and remove service.spec.ports.";
        };
        serviceSpecOwnedHits = builtins.filter (k: (config.service.spec.${k} or null) != null) (
          builtins.attrNames serviceSpecOwned
        );
        serviceSpec =
          if serviceSpecOwnedHits != [ ] then
            scope.fail (
              map (k: {
                option = "service.spec.${k}";
                message = "service.spec.${k} is set by the package, which ${serviceSpecOwned.${k}}";
              }) serviceSpecOwnedHits
            )
          else if serviceType == "ClusterIP" && nodePortsSet != { } then
            scope.fail {
              option = "service.nodePorts";
              message = "service.nodePorts sets ${lib.concatStringsSep ", " (builtins.attrNames nodePortsSet)}, which needs service.spec.type NodePort or LoadBalancer; the type is ClusterIP.";
            }
          else if serviceType == "ClusterIP" && config.service.spec.externalTrafficPolicy != null then
            scope.fail {
              option = "service.spec.externalTrafficPolicy";
              message = "service.spec.externalTrafficPolicy applies to NodePort and LoadBalancer Services, and the API server rejects it on ClusterIP.";
              fix = "Change service.spec.type or remove it.";
            }
          else
            kix.mergeGuarded
              {
                inherit scope;
                option = "service.spec";
                locked = [
                  [ "selector" ]
                  [ "ports" ]
                ];
              }
              {
                # rawSelector reads the Deployment's labels without forcing
                # its manifest, which requires this Service.
                selector = self.deployment.rawSelector;
                ports =
                  map
                    (
                      p:
                      p
                      // lib.optionalAttrs (config.service.nodePorts.${p.name} != null) {
                        nodePort = config.service.nodePorts.${p.name};
                      }
                    )
                    [
                      {
                        name = "http";
                        port = 80;
                        targetPort = 80;
                        appProtocol = "http";
                      }
                      {
                        name = "https";
                        port = 443;
                        targetPort = 443;
                        appProtocol = "https";
                      }
                    ];
              }
              (lib.filterAttrs (_: v: v != null) config.service.spec);

        # The controller parses flags with pflag (pkg/flags/flags.go
        # upstream).
        args = kix.mergeArgs {
          inherit scope;
          parser = "gnu";
          args = [
            "/nginx-ingress-controller"
            {
              owned = [ "--publish-service=$(POD_NAMESPACE)/${self.service.out.name}" ];
              reason = "Ingress status must publish the address of this instance's Service.";
            }
            {
              owned = [ "--election-id=${name}-leader" ];
              reason = "the leader-election Role only allows updating Lease \"${name}-leader\".";
            }
            {
              owned = [ "--controller-class=${controllerValue}" ];
              from = "the ingressClassName option";
              fix = "Set ingressClassName instead.";
            }
            {
              owned = [ "--ingress-class=${config.ingressClassName}" ];
              from = "the ingressClassName option";
              fix = "Set ingressClassName instead.";
            }
            {
              owned = [ "--configmap=$(POD_NAMESPACE)/${self.configmap.out.name}" ];
              reason = "this package renders the controller's ConfigMap from settings.";
              fix = "Set settings instead.";
            }
            {
              owned = [ "--validating-webhook=:8443" ];
              reason = "the admission webhook Service connects to port 8443.";
            }
            {
              owned = [ "--validating-webhook-certificate=/usr/local/certificates/cert" ];
              reason = "the package mounts the admission TLS certificate at /usr/local/certificates/cert.";
            }
            {
              owned = [ "--validating-webhook-key=/usr/local/certificates/key" ];
              reason = "the package mounts the admission TLS private key at /usr/local/certificates/key.";
            }
            {
              names = [ "--http-port" ];
              reason = "the Service, container ports, and network policy use port 80.";
            }
            {
              names = [ "--https-port" ];
              reason = "the Service, container ports, and network policy use port 443.";
            }
            {
              names = [ "--healthz-port" ];
              reason = "the probes and the metrics Service use port 10254.";
            }
            # Upstream's default is false, which serves only Go runtime
            # metrics on :10254. The flag follows the toggle alone, so adding
            # a prometheus instance does not restart the controller.
            {
              owned = lib.optional config.metrics.enabled "--enable-metrics=true";
              names = [ "--enable-metrics" ];
              from = "the metrics.enabled option";
              fix = "Set metrics.enabled instead.";
            }
          ];
        } config.extraArgs;

        env = kix.mkEnvVars (
          kix.mergeEnv {
            inherit scope;
            owned = [
              {
                vars = {
                  POD_NAME.valueFrom.fieldRef.fieldPath = "metadata.name";
                  POD_NAMESPACE.valueFrom.fieldRef.fieldPath = "metadata.namespace";
                };
                from = "the pod's own metadata, which the controller reads for --publish-service and leader election";
                fix = "Remove it.";
              }
              {
                vars.LD_PRELOAD = "/usr/local/lib/libmimalloc.so";
                from = "the controller image's mimalloc allocator";
                fix = "Remove it.";
              }
            ];
          } config.env
        );

        controllerSubjects = [
          {
            kind = "ServiceAccount";
            name = self.serviceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];
        admissionSubjects = [
          {
            kind = "ServiceAccount";
            name = self.admissionServiceAccount.out.name;
            namespace = scope.namespaceName;
          }
        ];

        # Each role set is read by its fixed keys below, so no role name can
        # replace another part.
        controllerClusterRbac = mkClusterRoleSet scope {
          subjects = controllerSubjects;
          labels = selectorLabels;
          roles.${clusterName} = grant [
            (
              [
                core.configmaps
                core.endpoints
                core.nodes
                core.pods
                # Ingresses in any namespace name their TLS Secrets.
                core.secrets
                core.namespaces
                core.services
                net.ingresses
                net.ingressclasses
                disco.endpointslices
              ]
              |> watch
            )
            (core.events |> emit)
            (net "ingresses/status" |> allow [ "update" ])
            (
              coord.leases
              |> allow [
                "list"
                "watch"
              ]
            )
          ];
        };
        controllerRbac = mkRoleSet scope {
          subjects = controllerSubjects;
          labels = selectorLabels;
          roles.${name} = grant [
            (
              coord.leases
              |> restrictTo [ "${name}-leader" ]
              |> allow [
                "get"
                "update"
              ]
            )
            (coord.leases |> allow [ "create" ])
          ];
        };
        admissionClusterRbac = mkClusterRoleSet scope {
          subjects = admissionSubjects;
          labels = admissionLabels;
          roles."${clusterName}-admission" = grant [
            (
              adm.validatingwebhookconfigurations
              |> restrictTo [ self.admissionWebhook.out.name ]
              |> allow [
                "get"
                "update"
              ]
            )
          ];
        };
        admissionRbac = mkRoleSet scope {
          subjects = admissionSubjects;
          labels = admissionLabels;
          roles."${name}-admission" = grant [
            (core.secrets |> allow [ "create" ])
            (core.secrets |> restrictTo [ "${name}-admission" ] |> allow [ "get" ])
          ];
        };

        certgenContainer = containerName: containerArgs: {
          name = containerName;
          image = kix.image.ref config.certgen.image;
          imagePullPolicy = config.certgen.image.pullPolicy;
          args = containerArgs ++ [
            "--namespace=$(POD_NAMESPACE)"
            "--secret-name=${name}-admission"
          ];
          inherit (config.certgen) resources;
          env = [
            {
              name = "POD_NAMESPACE";
              valueFrom.fieldRef.fieldPath = "metadata.namespace";
            }
          ];
          securityContext = {
            allowPrivilegeEscalation = false;
            capabilities.drop = [ "ALL" ];
            readOnlyRootFilesystem = true;
            runAsGroup = 65532;
            runAsNonRoot = true;
            runAsUser = 65532;
            seccompProfile.type = "RuntimeDefault";
          };
        };

        # The Jobs keep the chart's fixed names and a Job's pod template is
        # immutable, so the deploy engine replaces one when its own content
        # changes instead of failing on the patch. `checksums` puts the
        # content of the objects a Job writes to into that content.
        certgenJob =
          jobName: container: requires: checksums:
          scope.mkJob {
            name = jobName;
            labels = admissionLabels;
            inherit requires;
            spec = {
              template = {
                metadata = {
                  labels = admissionLabels;
                  annotations = checksums;
                };
                spec = {
                  serviceAccount = self.admissionServiceAccount;
                  restartPolicy = "OnFailure";
                  containers = [ container ];
                  nodeSelector."kubernetes.io/os" = "linux";
                };
              };
            };
          };
      in
      {
        serviceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          inherit name;
          labels = selectorLabels;
        };

        clusterRole = controllerClusterRbac.${clusterName};
        clusterRoleBinding = controllerClusterRbac."${clusterName}-binding";
        role = controllerRbac.${name};
        roleBinding = controllerRbac."${name}-binding";

        configmap = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          inherit name;
          labels = selectorLabels;
          data = settings;
        };

        deployment = scope.mkDeployment {
          inherit name;
          labels = selectorLabels;
          # The controller's caches never sync without its RBAC. The
          # IngressClass is listed so that the instance is Ready only once
          # the class it serves exists; nothing else in the Deployment
          # references it.
          requires = [
            self.ingressClass
            self.clusterRole
            self.clusterRoleBinding
            self.role
            self.roleBinding
          ];
          spec = {
            inherit (config) replicas;
            selector.matchLabels = selectorLabels;
            template = {
              metadata.labels = selectorLabels;
              spec = {
                serviceAccount = self.serviceAccount;
                terminationGracePeriodSeconds = 300;
                containers = [
                  {
                    name = "controller";
                    image = kix.image.ref config.image;
                    imagePullPolicy = config.image.pullPolicy;
                    inherit args env;
                    ports = [
                      (kix.port "http" 80)
                      (kix.port "https" 443)
                      (kix.port "webhook" 8443)
                      (kix.port "metrics" 10254)
                    ];
                    livenessProbe = {
                      httpGet = {
                        path = "/healthz";
                        port = "metrics";
                      };
                      initialDelaySeconds = 10;
                      failureThreshold = 5;
                    };
                    readinessProbe = {
                      httpGet = {
                        path = "/healthz";
                        port = "metrics";
                      };
                      initialDelaySeconds = 10;
                    };
                    lifecycle.preStop.exec.command = [ "/wait-shutdown" ];
                    inherit (config) resources;
                    securityContext = {
                      runAsUser = 101;
                      runAsGroup = 82;
                      runAsNonRoot = true;
                      allowPrivilegeEscalation = false;
                      readOnlyRootFilesystem = false;
                      capabilities = {
                        add = [ "NET_BIND_SERVICE" ];
                        drop = [ "ALL" ];
                      };
                      seccompProfile.type = "RuntimeDefault";
                    };
                    volumeMounts = [
                      {
                        name = "webhook-cert";
                        mountPath = "/usr/local/certificates";
                        readOnly = true;
                      }
                    ];
                  }
                ];
                nodeSelector."kubernetes.io/os" = "linux";
                volumes = [
                  {
                    name = "webhook-cert";
                    # The admissionCreate Job creates this Secret, so the
                    # Deployment applies after that Job completes.
                    secret.secretName = kix.untrackedRef {
                      kind = "Secret";
                      name = "${name}-admission";
                      by = self.admissionCreate;
                    };
                  }
                ];
              };
            };
          };
        };

        service = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          inherit name;
          labels = selectorLabels;
          annotations = config.service.annotations;
          spec = serviceSpec;
        };

        metricsService =
          if metricsOn then
            self.deployment
            |> kix.service.fromWorkload {
              name = "${name}-metrics";
              ports = [
                {
                  name = "metrics";
                  port = 10254;
                  targetPort = "metrics";
                }
              ];
              labels = labelsFor "metrics";
            }
            |> scope.mkResource
          else
            null;

        ingressClass = scope.mkClusterResource {
          apiVersion = "networking.k8s.io/v1";
          kind = "IngressClass";
          name = config.ingressClassName;
          labels = selectorLabels;
          annotations = lib.optionalAttrs config.isDefaultClass {
            "ingressclass.kubernetes.io/is-default-class" = "true";
          };
          spec.controller = controllerValue;
        };

        admissionServiceAccount = scope.mkResource {
          apiVersion = "v1";
          kind = "ServiceAccount";
          name = "${name}-admission";
          labels = admissionLabels;
        };

        admissionClusterRole = admissionClusterRbac."${clusterName}-admission";
        admissionClusterRoleBinding = admissionClusterRbac."${clusterName}-admission-binding";
        admissionRole = admissionRbac."${name}-admission";
        admissionRoleBinding = admissionRbac."${name}-admission-binding";

        admissionService = scope.mkResource {
          apiVersion = "v1";
          kind = "Service";
          name = "${name}-admission";
          labels = admissionLabels;
          spec = {
            # rawSelector, as on the controller Service: the Deployment
            # requires the webhook configuration, which names this Service.
            selector = self.deployment.rawSelector;
            ports = [
              {
                name = "https-webhook";
                port = 443;
                targetPort = 8443;
                appProtocol = "https";
              }
            ];
          };
        };

        # certgen keeps an existing Secret, so a rerun after the Job changes
        # leaves the certificate as is.
        admissionCreate =
          certgenJob "${name}-admission-create"
            (certgenContainer "create" [
              "create"
              "--host=${self.admissionService.out.name},${self.admissionService.out.name}.$(POD_NAMESPACE).svc"
            ])
            [
              self.admissionRole
              self.admissionRoleBinding
            ]
            { };

        admissionPatch =
          certgenJob "${name}-admission-patch"
            (certgenContainer "patch" [
              "patch"
              "--webhook-name=${self.admissionWebhook.out.name}"
              "--patch-mutating=false"
              "--patch-failure-policy=Fail"
            ])
            [
              self.admissionCreate
              self.admissionClusterRole
              self.admissionClusterRoleBinding
            ]
            # A changed webhook configuration gets its CA bundle again.
            { "checksum/webhook" = self.admissionWebhook.out.contentHash; };

        admissionWebhook = scope.mkClusterResource {
          apiVersion = "admissionregistration.k8s.io/v1";
          kind = "ValidatingWebhookConfiguration";
          name = "${clusterName}-admission";
          labels = admissionLabels;
          extra.webhooks = [
            {
              name = "validate.nginx.ingress.kubernetes.io";
              admissionReviewVersions = [ "v1" ];
              clientConfig.service = {
                name = self.admissionService.out.name;
                namespace = scope.namespaceName;
                path = "/networking/v1/ingresses";
                port = 443;
              };
              failurePolicy = "Fail";
              matchPolicy = "Equivalent";
              rules = [
                {
                  apiGroups = [ "networking.k8s.io" ];
                  apiVersions = [ "v1" ];
                  operations = [
                    "CREATE"
                    "UPDATE"
                  ];
                  resources = [ "ingresses" ];
                  scope = "*";
                }
              ];
              sideEffects = "None";
              timeoutSeconds = 10;
            }
          ];
        };

        # The root is the Deployment rather than the user-facing Service,
        # because the Service is upstream of the Deployment: with the Service
        # as root, the instance would report Ready before the controller.
        root = {
          resource = self.deployment;
          out = {
            version = kix.image.version config.image;

            # Consumers depend through string context. The class name carries
            # the Deployment's and the patch Job's context as well as the
            # IngressClass's, so an Ingress that reads it applies after the
            # controller serves and the webhook configuration has its CA
            # bundle; before that the webhook (failurePolicy Fail) rejects it.
            ingressClassName = builtins.appendContext self.ingressClass.out.name (
              builtins.getContext self.deployment.out.name // builtins.getContext self.admissionPatch.out.name
            );
            # Raw labels: the reader writes a policy selector from them and
            # already depends on this instance through ingressClassName.
            podSelector = selectorLabels;
            podNamespace = scope.namespaceName;
          };
        };
      }
    )

    (kix.monitor {
      service = "metricsService";
      port = "metrics";
    })
  ];
}
