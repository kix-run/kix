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
}:

{
  meta = {
    version = "v1.17.1";
    description = "cert-manager — X.509 certificate management for Kubernetes";
    provides = [
      "certificates"
      "tls"
    ];
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
    };
    webhook = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-webhook";
          tag = "v1.17.1";
        };
        replicaCount = 1;
      };
    };
    cainjector = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-cainjector";
          tag = "v1.17.1";
        };
        replicaCount = 1;
      };
    };
    acmesolver = lib.mkOption {
      type = lib.types.anything;
      default = {
        image = {
          repository = "quay.io/jetstack/cert-manager-acmesolver";
          tag = "v1.17.1";
        };
      };
    };
    replicaCount = lib.mkOption {
      type = lib.types.int;
      default = 1;
    };
    installCRDs = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    resources = lib.mkOption {
      type = lib.types.nullOr lib.types.anything;
      default = null;
    };
    dns01RecursiveNameservers = lib.mkOption {
      type = lib.types.str;
      default = "";
    };
    dns01RecursiveNameserversOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    prometheus = lib.mkOption {
      type = lib.types.anything;
      default = {
        enabled = false;
      };
    };
  };

  build = [
    ./crds.nix
    ./controller.nix
    ./webhook.nix
    ./cainjector.nix
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
            ];
        };
      }
    )
  ];
}
