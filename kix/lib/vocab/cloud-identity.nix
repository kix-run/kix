# Define the role a workload gets in a cloud: the values a cluster author
# gives a package's credentials dependency (`kix.cloudIdentity.aws`, `gcp`,
# `azure`), `use`, which a package calls on that dependency, and
# `annotationsFor`, for a ServiceAccount an operator creates.
#
# The cluster author writes the principal in its cloud's own terms as the
# value of a dependency, where a Secret instance would otherwise go:
# `deps.providerCredentials = kix.cloudIdentity.aws { roleArn = "..."; };`.
# How the cluster delivers it is chosen with the cluster: a flavor, or a
# module such as `kix.modules.experimental.irsa-webhook`, puts a mechanism
# (`cloud-identity-mechanisms.nix`) in the `out.cloudIdentity` of the
# instance that claims the `cloudIdentity` role. The scope's `sealResource`
# renders a bound ServiceAccount through it (`scope/builders.nix`).
{ lib }:

let
  kixKeys = (import ../core/annotations.nix).keys;
  errors = import ../core/error.nix { inherit lib; };

  inherit (import ./cloud-identity-mechanisms.nix { inherit lib; }) mechanismType;
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
        message = "`${call}` expects an attribute set `{ ... }`, but got a value of type `${builtins.typeOf args}`, so Kix rejected this cloud identity.";
        fix = "Pass the fields in braces: `${call} { ${template} }`.";
      }
    else if unknown != [ ] then
      {
        message = "`${call}` has no field ${quoted unknown}, so Kix rejected this cloud identity. Valid fields: ${quoted names}.";
        fix = "Remove ${quoted unknown} from `${call} { ... }`, or replace it with a valid field (${quoted names}).";
      }
    else if missing != [ ] then
      {
        message = "`${call}` is missing required field ${quoted missing}. Kix rejected this cloud identity because ${clouds.${cloud}} authentication requires it.";
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
        message = "`kix.cloudIdentity.aws` field `roleArn` is \"${args.roleArn}\", which is not a valid AWS IAM role ARN, so Kix rejected this cloud identity.";
        fix = "Set `roleArn` to a full IAM role ARN with a 12-digit AWS account ID, such as `\"arn:aws:iam::111122223333:role/external-dns\"`.";
      }
    else if
      cloud == "gcp" && args ? serviceAccount && !(matches googleAccountPattern args.serviceAccount)
    then
      {
        message = "`kix.cloudIdentity.gcp` field `serviceAccount` is \"${args.serviceAccount}\", which is not a valid Google Cloud service account email, so Kix rejected this cloud identity.";
        fix = "Set `serviceAccount` to a `<name>@<project>.iam.gserviceaccount.com` email, such as `\"external-dns@my-project.iam.gserviceaccount.com\"`, or omit `serviceAccount` (`kix.cloudIdentity.gcp { }`) when granting IAM roles directly to the Kubernetes ServiceAccount.";
      }
    else if cloud == "azure" && !(matches guidPattern args.clientId) then
      {
        message = "`kix.cloudIdentity.azure` field `clientId` is \"${args.clientId}\", which is not a valid GUID, so Kix rejected this cloud identity.";
        fix = "Set `clientId` to the 36-character GUID of your Azure managed identity or app registration, such as `\"00000000-0000-0000-0000-000000000000\"`.";
      }
    else if cloud == "azure" && args ? tenantId && !(matches guidPattern args.tenantId) then
      {
        message = "`kix.cloudIdentity.azure` field `tenantId` is \"${args.tenantId}\", which is not a valid GUID, so Kix rejected this cloud identity.";
        fix = "Set `tenantId` to your 36-character Azure tenant ID (GUID), or omit `tenantId` to use the cluster's default tenant.";
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
    description = "a cloud identity for ${clouds.${cloud}} (`kix.cloudIdentity.${cloud} { ... }`)";
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
      # How a cluster chooses a mechanism for each cloud.
      setUp = {
        aws = "On EKS, include `kix.flavors.eks` in `modules`. On a self-managed cluster running `amazon-eks-pod-identity-webhook`, add `kix.modules.experimental.irsa-webhook` to `modules`.";
        gcp = "On GKE, include `kix.flavors.gke` or `kix.flavors.gke-autopilot` in `modules`. Kix does not yet support Google Cloud workload identity outside GKE.";
        azure = "On AKS, include `kix.flavors.aks` in `modules`. On a self-managed cluster running the Azure Workload Identity webhook, add `kix.modules.experimental.azure-workload-identity-webhook` to `modules`.";
      };
      problem =
        if mechanism == null then
          {
            message = "This instance uses `${call}`, but this cluster is not configured for cloud identities, so Kix could not configure ${clouds.${identity.cloud}} authentication on its ServiceAccount and pods.";
            fix = "${setUp.${identity.cloud}} If this cluster does not support cloud identities, pass a Secret instance (`ref.<namespace>.<instance>`) instead.";
          }
        else if (mechanism._type or null) != mechanismType then
          {
            message = "`${providerName}` claims the `cloudIdentity` role, but its `out.cloudIdentity` is not a supported cloud identity mechanism, so Kix rejected it.";
            fix = "Remove `\"cloudIdentity\"` from `roles` on `${providerName}`, and use a built-in cloud flavor (`kix.flavors.eks`, `gke`, `gke-autopilot`, or `aks`) or a webhook module (`kix.modules.experimental.irsa-webhook` or `azure-workload-identity-webhook`) instead.";
          }
        else if mechanism.cloud != identity.cloud then
          {
            message = "This instance uses `${call}`, but `${providerName}` configures this cluster for ${clouds.${mechanism.cloud}} with ${mechanism.description}. Kix rejected this cloud identity because this cluster can only issue ${clouds.${mechanism.cloud}} pod identities.";
            fix = "To call ${clouds.${identity.cloud}} from this cluster, pass a Secret instance (`ref.<namespace>.<instance>`) instead. To use this cluster's ${clouds.${mechanism.cloud}} pod identities, change the dependency to `kix.cloudIdentity.${mechanism.cloud} { ... }` (and update the instance's `config` if needed). If the cluster itself runs on ${clouds.${identity.cloud}}, change the cluster flavor or `${providerName}`.";
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
            message = "With its current configuration, this package does not authenticate with a cloud identity, so Kix rejected `${call} { ... }`.";
            fix = "Pass a Secret instance (`ref.<namespace>.<instance>`) instead, or remove the dependency.";
          }
        else
          {
            message = "This instance passes `${call} { ... }` (${clouds.${dep.cloud}}), but it is configured to call ${clouds.${cloud}}, so Kix rejected the mismatched cloud identity.";
            fix = "Change the dependency to `kix.cloudIdentity.${cloud} { ... }` or to a Secret instance (`ref.<namespace>.<instance>`) with ${clouds.${cloud}} credentials, or change the instance's `config` to use ${clouds.${dep.cloud}}.";
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
    ;
}
