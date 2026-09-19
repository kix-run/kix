# cert-manager package — jetstack/cert-manager v1.17.1.
#
# X.509 certificate management for Kubernetes. Automates issuance and
# renewal of TLS certificates from various sources (Let's Encrypt, Vault,
# Venafi, self-signed, etc.).
#
# Three components:
#   controller  — main cert-manager, reconciles Certificate/Issuer CRDs
#   webhook     — validates and mutates cert-manager resources via admission webhooks
#   cainjector  — injects CA bundles into webhooks, API services, and CRDs

{
  scope,
  lib,
  kix,
  availability,
}:

{
  meta = {
    version = "v1.17.1";
    description = "cert-manager — X.509 certificate management for Kubernetes";
    defaultAliases = [ "certManager" ];
    k8s.minVersion = "1.21";
    k8s.platformNotes = {
      gke-private = {
        summary = "Webhook unreachable without extra firewall rule";
        detail = "GKE private clusters restrict control-plane → pod traffic. An additional firewall rule must allow the GKE control plane to reach the webhook port (10250).";
      };
      gke-autopilot = {
        summary = "Requires K8s >= 1.21; leader election must not use kube-system";
        detail = "Autopilot blocks mutating webhooks on K8s < 1.21 and forbids writes to kube-system. Leader election is already configured to use the package namespace.";
        mitigated = true;
      };
      aws-fargate = {
        summary = "Webhook port 10250 clashes with kubelet";
        detail = "Fargate runs kubelet on port 10250. The webhook secure-port must be changed. No hostNetwork option is available — Fargate controls networking.";
      };
      aws-eks-custom-cni = {
        summary = "Webhook unreachable with custom CNI unless hostNetwork is enabled";
        detail = "When using a non-default CNI (Weave, Calico) on EKS, the control plane cannot reach pods on the custom CNI. The webhook needs hostNetwork=true plus a non-10250 port.";
      };
    };
  };

  options = {
    image = lib.mkOption {
      type = lib.types.anything;
      default = {
        repository = "quay.io/jetstack/cert-manager-controller";
        tag = "v1.17.1";
        pullPolicy = "IfNotPresent";
      };
      description = ''
        Image for the cert-manager controller `Deployment`. Attrset with
        `repository`, `tag`, and `pullPolicy` keys.
      '';
    };
    webhook = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-webhook";
          tag = "v1.17.1";
        };
        # The webhook sits in the write path for every cert-manager object,
        # so with one replica a rolling restart is a visible API failure.
        replicaCount = kix.availability.pick availability {
          none = 1;
          pod = 2;
          node = 2;
          zone = 2;
        };
      };
      description = ''
        Webhook component config. Sets the `image` attrset and
        `replicaCount` for the admission webhook that validates and mutates
        cert-manager CRs. The replica count defaults from the cluster's
        availability level (v2_discussions/145).
      '';
    };
    cainjector = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-cainjector";
          tag = "v1.17.1";
        };
        # Leader election makes a restart invisible, so "pod" stays at 1.
        # From "node" up a standby keeps injecting when a node is lost.
        replicaCount = kix.availability.pick availability {
          none = 1;
          pod = 1;
          node = 2;
          zone = 2;
        };
      };
      description = ''
        CA-injector component config. Sets the `image` attrset and
        `replicaCount` for the controller that injects CA bundles into
        webhooks, APIServices, and CRDs. The replica count defaults from the
        cluster's availability level (v2_discussions/145).
      '';
    };
    acmesolver = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-acmesolver";
          tag = "v1.17.1";
        };
      };
      description = ''
        ACME-solver image used by cert-manager to spin up HTTP-01
        challenge-response pods. Image attrset with `repository` and `tag`.
      '';
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      # The controller holds a leader election lease, so a restart is not
      # user-visible; from "node" up a standby takes over when a node dies.
      default = kix.availability.pick availability {
        none = 1;
        pod = 1;
        node = 2;
        zone = 2;
      };
      description = ''
        Number of replicas for the cert-manager controller `Deployment`.
        Defaults from the cluster's availability level (v2_discussions/145).
      '';
    };
    installCRDs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether kix should emit the cert-manager CRDs (`Certificate`,
        `Issuer`, `Challenge`, etc.). Set to `false` when CRDs are managed
        out-of-band.
      '';
    };
    resources = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
      description = ''
        Optional resource requests/limits attrset applied to the controller
        container. `null` leaves the container's resource block unset.
      '';
    };
    dns01RecursiveNameservers = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Comma-separated list of recursive nameservers used to verify DNS-01
        ACME challenges (e.g. `8.8.8.8:53,1.1.1.1:53`). Empty string falls
        back to the system resolver.
      '';
    };
    dns01RecursiveNameserversOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        If `true`, only the nameservers in `dns01RecursiveNameservers` are
        used for DNS-01 self-checks (skipping cluster DNS entirely).
      '';
    };
    prometheus = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
      };
      description = ''
        Prometheus scrape config for cert-manager. When `enabled` is true,
        kix wires up the metrics endpoint annotations on the controller
        `Service`.
      '';
    };
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
        lib,
        ...
      }:
      {
        root = {
          resource = self.controllerDeployment;
          requires =
            # CRDs
            (lib.optionals config.installCRDs [
              self.crds.certificates
              self.crds.certificateRequests
              self.crds.challenges
              self.crds.clusterIssuers
              self.crds.issuers
              self.crds.orders
            ])
            # Controller
            ++ [
              self.controllerServiceAccount
              self.controllerService
            ]
            # Aggregate roles (no binding — not auto-discovered via inverse deps)
            ++ [
              self.clusterViewRole
              self.viewRole
              self.editRole
            ]
            # Webhook
            ++ [
              self.webhookServiceAccount
              self.webhookService
              self.webhookDeployment
              self.mutatingWebhookConfiguration
              self.validatingWebhookConfiguration
            ]
            # CA Injector
            ++ [
              self.cainjectorServiceAccount
              self.cainjectorService
              self.cainjectorDeployment
            ]
            # Startup API check (post-install verification job)
            ++ [
              self.startupapicheckJob
            ];
        };
      }
    )
  ];
}
