# Define the role a workload gets in a cloud: the values a cluster author
# gives a package's credentials dependency (`kix.cloudIdentity.aws`, `gcp`,
# `azure`), `use` and `useIdentity`, which a package calls on that
# dependency, `annotationsFor`, for a ServiceAccount an operator creates, and
# `ambientProblem`, which compares two packages' clouds.
#
# The cluster author writes the principal in its cloud's own terms as the
# value of a dependency, where a Secret instance would otherwise go:
# `deps.providerCredentials = kix.cloudIdentity.aws { roleArn = "..."; };`.
# How the cluster delivers it is chosen with the cluster: a flavor, or a
# module such as `kix.modules.experimental.irsa-webhook`, puts a mechanism
# (`cloud-identity-mechanisms.nix`) in the `out.cloudIdentity` of the
# instance that claims the `cloudIdentity` role. The scope's `sealResource`
# renders a bound ServiceAccount through it (`scope/builders.nix`).
#
# The identity goes on the instance that owns the ServiceAccount. When
# another package picks the cloud, the two packages pass the cloud through
# `out` along the dependency between them:
#
# - `out.identityCloud`: a package that owns the ServiceAccount and cannot
#   know the cloud publishes `credentials.cloud` from `useIdentity`. A
#   dependent that reaches a cloud with the pod's own credentials passes
#   that instance to `ambientProblem` as `holder`. A builder in the owner's
#   own `out` passes its instance's name and identity cloud instead.
# - `out.ambientCloud`: a package that picks the cloud and lets the pods
#   use their own credentials publishes that cloud (`"aws"`, `"gcp"`,
#   `"azure"`), or null when it reads a Secret. A dependent that owns the
#   ServiceAccount passes it to `useIdentity` as `cloud`.
{ lib }:

