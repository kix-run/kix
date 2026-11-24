# Define workload cloud identity: the `cloudIdentity` attribute of an
# instance, the mechanisms that deliver it (`kix.cloudIdentity.irsa`,
# `eksPodIdentity`, `gke`, `azureWorkloadId`), and the check a package runs on it
# (`kix.cloudIdentity.orSecret`).
#
# The cluster author names the principal in its cloud's own terms on the
# instance. The instance that claims the `cloudIdentity` role (a flavour's
# import, or a package that runs the webhook) carries one mechanism in
# `out.cloudIdentity`, which turns that value into the ServiceAccount
# annotations and pod labels the cloud reads. A package binds the result to
# its ServiceAccount with `scope.cloudIdentity.bind`.
{ lib }:

let
  kixKeys = (import ../core/annotations.nix).keys;

  mechanismType = "kix-cloud-identity-mechanism";

  # The word each cloud's attribute uses, and how a message names the cloud.
  clouds = {
    aws = "AWS";
    gcp = "Google Cloud";
    azure = "Azure";
  };

  str = lib.types.str;
  nullOrStr = lib.types.nullOr lib.types.str;

  type = lib.types.nullOr (
    lib.types.submodule {
      options = {
        aws = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options.roleArn = lib.mkOption {
                type = str;
                example = "arn:aws:iam::111122223333:role/external-dns";
                description = "ARN of the IAM role the workload assumes.";
              };
            }
          );
          default = null;
          description = "AWS IAM role for this instance's pods.";
        };
        gcp = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options.serviceAccount = lib.mkOption {
                type = nullOrStr;
                default = null;
                example = "external-dns@my-project.iam.gserviceaccount.com";
                description = ''
                  Email address of the Google service account for this
                  instance's pods. Leave unset (`gcp = { }`) to grant IAM roles
                  directly to the Kubernetes ServiceAccount.
                '';
              };
            }
          );
          default = null;
          description = "Google Cloud identity for this instance's pods.";
        };
        azure = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                clientId = lib.mkOption {
                  type = str;
                  example = "00000000-0000-0000-0000-000000000000";
                  description = "Client ID (GUID) of the Microsoft Entra application or user-assigned managed identity.";
                };
                tenantId = lib.mkOption {
                  type = nullOrStr;
                  default = null;
                  description = "Microsoft Entra tenant ID (GUID), when different from the cluster's tenant.";
                };
              };
            }
          );
          default = null;
          description = "Azure identity for this instance's pods.";
        };
      };
    }
  );

  roleArnPattern = "arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+";
  googleAccountPattern = "[^@[:space:]]+@[a-z0-9.-]+[.]gserviceaccount[.]com";
  guidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
  matches = pattern: value: builtins.match pattern value != null;

  # Return the clouds the instance value sets, as `{ cloud; value; }`.
  declaredClouds =
    value:
    if value == null then
      [ ]
    else
      lib.mapAttrsToList (cloud: v: {
        inherit cloud;
        value = v;
      }) (lib.filterAttrs (cloud: v: clouds ? ${cloud} && v != null) value);

  # Return what is wrong with one cloud's value, as `{ message; fix; }`, or
  # null.
  valueProblem =
    { cloud, value }:
    if cloud == "aws" && !(matches roleArnPattern value.roleArn) then
      {
        message = "`cloudIdentity.aws.roleArn` is \"${value.roleArn}\", which is not a valid AWS IAM role ARN. Kix cannot bind this instance's ServiceAccount to a malformed ARN.";
        fix = "Set `cloudIdentity.aws.roleArn` to a full IAM role ARN (including the 12-digit AWS account ID), such as `\"arn:aws:iam::111122223333:role/external-dns\"`.";
      }
    else if
      cloud == "gcp"
      && value.serviceAccount != null
      && !(matches googleAccountPattern value.serviceAccount)
    then
      {
        message = "`cloudIdentity.gcp.serviceAccount` is \"${value.serviceAccount}\", which is not a valid Google service account email address. Kix cannot bind this instance's ServiceAccount to a malformed email address.";
        fix = "Set `cloudIdentity.gcp.serviceAccount` to an email address ending in `.gserviceaccount.com` (such as `\"external-dns@my-project.iam.gserviceaccount.com\"`), or set `cloudIdentity.gcp = { };` to grant IAM roles directly to the Kubernetes ServiceAccount.";
      }
    else if cloud == "azure" && !(matches guidPattern value.clientId) then
      {
        message = "`cloudIdentity.azure.clientId` is \"${value.clientId}\", which is not a valid client ID GUID. Kix cannot write a malformed client ID onto this instance's ServiceAccount.";
        fix = "Set `cloudIdentity.azure.clientId` to the client ID GUID of the Microsoft Entra application or managed identity, such as `\"00000000-0000-0000-0000-000000000000\"`.";
      }
    else if cloud == "azure" && value.tenantId != null && !(matches guidPattern value.tenantId) then
      {
        message = "`cloudIdentity.azure.tenantId` is \"${value.tenantId}\", which is not a valid tenant ID GUID. Kix cannot write a malformed tenant ID onto this instance's ServiceAccount.";
        fix = "Set `cloudIdentity.azure.tenantId` to the Microsoft Entra tenant ID GUID (such as `\"00000000-0000-0000-0000-000000000000\"`), or remove `tenantId` to use the cluster's tenant.";
      }
    else
      null;

  # Return a mechanism record. `render` takes the value of the mechanism's
  # cloud and returns the ServiceAccount annotations and pod labels it needs.
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
      };
    };

  # Return the EKS Pod Identity mechanism. The link between the
  # ServiceAccount and the role is an association in the EKS API, which Kix
  # does not create, so it renders nothing the cloud reads. The record and
  # the restart stamp still follow the declared role.
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
      };
    };

  # Return the GKE Workload Identity Federation mechanism. With no Google
  # service account it renders nothing, because Google grants IAM roles to
  # the Kubernetes ServiceAccount itself.
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
      };
    };

  # Resolve an instance's `cloudIdentity` against the cluster's provider.
  # `provider` is `{ ns; inst; out; }` from the role lookup, or null.
  # Return `{ isSet; cloud; problem; rendered; record; }`. `problem` is
  # `{ message; fix; }` or null, and `rendered` and `record` are set only
  # when `problem` is null.
  resolve =
    { value, provider }:
    let
      declared = declaredClouds value;
      one = builtins.head declared;
      mechanism = if provider == null then null else provider.out.cloudIdentity or null;
      providerName = "${provider.ns}/${provider.inst}";
      problem =
        if builtins.length declared > 1 then
          {
            message = "`cloudIdentity` sets more than one cloud (${
              lib.concatMapStringsSep " and " (d: d.cloud) declared
            }), but an instance can bind only one cloud identity. Kix cannot choose which cloud's annotations and labels to write on this instance's ServiceAccount and pods.";
            fix = "Keep the `cloudIdentity` setting for this cluster's cloud, and remove the others.";
          }
        else if valueProblem one != null then
          valueProblem one
        else if mechanism == null then
          {
            message = "`cloudIdentity.${one.cloud}` is set on this instance, but this cluster does not configure a cloud identity provider, so Kix does not know how to annotate this instance's ServiceAccount and pods for ${clouds.${one.cloud}}.";
            fix =
              "On EKS, GKE, or AKS, add `kix.flavors.eks`, `kix.flavors.gke`, `kix.flavors.gke-autopilot`, or `kix.flavors.aks` to `modules` in your cluster definition."
              + " On a self-managed cluster, declare a `cloudIdentity` import (`kix.cloudIdentity.irsa { }`, `kix.cloudIdentity.gke { }`, or `kix.cloudIdentity.azureWorkloadId { }`), for example:"
              + "\n  instances.kube-system.cloud-identity.package = kix.mkImport {"
              + "\n    roles = [ \"cloudIdentity\" ];"
              + "\n    annotationDomains = [ \"eks.amazonaws.com\" ];"
              + "\n    out.cloudIdentity = kix.cloudIdentity.irsa { };"
              + "\n  };";
          }
        else if (mechanism._type or null) != mechanismType then
          {
            message = "`${providerName}` declares the `cloudIdentity` role, but its `out.cloudIdentity` is not a valid mechanism from `kix.cloudIdentity`, so Kix cannot render `cloudIdentity` on this instance's ServiceAccount and pods.";
            fix = "Set `out.cloudIdentity` on `${providerName}` to `kix.cloudIdentity.irsa { }`, `kix.cloudIdentity.eksPodIdentity { }`, `kix.cloudIdentity.gke { }`, or `kix.cloudIdentity.azureWorkloadId { }`.";
          }
        else if mechanism.cloud != one.cloud then
          {
            message = "`cloudIdentity.${one.cloud}` is set on this instance, but `${providerName}` configures this cluster for ${clouds.${mechanism.cloud}} through ${mechanism.description}. Kix cannot bind `cloudIdentity.${one.cloud}` on a cluster configured for ${clouds.${mechanism.cloud}}.";
            fix = "Replace `cloudIdentity.${one.cloud}` with `cloudIdentity.${mechanism.cloud}` for ${clouds.${mechanism.cloud}}, or update `${providerName}` if this cluster runs on another cloud.";
          }
        else
          null;
    in
    if declared == [ ] then
      {
        isSet = false;
        cloud = null;
        problem = null;
      }
    else
      {
        isSet = true;
        cloud = if builtins.length declared == 1 then one.cloud else null;
        inherit problem;
      }
      // lib.optionalAttrs (problem == null) {
        rendered = mechanism.render one.value;
        # What the ServiceAccount records under `kix.run/cloud-identity`:
        # the declared value and the mechanism that delivers it. The pod
        # template's restart stamp hashes the same record.
        record = {
          mechanism = mechanism.name;
          ${one.cloud} = lib.filterAttrs (_: v: v != null) one.value;
        };
      };

  # Return the `scope.cloudIdentity` handle for a resolved identity.
  # `requires` lists the provider's root, which every bound ServiceAccount
  # depends on.
  handle =
    { resolved, requires }:
    let
      ok = resolved.isSet && resolved.problem == null;
      recordJson = builtins.toJSON resolved.record;
    in
    {
      inherit (resolved) isSet cloud;

      # Return ServiceAccount arguments with this instance's identity on
      # them: the mechanism's annotations, `kix.run/cloud-identity`, and a
      # dependency on the provider. The workload builder reads
      # `_cloudIdentity` from the ServiceAccount a pod spec names and adds
      # the pod labels and the restart stamp. Without an identity, or with
      # one the instance's checks refuse, the arguments come back unchanged.
      bind =
        args:
        if !ok then
          args
        else
          args
          // {
            annotations =
              (args.annotations or { })
              // resolved.rendered.serviceAccountAnnotations
              // {
                ${kixKeys.cloudIdentity} = recordJson;
              };
            requires = (args.requires or [ ]) ++ requires;
            _cloudIdentity = {
              inherit (resolved.rendered) podLabels;
              stamp = builtins.hashString "sha256" recordJson;
            };
          };
    };

  # The handle of an instance without an identity.
  unset = handle {
    resolved = resolve {
      value = null;
      provider = null;
    };
    requires = [ ];
  };

  # Return assertions for a package whose software calls `cloud`'s API with
  # either the instance's cloud identity or a credentials Secret. They refuse
  # neither and both. `cloud` null means the software calls no cloud API
  # that a cloud identity reaches, and the assertions refuse an identity.
  # `secretDependency` names the Secret's dependency in the messages, and
  # `id` is the change record a package that starts to refuse neither or
  # both gives those two refusals.
  orSecret =
    {
      identity,
      secret,
      cloud,
      what,
      secretDependency ? null,
      id ? null,
    }:
    let
      fields =
        lib.optionalAttrs (secretDependency != null) { dependency = secretDependency; }
        // lib.optionalAttrs (id != null) { inherit id; };
      depText = if secretDependency == null then "a credentials Secret" else "`deps.${secretDependency}`";
      wireText =
        if secretDependency == null then
          "provide a credentials Secret"
        else
          "set `deps.${secretDependency}` to a Secret instance";
    in
    if cloud == null then
      [
        {
          assertion = !identity.isSet;
          message = "`cloudIdentity` is set on this instance, but ${what} does not use a cloud identity. Kix refuses `cloudIdentity` here because ${what} would ignore those credentials.";
          fix = "Remove `cloudIdentity` from this instance.";
        }
      ]
    else
      [
        (
          {
            assertion = identity.isSet || secret != null;
            message = "${what} requires ${clouds.${cloud}} credentials, but this instance sets neither `cloudIdentity.${cloud}` nor ${depText}. Kix stopped because the pods would have no credentials for ${clouds.${cloud}}.";
            fix = "Set `cloudIdentity.${cloud}` on this instance, or ${wireText}.";
          }
          // fields
        )
        (
          {
            assertion = !(identity.isSet && secret != null);
            message = "Both `cloudIdentity` and ${depText} are set on this instance, but ${what} can use only one credential source. Kix refuses to build the instance when both are set.";
            fix = "Keep either `cloudIdentity` or ${depText} on this instance, and remove the other.";
          }
          // fields
        )
        {
          assertion = !identity.isSet || identity.cloud == null || identity.cloud == cloud;
          message = "`cloudIdentity.${toString identity.cloud}` is set on this instance, but ${what} calls the ${clouds.${cloud}} API. Kix refuses this configuration because `cloudIdentity.${toString identity.cloud}` cannot authenticate to ${clouds.${cloud}}.";
          fix = "Replace `cloudIdentity.${toString identity.cloud}` with `cloudIdentity.${cloud}`, or remove `cloudIdentity` and ${wireText}.";
        }
      ];
in
{
  inherit
    type
    irsa
    eksPodIdentity
    gke
    azureWorkloadId
    resolve
    handle
    unset
    orSecret
    ;
}
