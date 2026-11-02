# Define reusable package option schemas (`kix.options.*`).
{ lib }:

let
  quantity = import ./quantity.nix { inherit lib; };

  # Return true when `name` is a valid Kubernetes ResourceRequirements key.
  isResourceName =
    name:
    builtins.elem name [
      "cpu"
      "memory"
      "ephemeral-storage"
    ]
    || builtins.match "hugepages-.+" name != null
    || lib.hasInfix "/" name;

  # Strip null leaves and empty sections from a `kix.options.resources` value.
  # Validate undeclared resource names here because a submodule `freeformType`
  # does not run its own `check`.
  cleanResources =
    value:
    let
      dropNulls = lib.filterAttrs (_: v: v != null);
      side =
        sideName:
        let
          kept = dropNulls value.${sideName};
          bad = builtins.filter (n: !(isResourceName n)) (builtins.attrNames kept);
        in
        if bad != [ ] then
          throw "kix.options.resources: ${
            lib.concatMapStringsSep ", " (n: "${sideName}.${n}") bad
          } is not a resource name. Use cpu, memory or ephemeral-storage, hugepages-<size>, or an extended resource whose name contains \"/\" (nvidia.com/gpu)."
        else
          kept;
      requests = side "requests";
      limits = side "limits";
    in
    lib.optionalAttrs (requests != { }) { inherit requests; }
    // lib.optionalAttrs (limits != { }) { inherit limits; }
    // lib.optionalAttrs (value.claims != null) { claims = map dropNulls value.claims; };
