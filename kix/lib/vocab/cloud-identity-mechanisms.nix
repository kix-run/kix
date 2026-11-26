# Define the mechanisms that deliver a workload's cloud identity: how a
# cluster turns `kix.cloudIdentity.aws`, `gcp`, or `azure` into ServiceAccount
# annotations and pod labels. They are internal to the library. The `eks`,
# `gke`, `gke-autopilot`, and `aks` flavors and the `irsa-webhook` and
# `azure-workload-identity-webhook` modules put one in the `out.cloudIdentity`
# of the instance that claims the `cloudIdentity` role.
{ lib }:

let
  mechanismType = "kix-cloud-identity-mechanism";

  # Return a mechanism record. `render` takes the value of the mechanism's
  # cloud and returns the ServiceAccount annotations and pod labels it needs.
  # It may also return:
  #
  # - `podEnv`: the environment variables the platform adds to every
  #   container of a pod it gives the identity to, each mapped to its
  #   expected value or to null when only its presence is known. The deploy
  #   checks a new pod for them, because only the platform can say whether
  #   the pod got the identity.
  # - `podEnvFix`: what to check when a pod lacks them.
  # - `servesHostNetwork = false` when the platform gives no identity to a
  #   pod with `hostNetwork: true`.
  mkMechanism =
    {
      cloud,
      name,
      description,
      annotationDomains,
      render,
    }:
    {
      _type = mechanismType;
      inherit
        cloud
        name
        description
        annotationDomains
        render
        ;
    };

  # Return the IAM roles for service accounts (IRSA) mechanism, which EKS
  # and the self-hosted amazon-eks-pod-identity-webhook read from a
  # ServiceAccount annotation. The self-hosted webhook takes the prefix as
  # its `--annotation-prefix` flag.
  irsa =
    {
      annotationPrefix ? "eks.amazonaws.com",
    }:
    mkMechanism {
      cloud = "aws";
      name = "irsa";
      description = "IAM roles for service accounts (IRSA)";
      annotationDomains = [ annotationPrefix ];
      render = value: {
        serviceAccountAnnotations."${annotationPrefix}/role-arn" = value.roleArn;
        podLabels = { };
        podEnv = {
          AWS_ROLE_ARN = value.roleArn;
          AWS_WEB_IDENTITY_TOKEN_FILE = null;
        };
        podEnvFix = "Check that the IRSA webhook runs (on EKS it is part of the control plane). On EKS, an EKS Pod Identity association for this ServiceAccount takes precedence over IRSA: delete the association in AWS. Then restart the workload's pods.";
      };
    };

  # Return the EKS Pod Identity mechanism. The link between the
  # ServiceAccount and the role is an association in the EKS API, which Kix
  # does not create, so it renders nothing the cloud reads. The declared role
  # is the role the association must name. EKS does not tell the pod which
  # role the association names, so the deploy can check only that the pod
  # got some association.
  eksPodIdentity =
    { }:
    mkMechanism {
      cloud = "aws";
      name = "eks-pod-identity";
      description = "EKS Pod Identity";
      annotationDomains = [ ];
      render = _: {
        serviceAccountAnnotations = { };
        podLabels = { };
        podEnv = {
          AWS_CONTAINER_CREDENTIALS_FULL_URI = null;
          AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = null;
        };
        podEnvFix = "Create an EKS Pod Identity association in AWS for this ServiceAccount and the role in the cloud identity (Kix does not create it), and check that the EKS Pod Identity Agent add-on runs. Then restart the workload's pods.";
      };
    };

  # Return the GKE Workload Identity Federation mechanism. With no Google
  # service account it renders nothing, because Google grants IAM roles to
  # the Kubernetes ServiceAccount itself. GKE adds no environment variables,
  # so the deploy cannot check a pod. GKE does not serve a pod with
  # `hostNetwork: true`, which then runs as the node's service account.
  gke =
    { }:
    mkMechanism {
      cloud = "gcp";
      name = "gke";
      description = "GKE Workload Identity Federation";
      annotationDomains = [ "iam.gke.io" ];
      render = value: {
        serviceAccountAnnotations = lib.optionalAttrs (value.serviceAccount != null) {
          "iam.gke.io/gcp-service-account" = value.serviceAccount;
        };
        podLabels = { };
        servesHostNetwork = false;
      };
    };

  # Return the Microsoft Entra Workload ID mechanism. Its webhook acts only
  # on pods that carry the `azure.workload.identity/use` label.
  azureWorkloadId =
    { }:
    mkMechanism {
      cloud = "azure";
      name = "azure-workload-id";
      description = "Microsoft Entra Workload ID";
      annotationDomains = [ "azure.workload.identity" ];
      render = value: {
        serviceAccountAnnotations = {
          "azure.workload.identity/client-id" = value.clientId;
        }
        // lib.optionalAttrs (value.tenantId != null) {
          "azure.workload.identity/tenant-id" = value.tenantId;
        };
        podLabels."azure.workload.identity/use" = "true";
        podEnv = {
          AZURE_CLIENT_ID = value.clientId;
          AZURE_TENANT_ID = value.tenantId;
          AZURE_FEDERATED_TOKEN_FILE = null;
        };
        podEnvFix = "Check that the Azure Workload Identity webhook runs and that its mutating webhook configuration covers this namespace. Then restart the workload's pods.";
      };
    };

in
{
  inherit
    mechanismType
    irsa
    eksPodIdentity
    gke
    azureWorkloadId
    ;
}