let
  kixKeys = (import ../core/annotations.nix).keys;
  errors = import ../core/error.nix { inherit lib; };

  mechanisms = import ./cloud-identity-mechanisms.nix { inherit lib; };
  inherit (mechanisms) mechanismType;

  # Every built-in mechanism, so a pod check can name the one the platform
  # applied instead. The prefix of IRSA does not change its variables.
  allMechanisms = [
    (mechanisms.irsa { })
    (mechanisms.eksPodIdentity { })
    (mechanisms.gke { })
    (mechanisms.azureWorkloadId { })
  ];
  # A value of every cloud's fields, for reading a mechanism's variable
  # names without an identity.
  anyValue = {
    roleArn = "";
    clientId = "";
    tenantId = null;
    serviceAccount = null;
  };

  # Return what the deploy checks on the pods of a workload bound to
  # `mechanism` with `rendered` as its output, or null when the platform
  # adds no variables. `alternatives` are the other mechanisms of the same
  # cloud, by their variable names, so a pod that got one of them is named.
  podCheckOf =
    mechanism: rendered:
    let
      env = rendered.podEnv or { };
      alternatives = lib.concatMap (
        m:
        let
          r = m.render anyValue;
        in
        lib.optional (m.cloud == mechanism.cloud && m.name != mechanism.name && (r.podEnv or { }) != { }) {
          inherit (m) description;
          env = builtins.attrNames r.podEnv;
          fix = r.podEnvOverrideFix or null;
        }
      ) allMechanisms;
    in
    if env == { } then
      null
    else
      {
        inherit (mechanism) description;
        inherit env alternatives;
        fix = rendered.podEnvFix or null;
        skip = rendered.podEnvSkip or null;
      };
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
  # labels, the restart stamp, and the mechanism's facts about pods:
  # `podCheck` (what the deploy checks, or null), `servesHostNetwork`, and
  # its `description`.
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
        podCheck = podCheckOf mechanism rendered;
        servesHostNetwork = rendered.servesHostNetwork or true;
        inherit (mechanism) description;
      };

  # Return what is wrong with cloud identity `dep` for software that calls
  # `cloud`, as `{ message; fix; }`, or null. `cloud` null means the software
  # takes no cloud identity, and the caller's `unused` is returned. A cloud
  # other than the identity's returns `mismatch`, a function of the two
  # calls, such as "kix.cloudIdentity.aws", and the two cloud names.
  identityProblem =
    {
      dep,
      cloud,
      unused,
      mismatch,
    }:
    if dep.problem != null then
      dep.problem
    else if cloud == null then
      unused "kix.cloudIdentity.${dep.cloud}"
    else if cloud != dep.cloud then
      mismatch {
        given = "kix.cloudIdentity.${dep.cloud}";
        wanted = "kix.cloudIdentity.${cloud}";
        givenCloud = clouds.${dep.cloud};
        wantedCloud = clouds.${cloud};
      }
    else
      null;

  # Put identity `dep` on ServiceAccount arguments, with `arg`, the name of
  # the dependency that holds it, so a later refusal can name it.
  bindTo =
    dep: arg: args:
    args
    // {
      _cloudIdentity = dep // {
        dependency = arg;
      };
    };

  # Return how a message names the dependency `arg` of the instance, or the
  # dependency in general when `arg` is null, as `this` inside a sentence
  # and `This` at its start.
  depWords =
    arg:
    let
      this = if arg == null then "this dependency" else "`deps.${arg}`";
    in
    {
      inherit this;
      This = capitalize this;
    };

  capitalize = s: lib.toUpper (builtins.substring 0 1 s) + builtins.substring 1 (-1) s;

  # Read a credentials dependency that holds a Secret instance or a cloud
  # identity. `cloud` is the cloud whose API the package's software calls
  # (`"aws"`, `"gcp"`, `"azure"`), or null when it takes no cloud identity.
  # `identityGoesTo` names where this cluster takes the identity instead,
  # such as the dependency of another instance that owns the
  # ServiceAccount, for the fix when `cloud` is null. `supportedClouds`
  # lists every cloud the package can call in any configuration, or is null
  # when its `config` can choose any of them. An identity for a cloud
  # outside that list is refused with a message that says the package does
  # not support that cloud, and suggests no change of `config`.
  # Return `{ secret; identity; bind; }`: one of `secret` and `identity` is
  # the dependency and the other is null, and `bind` adds the identity to
  # ServiceAccount arguments. The scope's `sealResource` renders it through
  # the cluster's mechanism, and the workload builders add the pod labels
  # and a restart stamp to every pod template that names that
  # ServiceAccount. Without an identity, `bind` returns its arguments
  # unchanged. `arg` is the name the package takes `dep` under, and a
  # refusal names that dependency of the instance.
  use =
    {
      scope,
      dep,
      cloud,
      identityGoesTo ? null,
      supportedClouds ? null,
      arg ? null,
    }:
    let
      fail = errors.failOf "cloudIdentity.use" {
        inherit scope;
        who = null;
      };
      words = depWords arg;
      problem = identityProblem {
        inherit dep cloud;
        unused = call: {
          message = "${words.This} is set to `${call} { ... }`, but this instance does not authenticate with a cloud identity in its current configuration. Kix rejected the cloud identity.";
          fix =
            "Set ${words.this} to a Secret instance (`ref.<namespace>.<instance>`), or remove it."
            + lib.optionalString (
              identityGoesTo != null
            ) " To authenticate with this cloud identity, move it to ${identityGoesTo}.";
        };
        mismatch =
          m:
          if supportedClouds != null && !(builtins.elem dep.cloud supportedClouds) then
            {
              message = "${words.This} is set to `${m.given} { ... }` (${m.givenCloud}), but this package works only with ${
                lib.concatMapStringsSep " and " (c: clouds.${c}) supportedClouds
              } (${m.givenCloud} is not supported yet). Kix rejected the cloud identity.";
              fix = "Set ${words.this} to `${m.wanted} { ... }` or a Secret instance (`ref.<namespace>.<instance>`) with ${m.wantedCloud} credentials.";
            }
          else
            {
              message = "${words.This} is set to `${m.given} { ... }` (${m.givenCloud}), but this instance is configured to call ${m.wantedCloud}. Kix rejected the cloud identity.";
              fix = "Set ${words.this} to `${m.wanted} { ... }` or a Secret instance (`ref.<namespace>.<instance>`) with ${m.wantedCloud} credentials, or change this instance's `config` to use ${m.givenCloud}.";
            };
      };
    in
    if !(isIdentity dep) then
      {
        secret = dep;
        identity = null;
        bind = args: args;
      }
    else if problem != null then
      fail (problem // { dependency = arg; })
    else
      {
        secret = null;
        identity = dep;
        bind = bindTo dep arg;
      };

  # Read a dependency that holds a cloud identity or nothing, on a package
  # that owns a ServiceAccount whose credentials another package configures.
  # `secretGoesTo` names where the cluster gives a Secret instead, for the
  # fix when `dep` is not a cloud identity. `cloud` is the cloud the pods
  # call, as a dependency's `out.ambientCloud` gives it, and null when that
  # dependency reads a Secret, so any identity is refused. Without `cloud`,
  # only the identity's own fields are checked, because only a dependent
  # knows the cloud. Return `{ identity; cloud; bind; }`: `identity` is the
  # dependency or null, `cloud` is the identity's cloud or null, for
  # `out.identityCloud`, and `bind` works as `use`'s does. `arg` works as
  # `use`'s does.
  useIdentity =
    {
      scope,
      dep,
      secretGoesTo,
      cloud ? null,
      arg ? null,
    }@args:
    let
      fail = errors.failOf "cloudIdentity.useIdentity" {
        inherit scope;
        who = null;
      };
      words = depWords arg;
      depName =
        if builtins.isAttrs dep && dep ? _meta then
          "`${dep._meta.namespaceName}/${dep._meta.instanceName}`"
        else
          "a value of another type";
      problem =
        if !(isIdentity dep) then
          {
            message = "${words.This} accepts only a cloud identity (`kix.cloudIdentity.aws`, `gcp`, or `azure`) or `null`, but got ${depName}. Kix rejected it.";
            fix = "To authenticate with a Secret, pass it to ${secretGoesTo} instead. Otherwise, set ${words.this} to a cloud identity (such as `kix.cloudIdentity.aws { roleArn = \"...\"; }`) or remove it.";
          }
        else if !(args ? cloud) then
          dep.problem
        else
          identityProblem {
            inherit dep cloud;
            unused = call: {
              message = "${words.This} is set to `${call} { ... }`, but this instance's pods read their cloud credentials from a Secret. Kix rejected the unused cloud identity.";
              fix = "To keep using the Secret, remove ${words.this}. To authenticate with this cloud identity instead, remove the Secret from ${secretGoesTo} and configure that instance to use pod credentials.";
            };
            mismatch = m: {
              message = "${words.This} is set to `${m.given} { ... }` (${m.givenCloud}), but this instance's pods call ${m.wantedCloud}. Kix rejected the cloud identity.";
              fix = "Set ${words.this} to `${m.wanted} { ... }`, or change the instance configured for ${m.wantedCloud} to use ${m.givenCloud}.";
            };
          };
    in
    if dep == null then
      {
        identity = null;
        cloud = null;
        bind = sa: sa;
      }
    else if problem != null then
      fail (problem // { dependency = arg; })
    else
      {
        identity = dep;
        inherit (dep) cloud;
        bind = bindTo dep arg;
      };

  # Compare `cloud`, the cloud that an object reaches with the pod's own
  # credentials, with the cloud identity of the instance whose pods make the
  # call. Name that instance in one of two forms. `holder` is a dependency
  # that publishes `out.identityCloud`. `holderName` ("namespace/instance")
  # and `identityCloud` serve a package that checks its own instance, such
  # as a builder in its own `out`. Return a `{ message; fix; }` that names
  # the holder and both clouds when they differ, or null. A holder without
  # an identity is never refused, because its pods may use the node's
  # credentials.
  ambientProblem =
    args:
    let
      hasHolder = args ? holder;
      hasDirect = args ? holderName || args ? identityCloud;
    in
    if
      !(args ? cloud)
      || hasHolder == hasDirect
      || (hasDirect && !(args ? holderName && args ? identityCloud))
    then
      errors.fail {
        message = "`kix.cloudIdentity.ambientProblem` expects `cloud` and either `holder` or both `holderName` and `identityCloud`, but got ${
          if builtins.attrNames args == [ ] then
            "no arguments"
          else
            "`${lib.concatStringsSep "`, `" (builtins.attrNames args)}`"
        }, so Kix could not check the cloud identity.";
        fix = "Pass `{ cloud; holder; }` when checking a dependency instance, or `{ cloud; holderName; identityCloud; }` (with `holderName` set to `\"<namespace>/<instance>\"`) when checking this package's own instance.";
      }
    else if hasHolder then
      ambientProblemOf {
        inherit (args) cloud;
        holderName = "${args.holder._meta.namespaceName}/${args.holder._meta.instanceName}";
        identityCloud = args.holder.out.identityCloud or null;
      }
    else
      ambientProblemOf { inherit (args) cloud holderName identityCloud; };

  ambientProblemOf =
    {
      cloud,
      holderName,
      identityCloud,
    }:
    if cloud == null || identityCloud == null || identityCloud == cloud then
      null
    else
      {
        message = "This instance uses the pod credentials of `${holderName}` to call ${clouds.${cloud}}, but `${holderName}` has a cloud identity for ${clouds.${identityCloud}}, so Kix rejected this configuration.";
        fix = "Change the cloud identity on `${holderName}` to `kix.cloudIdentity.${cloud} { ... }`, configure this instance to use ${clouds.${identityCloud}}, or authenticate with separate credentials instead of pod credentials.";
      };

  # Return the ServiceAccount annotations and pod labels of `identity` for a
  # ServiceAccount that an operator creates from a custom resource, which
  # `bind` cannot reach. `provider` is the package's `cloudIdentity`
  # dependency, the instance that holds the role. With `identity` null,
  # return empty sets.
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
    if identity == null then
      {
        serviceAccountAnnotations = { };
        podLabels = { };
      }
    else if r.problem != null then
      fail r.problem
    else
      { inherit (r) serviceAccountAnnotations podLabels; };
in
{
  inherit
    aws
    gcp
    azure
    isIdentity
    use
    useIdentity
    ambientProblem
    annotationsFor
    render
    ;
}