in
{
  # Build a container image submodule option (`repository`, `tag`, `digest`,
  # `pullPolicy`, and pin metadata).
  #
  # When an instance overrides only some fields, the remaining fields keep
  # the package defaults. The default `digest` is kept only while `config.tag`
  # matches the package's `tag`.
  #
  # Set `tagText` when a package derives `config.image.tag` from another
  # option so generated docs show the expression while `digest` still compares
  # against `tag`. Leave `repository` or `tag` null in framework packages that
  # have no default image of their own.
  image =
    {
      repository ? null,
      tag ? null,
      digest ? null,
      pullPolicy ? "IfNotPresent",
      tagText ? null,
      description ? "Container image for this instance. Set it from a pin file (`kix.pins`) so the deployed reference is committed and resolved.",
    }:
    assert lib.assertMsg (digest == null || tag != null)
      "kix.options.image: digest ${digest} is set without the tag it was resolved from. Pass `tag` too.";
    let
      hasDefault = repository != null && tag != null;
      default = {
        inherit
          repository
          tag
          digest
          pullPolicy
          ;
      };
      # Use `__pretty` so `toPretty` renders `tagText` as a literal expression
      # rather than a quoted string.
      shownDefault = default // {
        tag = {
          __pretty = lib.id;
          val = tagText;
        };
      };
    in
    lib.mkOption {
      inherit description;
      type = lib.types.submodule (
        { config, ... }:
        {
          options = {
            repository = lib.mkOption (
              {
                type = lib.types.str;
                description = "Image repository, registry host included.";
              }
              // lib.optionalAttrs (repository != null) { default = repository; }
            );
            tag = lib.mkOption (
              {
                type = lib.types.str;
                description = "Image tag. What was asked for.";
              }
              // lib.optionalAttrs (tag != null) { default = tag; }
              // lib.optionalAttrs (tagText != null) { defaultText = lib.literalExpression tagText; }
            );
            digest = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = if tag != null && config.tag == tag then digest else null;
              defaultText = lib.literalMD "the package's digest while `tag` is the package's tag, otherwise null";
              description = "Resolved manifest digest, `sha256:` followed by 64 hex characters. What will actually run. Null means not resolved.";
            };
            pullPolicy = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = pullPolicy;
              description = "imagePullPolicy for containers using this image. Null leaves it to Kubernetes.";
            };
            sourceRev = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Revision of the source the image was built from, when Kix built it. Null for upstream images.";
            };
            promotedBy = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Who resolved this pin, for the record. Null when unknown.";
            };
            resolvedAt = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "When this pin was resolved, RFC 3339. Null when unknown.";
            };
            note = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Whatever a person wanted to say about this pin. Kix never reads it and a promotion never discards it. Declared here for the same reason as the three fields above: a pin carries its own record-keeping, and the option accepts the whole pin rather than a subset of it.";
            };
          };
        }
      );
    }
    // (
      if hasDefault then
        { inherit default; }
      else
        {
          default = { };
          defaultText = lib.literalMD "none: an instance sets ${
            lib.concatMapStringsSep " and " (f: "`${f}`") (
              lib.optional (repository == null) "repository" ++ lib.optional (tag == null) "tag"
            )
          }";
        }
    )
    // lib.optionalAttrs (hasDefault && tagText != null) {
      defaultText = lib.literalExpression (
        lib.generators.toPretty {
          multiline = true;
          allowPrettyValues = true;
        } shownDefault
      );
    };

  # Build a container `resources` submodule option (`requests`, `limits`, and
  # `claims`) that evaluates to a cleaned Kubernetes `ResourceRequirements`
  # attrset.
  #
  # Package defaults may set `cpu`, `memory`, and `ephemeral-storage`.
  # Instances may also set `hugepages-<size>` and extended resources (such as
  # `nvidia.com/gpu`) or set a field to null to clear its default.
  resources =
    {
      requests ? { },
      limits ? { },
      description ? "Container resource requests and limits. Each field keeps its default until set, and null removes a default.",
    }:
    let
      known = [
        "cpu"
        "memory"
        "ephemeral-storage"
      ];
      badDefaults = builtins.filter (k: !(builtins.elem k known)) (
        builtins.attrNames requests ++ builtins.attrNames limits
      );
      side =
        defaults:
        lib.mkOption {
          type = lib.types.submodule {
            freeformType = lib.types.attrsOf quantity.type;
            options = lib.genAttrs known (
              name:
              lib.mkOption {
                type = lib.types.nullOr quantity.type;
                default = defaults.${name} or null;
                description = "The ${name} quantity. Null leaves it unset.";
              }
            );
          };
          default = { };
          description = "Resource quantities by name.";
        };
      shownDefault = cleanResources {
        inherit requests limits;
        claims = null;
      };
    in
    if badDefaults != [ ] then
      throw "kix.options.resources: defaults may set cpu, memory and ephemeral-storage; ${lib.concatStringsSep ", " badDefaults} is not one of them."
    else
      lib.mkOption {
        inherit description;
        default = { };
        defaultText = lib.literalExpression (lib.generators.toPretty { } shownDefault);
        type = lib.types.submodule {
          options = {
            requests = side requests;
            limits = side limits;
            claims = lib.mkOption {
              type = lib.types.nullOr (
                lib.types.listOf (
                  lib.types.submodule {
                    options = {
                      name = lib.mkOption {
                        type = lib.types.str;
                        description = "Name of an entry in the pod's `resourceClaims`.";
                      };
                      request = lib.mkOption {
                        type = lib.types.nullOr lib.types.str;
                        default = null;
                        description = "Request within the claim to use. Null uses the whole claim.";
                      };
                    };
                  }
                )
              );
              default = null;
              description = "Dynamic resource claims the container uses. Null leaves it unset.";
            };
          };
        };
        apply = cleanResources;
      };

  # Extra container environment variables, merged via `kix.mergeEnv` so
  # package-owned variables cannot be overridden.
  env = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.nullOr (
        lib.mkOptionType {
          name = "envValue";
          description = "string or env var source with `valueFrom`";
          descriptionClass = "noun";
          check = v: builtins.isString v || (builtins.isAttrs v && v ? valueFrom);
          merge = lib.options.mergeEqualOption;
        }
      )
    );
    default = { };
    description = "Extra environment variables. A value is a string, a `fieldRef` source such as `{ valueFrom.fieldRef.fieldPath = \"metadata.name\"; }`, or a `secretKeyRef` source naming a Secret managed outside Kix with `kix.untrackedRef`. A credential that comes from a dependency is wired by the package. Null removes a variable the package sets by default.";
  };

  ingress = {
    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Ingress hostname. Null = auto-derive from cluster.domain.";
    };
    annotations = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra ingress annotations.";
    };
  };

  monitor = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable metrics endpoint and monitoring resources (ServiceMonitor, PrometheusRules) when prometheus is available.";
    };
    interval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Scrape interval (e.g. \"30s\"). Null = use Prometheus default.";
    };
  };

  # The `metrics` options of a package whose scrape an operator configures,
  # so the package renders only rules (`kix.alerts`) and has no scrape to
  # switch or time.
  alerts = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Render the package's alert rules when a `prometheus` dependency is present. The operator's scrape of the workload does not depend on it.";
    };
  };

  # Options read by `kix.healthCheck` for packages that define a post-deploy
  # probe.
  healthCheck = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run the package's post-deploy probe (kix.healthCheck) once its resources are ready. A failing probe fails the deploy before the activation switches.";
    };
    retryFor = lib.mkOption {
      type = lib.types.int;
      default = 90;
      description = "Seconds the probe keeps re-checking before it gives up, so a target still restarting from the rollout does not fail the deploy. The Job's deadline is sized from it.";
    };
  };
}
