# cert-manager: X.509 certificate issuance and renewal for Kubernetes.
#
# Components:
#   controller   reconciles Certificates, CertificateRequests, Issuers,
#                ClusterIssuers, ACME Orders, and Challenges, and creates
#                Certificates for annotated Ingresses and Gateways
#                (controller.nix)
#   webhook      validates and mutates cert-manager objects (webhook.nix)
#   cainjector   copies the webhook's CA into its configurations and into
#                any object annotated for injection (cainjector.nix)
#   API check    a Job that succeeds once the API server admits
#                cert-manager objects (startupapicheck.nix)
#
# The package needs no dependencies and no config:
#
#   instances.cert-manager.cert-manager.package = packages.cert-manager;
#
# Issuers come from the `cluster-issuers` package. With a `prometheus`
# provider in the cluster, the instance also renders metrics Services, three
# ServiceMonitors, and its alerts (`metrics.enabled = false` turns them off).
#
# The six CRDs are vendored from the release (crds.nix). The webhook
# refuses writes until cainjector has injected its CA, so every custom
# resource built from `out.crds.<Kind>` requires the API check, and
# Certificate, CertificateRequest, Issuer, and ClusterIssuer wait for
# Ready=True at deploy. ACME DNS-01 issuance can take longer than
# `kix deploy`'s default timeout; raise `--timeout` on clusters that issue
# through ACME.
#
# One instance per cluster: the CRDs, webhook configurations, and
# ClusterRoles are cluster-scoped (`meta.conflictsWith`).
#
# DI deps:
#   prometheus (optional)  metrics Services, three ServiceMonitors, and the
#                          alerts.
#
# Network policy: the intents below open egress to issuer endpoints outside
# the cluster on 443, 80, and 53, and admit the API server to the webhook.
# They apply to every workload of the instance. An issuer on another port
# (Vault on 8200, a private ACME server) needs its own policy. Under an
# enforcer the ACME HTTP-01 solver pods the controller launches get no
# policy and stay unreachable, so HTTP-01 issuance needs a
# `networkPolicy.platformIntents` entry for the pods
# `out.operandSelectors.acmesolver` selects, on port 8089. Prometheus
# scrapes are also dropped under an enforcer, so CertManagerAbsent fires
# there.
#
# Escape hatches: `extraArgs`, `webhook.extraArgs`, and
# `cainjector.extraArgs`; the controller's `env`; the instance's
# `partsOverlays` for placement and exact replica counts.
#
# Exposes:
#   out.crds.{Certificate,Issuer,ClusterIssuer,CertificateRequest,Order,Challenge}
#       For `scope.mkCR`; each custom resource requires the API check.
#   out.clusterResourceNamespace
#       The namespace the controller reads ClusterIssuer Secrets from.
#   out.clusterIssuerSpecSchema
#       The ClusterIssuer CRD's `spec` schema.
#   out.operandSelectors.acmesolver
#       The labels of the ACME HTTP-01 solver pods.
#   out.extraImages
#       The ACME HTTP-01 solver image.

{ lib, kix, ... }:

let
  common = import ./common.nix { inherit lib; };
  inherit (common) release;

  clusterIssuerCrd =
    (builtins.fromJSON (builtins.readFile ./crds/clusterissuers.cert-manager.io.json)).spec;

  extraArgsOption =
    component: examples:
    lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Flags appended to the ${component} container's arguments${examples}. A
        repeated scalar flag such as `--v` takes the last value; list and map
        flags such as `--feature-gates` accumulate. A flag the package
        derives is refused, and the error says what to do instead.
      '';
    };
