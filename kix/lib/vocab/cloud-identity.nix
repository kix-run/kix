# Define workload cloud identity: the values a cluster author gives a
# package's credentials dependency (`kix.cloudIdentity.aws`, `gcp`,
# `azure`), the mechanisms that deliver them (`irsa`, `eksPodIdentity`,
# `gke`, `azureWorkloadId`), and `use`, which a package calls on that
# dependency.
#
# The cluster author writes the principal in its cloud's own terms as the
# value of a dependency, where a Secret instance would otherwise go:
# `deps.providerCredentials = kix.cloudIdentity.aws { roleArn = "..."; };`.
# The instance that claims the `cloudIdentity` role (a flavour's import, or
# a package that runs the webhook) carries one mechanism in
# `out.cloudIdentity`. The scope's `sealResource` renders a bound
# ServiceAccount through it (`scope/builders.nix`).
{ lib }:

let
  kixKeys = (import ../core/annotations.nix).keys;
  errors = import ../core/error.nix { inherit lib; };

  mechanismType = "kix-cloud-identity-mechanism";
  identityType = "kix-cloud-identity";

  # How a message names each cloud.
  clouds = {
    aws = "AWS";
    gcp = "Google Cloud";
    azure = "Azure";
  };

  roleArnPattern = "arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+";
  googleAccountPattern = "[^@[:space:]]+@[a-z0-9.-]+[.]gserviceaccount[.]com";
  guidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
  matches = pattern: value: builtins.match pattern value != null;

  # The fields each constructor takes: `true` for a required field.
  fieldsOf = {
    aws.roleArn = true;
    gcp.serviceAccount = false;
    azure = {
      clientId = true;
      tenantId = false;
    };
  };

  # Return what is wrong with the arguments of `kix.cloudIdentity.<cloud>`,
  # as `{ message; fix; }`, or null.
  argsProblem =
    cloud: args:
    let
      call = "kix.cloudIdentity.${cloud}";
      fields = fieldsOf.${cloud};
      names = builtins.attrNames fields;
      quoted = fs: lib.concatMapStringsSep ", " (f: "`${f}`") fs;
      unknown = builtins.attrNames (removeAttrs args names);
      missing = builtins.filter (f: fields.${f} && !(args ? ${f})) names;
      notText = builtins.filter (f: args ? ${f} && !(builtins.isString args.${f})) names;
      template = lib.concatMapStringsSep " " (f: "${f} = \"...\";") names;
    in
    if !builtins.isAttrs args then
      {
        message = "`${call}` expects settings in `{ ... }`, got type `${builtins.typeOf args}`, so Kix rejected this cloud identity.";
        fix = "Pass the settings inside braces: `${call} { ${template} }`.";
      }
    else if unknown != [ ] then
      {
        message = "`${call}` has no field ${quoted unknown}, so Kix rejected this cloud identity. Valid fields: ${quoted names}.";
        fix = "Remove ${quoted unknown} from `${call} { ... }`, or replace it with a valid field (${quoted names}).";
      }
    else if missing != [ ] then
      {
        message = "`${call}` is missing required field ${quoted missing}, so Kix rejected it. Kix needs this field to configure ${clouds.${cloud}} authentication on the ServiceAccount.";
        fix = "Add ${
          lib.concatMapStringsSep " and " (f: "`${f} = \"...\";`") missing
        } to `${call} { ... }`.";
      }
    else if notText != [ ] then
      {
        message = "`${call}` field ${quoted notText} must be a string, so Kix rejected this cloud identity.";
        fix = "Set ${quoted notText} to a quoted string, such as `\"...\"`.";
      }
    else if cloud == "aws" && !(matches roleArnPattern args.roleArn) then
      {
        message = "`kix.cloudIdentity.aws` field `roleArn` is \"${args.roleArn}\", which is not a valid AWS IAM role ARN. Kix rejected it because AWS would refuse credentials to the pods.";
        fix = "Set `roleArn` to a full IAM role ARN with a 12-digit AWS account ID, such as `\"arn:aws:iam::111122223333:role/external-dns\"`.";
      }
    else if
      cloud == "gcp" && args ? serviceAccount && !(matches googleAccountPattern args.serviceAccount)
    then
      {
        message = "`kix.cloudIdentity.gcp` field `serviceAccount` is \"${args.serviceAccount}\", which is not a valid Google service account email. Kix rejected it because Google Cloud would refuse credentials to the pods.";
        fix = "Set `serviceAccount` to a full Google service account email, such as `\"external-dns@my-project.iam.gserviceaccount.com\"`, or omit `serviceAccount` (`kix.cloudIdentity.gcp { }`) if IAM roles are granted directly to the Kubernetes ServiceAccount.";
      }
    else if cloud == "azure" && !(matches guidPattern args.clientId) then
      {
        message = "`kix.cloudIdentity.azure` field `clientId` is \"${args.clientId}\", which is not a valid GUID. Kix rejected it because Microsoft Entra Workload ID would refuse tokens to the pods.";
        fix = "Set `clientId` to the client ID (GUID) of the Azure managed identity or app registration, such as `\"00000000-0000-0000-0000-000000000000\"`.";
      }
    else if cloud == "azure" && args ? tenantId && !(matches guidPattern args.tenantId) then
      {
        message = "`kix.cloudIdentity.azure` field `tenantId` is \"${args.tenantId}\", which is not a valid GUID. Kix rejected it because Microsoft Entra Workload ID could not look up the tenant.";
        fix = "Set `tenantId` to the Azure tenant ID (GUID), or remove `tenantId` to use the cluster's default tenant.";
      }
    else
      null;

  # Return a cloud identity value. Its fields are checked when a package
  # reads it (`use`), so the error names the instance that holds it.
  mkIdentity = cloud: args: {
    _type = identityType;
    inherit cloud;
    # How a message that expected another kind of dependency names this
    # value.
    description = "the ${clouds.${cloud}} cloud identity `kix.cloudIdentity.${cloud} { ... }`";
    value = if builtins.isAttrs args then args else { };
    problem = argsProblem cloud args;
  };

  isIdentity = v: builtins.isAttrs v && (v._type or "") == identityType;

  # Return the value an instance gives a credentials dependency to act as a
  # cloud principal. `aws` takes `roleArn`, `gcp` an optional
  # `serviceAccount`, and `azure` `clientId` and an optional `tenantId`.
  aws = mkIdentity "aws";
  gcp = mkIdentity "gcp";
  azure = mkIdentity "azure";

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

  # Render `identity` through the mechanism of the `cloudIdentity` role's
  # provider (`{ ns; inst; out; }`, or null). Return `{ problem; }` with a
  # `{ message; fix; }` when the cluster cannot deliver it, or the
  # ServiceAccount annotations (with `kix.run/cloud-identity`), the pod
  # labels, and the restart stamp.
  render =
    { identity, provider }:
    let
      mechanism = if provider == null then null else provider.out.cloudIdentity or null;
      providerName = "${provider.ns}/${provider.inst}";
      call = "kix.cloudIdentity.${identity.cloud}";
      problem =
        if mechanism == null then
          {
            message = "This instance uses `${call}`, but the cluster has no `cloudIdentity` provider, so Kix cannot configure ${clouds.${identity.cloud}} authentication on its ServiceAccount and pods.";
            fix =
              "On a managed cloud cluster, add `kix.flavors.eks`, `kix.flavors.gke`, `kix.flavors.gke-autopilot`, or `kix.flavors.aks` to `modules` in your cluster definition."
              + " On a self-managed cluster, declare a `cloudIdentity` import using `kix.cloudIdentity.irsa { }`, `kix.cloudIdentity.gke { }`, or `kix.cloudIdentity.azureWorkloadId { }`; for example, for AWS IRSA:"
              + "\n  instances.kube-system.cloud-identity.package = kix.mkImport {"
              + "\n    roles = [ \"cloudIdentity\" ];"
              + "\n    annotationDomains = [ \"eks.amazonaws.com\" ];"
              + "\n    out.cloudIdentity = kix.cloudIdentity.irsa { };"
              + "\n  };"
              + "\nIf this cluster does not support cloud identities, pass a Secret instance (`ref.<namespace>.<instance>`) instead.";
          }
        else if (mechanism._type or null) != mechanismType then
          {
            message = "`${providerName}` claims the `cloudIdentity` role, but its `out.cloudIdentity` is not a `kix.cloudIdentity` mechanism, so Kix cannot configure cloud authentication on this instance's ServiceAccount and pods.";
            fix = "Set `out.cloudIdentity` on `${providerName}` to `kix.cloudIdentity.irsa { }`, `kix.cloudIdentity.eksPodIdentity { }`, `kix.cloudIdentity.gke { }`, or `kix.cloudIdentity.azureWorkloadId { }`.";
          }
        else if mechanism.cloud != identity.cloud then
          {
            message = "This instance uses `${call}`, which does not match this cluster's cloud. `${providerName}` configures the cluster for ${clouds.${mechanism.cloud}} with ${mechanism.description}, so Kix can only attach ${clouds.${mechanism.cloud}} identities to pods here.";
            fix = "Pass a Secret instance (`ref.<namespace>.<instance>`) instead. If this instance should authenticate with this cluster's cloud identity, switch the dependency to `kix.cloudIdentity.${mechanism.cloud} { ... }` (and update the instance's provider setting if needed); if the cluster runs on another cloud, update `${providerName}` or the cluster flavor.";
          }
        else
          null;
      full = {
        mechanism = mechanism.name;
        ${identity.cloud} = identity.value;
      };
      recordJson = builtins.toJSON full;
      rendered = mechanism.render (
        {
          serviceAccount = null;
          tenantId = null;
        }
        // identity.value
      );
    in
    if problem != null then
      { inherit problem; }
    else
      {
        problem = null;
        serviceAccountAnnotations = rendered.serviceAccountAnnotations // {
          ${kixKeys.cloudIdentity} = recordJson;
        };
        inherit (rendered) podLabels;
        stamp = builtins.hashString "sha256" recordJson;
      };

  # Read a credentials dependency that holds a Secret instance or a cloud
  # identity. `cloud` is the cloud whose API the package's software calls
  # (`"aws"`, `"gcp"`, `"azure"`), or null when it takes no cloud identity.
  # Return `{ secret; identity; bind; }`: one of `secret` and `identity` is
  # the dependency and the other is null, and `bind` adds the identity to
  # ServiceAccount arguments. The scope's `sealResource` renders it through
  # the cluster's mechanism, and the workload builders add the pod labels
  # and a restart stamp to every pod template that names that
  # ServiceAccount. Without an identity, `bind` returns its arguments
  # unchanged.
  use =
    {
      scope,
      dep,
      cloud,
    }:
    let
      fail = errors.failOf "cloudIdentity.use" {
        inherit scope;
        who = null;
      };
      call = "kix.cloudIdentity.${dep.cloud}";
    in
    if !(isIdentity dep) then
      {
        secret = dep;
        identity = null;
        bind = args: args;
      }
    else if dep.problem != null then
      fail dep.problem
    else if cloud != dep.cloud then
      fail (
        if cloud == null then
          {
            message = "This instance passes `${call} { ... }`, which this package does not accept for its current configuration, so Kix rejected it. Its pods do not authenticate with a cloud ServiceAccount identity.";
            fix = "Set that dependency to a Secret instance (`ref.<namespace>.<instance>`), or remove it.";
          }
        else
          {
            message = "This instance passes `${call} { ... }`, while the package is configured to call the ${clouds.${cloud}} API, so Kix rejected it. ${clouds.${dep.cloud}} credentials cannot authenticate to ${clouds.${cloud}}.";
            fix = "Set that dependency to `kix.cloudIdentity.${cloud} { ... }` or to a Secret instance (`ref.<namespace>.<instance>`) with ${clouds.${cloud}} credentials, or update the instance's configuration to match the cloud identity.";
          }
      )
    else
      {
        secret = null;
        identity = dep;
        bind = args: args // { _cloudIdentity = dep; };
      };

  # Return the ServiceAccount annotations and pod labels of `identity` for a
  # ServiceAccount that an operator creates from a custom resource, which
  # `bind` cannot reach. `provider` is the package's `cloudIdentity`
  # dependency, the instance that holds the role.
  annotationsFor =
    {
      scope,
      identity,
      provider,
    }:
    let
      fail = errors.failOf "cloudIdentity.annotationsFor" {
        inherit scope;
        who = null;
      };
      r = render {
        inherit identity;
        provider =
          if provider == null then
            null
          else
            {
              ns = provider._meta.namespaceName;
              inst = provider._meta.instanceName;
              inherit (provider) out;
            };
      };
    in
    if r.problem != null then fail r.problem else { inherit (r) serviceAccountAnnotations podLabels; };
in
{
  inherit
    aws
    gcp
    azure
    isIdentity
    use
    annotationsFor
    render
    irsa
    eksPodIdentity
    gke
    azureWorkloadId
    ;
}