in
{
  meta = {
    version = release;
    description = "cert-manager: X.509 certificate management for Kubernetes";
    owner = "platform";
    defaultAliases = [ "certManager" ];
    conflictsWith = [ "cluster:certManager" ];
    # TLS Ingresses carry `cert-manager.io/cluster-issuer`, stamped by the
    # cluster-issuers package's `out.withCert`. The consumer depends on the
    # cluster-issuers instance and that instance on this package, and the
    # annotation-ownership rule follows that chain.
    annotationDomains = [ "cert-manager.io" ];
    # The lowest Kubernetes release cert-manager v1.21 supports.
    k8s.minVersion = "1.33";
    network.intents = {
      # Issuer endpoints are runtime data in Issuer specs: ACME directories
      # and DNS provider APIs on 443, HTTP-01 self-checks on 80, and DNS-01
      # self-checks against authoritative nameservers on 53.
      issuers.egress = [
        {
          to = "world";
          ports = [
            {
              port = 443;
              protocol = "TCP";
            }
            {
              port = 80;
              protocol = "TCP";
            }
            {
              port = 53;
              protocol = "UDP";
            }
            {
              port = 53;
              protocol = "TCP";
            }
          ];
        }
      ];
      # The API server calls the admission webhook on webhook.securePort.
      # meta cannot read config, so the rule admits the API server on any
      # port.
      webhook.ingress = [ { from = "apiserver"; } ];
    };
  };

  options = {
    image = kix.options.image {
      repository = "quay.io/jetstack/cert-manager-controller";
      tag = release;
      digest = "sha256:70f532fd9cfde0b09d55687200942399d89838bc2d5d5b45152eb799a15912b8";
      description = "Image of the controller. Its major.minor must match the vendored CRDs and RBAC; the other images follow its tag.";
    };
    # Each component held under 30 MiB on an idle kind cluster. The
    # controller and cainjector requests of 64Mi leave room for their
    # informer caches, which grow with the cluster; the webhook keeps no
    # cache.
    # cert-manager's best-practice guide asks for limits sized to the
    # cluster and publishes no figures.
    resources = kix.options.resources {
      requests = {
        cpu = "10m";
        memory = "64Mi";
      };
      limits = {
        cpu = "500m";
        memory = "512Mi";
      };
      description = ''
        Resource requests and limits for the controller container. The
        512Mi memory limit suits a small cluster. The controller caches the
        TLS Secrets its Certificates own, so its memory grows roughly with
        their total size (cert-manager's "Scaling cert-manager" guide); raise
        `limits.memory` on a cluster with many certificates or large RSA keys.
        Each field keeps its default until set, and null removes a default.
      '';
    };
    extraArgs = extraArgsOption "controller" ", such as `--dns01-recursive-nameservers=1.1.1.1:53`, `--dns01-recursive-nameservers-only`, `--enable-gateway-api`, or `--v=4`";
    env = kix.options.env // {
      description = ''
        Extra environment variables for the controller, such as
        `HTTPS_PROXY` and `NO_PROXY` for ACME and DNS provider egress. A
        value is a string, a `fieldRef` source, or a `secretKeyRef` source
        naming a Secret managed outside Kix with `kix.untrackedRef`. The
        package sets `POD_NAMESPACE`.
      '';
    };

    webhook = {
      image = kix.options.image {
        repository = "quay.io/jetstack/cert-manager-webhook";
        tag = release;
        digest = "sha256:a60e2dac46dbb8a7f3df95c54ce941012f54c2fe022f0ee55aaa1ab40ed957ae";
        tagText = "config.image.tag";
        description = "Image of the admission webhook.";
      };
      # The webhook keeps no cache, so its memory stays flat as the cluster
      # grows.
      resources = kix.options.resources {
        requests = {
          cpu = "10m";
          memory = "32Mi";
        };
        limits = {
          cpu = "200m";
          memory = "128Mi";
        };
        description = "Resource requests and limits for the webhook container. Each field keeps its default until set, and null removes a default.";
      };
      securePort = lib.mkOption {
        type = lib.types.port;
        default = 10250;
        description = ''
          Port the webhook serves admission requests on. It sets
          `--secure-port`, the containerPort, and the Service's targetPort.
          Change it where the kubelet holds 10250 on the pod network, as on
          EKS Fargate.
        '';
      };
      extraArgs = extraArgsOption "webhook" "";
    };

    cainjector = {
      image = kix.options.image {
        repository = "quay.io/jetstack/cert-manager-cainjector";
        tag = release;
        digest = "sha256:c85268c64f2e0e76684bf5fe8906caff34b82523561c6affe0fae3546bd87562";
        tagText = "config.image.tag";
        description = "Image of the CA injector.";
      };
      resources = kix.options.resources {
        requests = {
          cpu = "10m";
          memory = "64Mi";
        };
        limits = {
          cpu = "500m";
          memory = "512Mi";
        };
        description = ''
          Resource requests and limits for the CA-injector container. The
          512Mi memory limit suits a small cluster. cainjector's cache grows
          with the Secrets, CRDs, and webhook configurations it watches, so
          raise `limits.memory` on a large one (cert-manager's installation
          best-practice guide, "Scalability"). Each field keeps its default
          until set, and null removes a default.
        '';
      };
      extraArgs = extraArgsOption "cainjector" "";
    };

    startupapicheck.image = kix.options.image {
      repository = "quay.io/jetstack/cert-manager-startupapicheck";
      tag = release;
      digest = "sha256:46e75b6866359ffb5d82624f41e3ed1c70b2994982702ced547ce5edb418a8f5";
      tagText = "config.image.tag";
      description = "Image of the API-check Job. Its pull policy follows the controller's.";
    };

    operandImages.acmesolver = kix.options.image {
      repository = "quay.io/jetstack/cert-manager-acmesolver";
      tag = release;
      digest = "sha256:699b40d622211ab7accad8a21b04c5fbaa1841ef7a12621e8de492dbe27b2503";
      tagText = "config.image.tag";
      description = "Image of the ACME HTTP-01 solver pods the controller launches (`--acme-http01-solver-image`).";
    };

    metrics = kix.options.monitor;
  };

  # A component's tag follows the controller's `image.tag` unless the
  # instance sets that component's tag itself.
  config =
    { config, ... }:
    {
      webhook.image.tag = lib.mkDefault config.image.tag;
      cainjector.image.tag = lib.mkDefault config.image.tag;
      startupapicheck.image = {
        tag = lib.mkDefault config.image.tag;
        pullPolicy = lib.mkDefault config.image.pullPolicy;
      };
      operandImages.acmesolver.tag = lib.mkDefault config.image.tag;
    };

  build = [
    ./crds.nix
    ./controller.nix
    ./webhook.nix
    ./cainjector.nix
    ./startupapicheck.nix

    (
      {
        self,
        config,
        scope,
        ...
      }:
      {
        root = {
          resource = self.controllerDeployment;
          requires = lib.filter (r: r != null) (
            builtins.attrValues self.crds
            ++ [
              self.controllerServiceAccount
              self.controllerService
              # Aggregated by label; nothing else depends on them.
              self.clusterViewRole
              self.viewRole
              self.editRole
              self.webhookServiceAccount
              self.webhookService
              self.webhookDeployment
              self.mutatingWebhookConfiguration
              self.validatingWebhookConfiguration
              self.cainjectorServiceAccount
              self.cainjectorService
              self.cainjectorDeployment
              # The alert rules reference no other part, so nothing else
              # brings them into the instance.
              self.controllerAlerts
            ]
          );
          postHooks = [ self.apiCheck ];
          out = {
            crds = {
              Certificate = self.crds.certificates;
              Issuer = self.crds.issuers;
              ClusterIssuer = self.crds.clusterIssuers;
              CertificateRequest = self.crds.certificateRequests;
              Order = self.crds.orders;
              Challenge = self.crds.challenges;
            };
            # --cluster-resource-namespace is the pod's namespace.
            clusterResourceNamespace = scope.namespaceName;
            # The cluster-issuers package checks ClusterIssuer specs against
            # it at evaluation.
            clusterIssuerSpecSchema =
              (builtins.head clusterIssuerCrd.versions).schema.openAPIV3Schema.properties.spec;
            # The controller labels the HTTP-01 solver pods it launches in a
            # Certificate's namespace with this set.
            operandSelectors.acmesolver."acme.cert-manager.io/http01-solver" = "true";
            extraImages = [ (kix.image.ref config.operandImages.acmesolver) ];
          };
        };
      }
    )

    # DI passes a build function only the arguments its formals name, so
    # each wrapper names every argument kix.monitor reads. The alerts ride
    # on the controller's monitor, whose Service serves the certificate
    # metrics.
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      let
        # Evaluated only when the rules render, which is also the only case
        # where controllerService exists.
        selector = ''namespace="${scope.namespaceName}",service="${self.controllerService.out.name}"'';
      in
      kix.monitor {
        service = "controllerService";
        port = "http-metrics";
        monitorPart = "controllerMonitor";
        rulesPart = "controllerAlerts";
        alerts = {
          # Fires when the controller target is down or missing. The
          # certificate series below vanish with it, so neither of the other
          # alerts can fire then.
          CertManagerAbsent = {
            expr = "absent(up{${selector}} == 1)";
            "for" = "10m";
            severity = "critical";
            summary = "The cert-manager controller has not been scraped for 10 minutes";
            description = "Prometheus has no reachable cert-manager controller target in namespace ${scope.namespaceName}. While the controller is down, certificates are not renewed. Check Deployment ${scope.namespaceName}/${self.controllerDeployment.out.name} and its Prometheus target.";
          };
          CertManagerCertificateRenewalOverdue = {
            expr = "time() - certmanager_certificate_renewal_timestamp_seconds{${selector}} > 0";
            "for" = "1h";
            severity = "warning";
            summary = "A certificate is more than an hour past its renewal time";
            description = "Certificate {{ $labels.exported_namespace }}/{{ $labels.name }} has been past its renewal time for over an hour. Run kubectl describe certificate on it and check its CertificateRequests and Orders.";
          };
          CertManagerCertificateNotReady = {
            expr = ''certmanager_certificate_ready_status{${selector},condition="False"} == 1'';
            "for" = "15m";
            severity = "warning";
            summary = "A certificate has not been Ready for 15 minutes";
            description = "Certificate {{ $labels.exported_namespace }}/{{ $labels.name }} reports Ready=False. Run kubectl describe certificate on it for cert-manager's reason.";
          };
        };
      } args
    )
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor {
        name = "${scope.instanceName}-webhook";
        service = "webhookService";
        monitorPart = "webhookMonitor";
        rulesPart = "webhookAlerts";
      } args
    )
    (
      {
        self,
        config,
        scope,
        lib,
        prometheus ? null,
        ...
      }@args:
      kix.monitor {
        name = "${scope.instanceName}-cainjector";
        service = "cainjectorService";
        port = "http-metrics";
        monitorPart = "cainjectorMonitor";
        rulesPart = "cainjectorAlerts";
      } args
    )
  ];
}
