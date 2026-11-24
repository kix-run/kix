# Compose workload, Service, env, and policy helpers, and re-export the
# vocabulary modules under `kix.*`.
{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail failOf;
  markers = import ../core/markers.nix { inherit lib; };

  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;

  normalize = import ../core/normalize.nix { inherit lib; };
  versions = import ../core/version.nix { inherit lib; };

  quantity = import ./quantity.nix { inherit lib; };

  mounts = import ./mounts.nix { inherit lib; };
  optionsModule = import ./options.nix { inherit lib; };
  monitorModule = import ./monitor.nix { inherit lib; };
  exposeModule = import ./expose.nix { inherit lib; };
in

rec {

  # Expose annotation keys from `core/annotations.nix`.
  keys = kixKeys;

  # Expose canonical annotation values from `core/annotations.nix`.
  keyValues = kixAnnotations.values;

  # Expose endpoint fact constructors (`core/facts.nix`).
  facts = {
    inherit (import ../core/facts.nix { inherit lib; }) refOnly connect structural;
  };

  # Format and inspect container image references (`{ repository; tag; digest?; }`).
  # These helpers do not validate digest syntax or query a registry. See
  # `pins.nix` for pin file loading and validation.
  image =
    let
      needField =
        image: field:
        let
          v = image.${field} or null;
        in
        if v == null || v == "" then
          fail {
            message = "kix.image.ref: image reference has no '${field}', and got: ${builtins.toJSON image}";
            fix = "An image needs at least { repository, tag }.";
          }
        else
          v;
    in
    {
      # Render `repository:tag` with `@digest` appended when `digest` is non-null.
      # Discard string context so Nix-built image tags do not add build-time
      # store dependencies to rendered manifests while still allowing
      # `kix-image-sources.json` to classify the option value as `nix_built`.
      ref =
        image:
        builtins.unsafeDiscardStringContext (
          "${needField image "repository"}:${needField image "tag"}"
          + lib.optionalString (image.digest or null != null) "@${image.digest}"
        );

      # Return the version the image's tag names, or null when the tag names
      # none. A package publishes it as `out.version`, so an instance that
      # runs another image reports the version it runs.
      version =
        image:
        let
          tag = image.tag or null;
        in
        if tag == null then null else versions.ofTag (builtins.unsafeDiscardStringContext tag);

      # Return true when `image.digest` is present and non-null.
      isPinned = image: (image.digest or null) != null;
    };

  port = name: containerPort: {
    inherit name containerPort;
    protocol = "TCP";
  };

  # Convert an attrset of environment variables into a Kubernetes `env` list,
  # dropping null entries. Each value may be a string or a `valueFrom` attrset
  # (such as `secret.out.keyRef "password"`), which preserves its dependency
  # context so the workload is ordered after the referenced resource.
  mkEnvVars =
    attrs:
    lib.mapAttrsToList (
      name: value:
      if !builtins.isAttrs value || value ? outPath || value ? __toString then
        { inherit name value; }
      else if value ? valueFrom then
        value // { inherit name; }
      else
        fail {
          message = "kix.mkEnvVars: ${name} is an attrset with no `valueFrom`, which would render as an env var whose value is an object. Got: ${builtins.toJSON (builtins.attrNames value)}";
          fix = "Pass a string, or a source such as `secret.out.keyRef \"key\"`.";
        }
    ) (lib.filterAttrs (_: v: v != null) attrs);

  mkEnv = attrs: raw: (mkEnvVars attrs) ++ raw;

  # Merge `overrides` into `base` with `lib.recursiveUpdate`, failing if
  # `overrides` touches any attribute path in `locked` or replaces a parent of
  # a locked path with a non-attrset value. `option` is the instance option
  # that holds `overrides`, and the error names it. Set it to null when
  # `overrides` comes from somewhere else, such as an argument of a function
  # the package publishes in `out`. `object` names the Kubernetes object the
  # merge builds, `{ kind; name; namespace ? null; }`, when the instance
  # builds several from one option.
  mergeGuarded =
    {
      scope ? null,
      who ? null,
      locked,
      option ? "extraSpec",
      what ? null,
      object ? null,
    }:
    base: overrides:
    let
      scopeFail =
        let
          f = failOf "mergeGuarded" { inherit scope who; };
        in
        if what != null then
          f {
            id = "K0998";
            message = "kix.mergeGuarded no longer accepts `what`. That argument is now named `option`.";
            fix = "Rename `what` to `option`.";
          }
        else
          f;

      # Return the shortest proper prefix of `path` that `overrides` sets to a
      # non-attrset, or null when none exists.
      replacingAncestor =
        path:
        lib.findFirst (
          prefix:
          lib.hasAttrByPath prefix overrides && !builtins.isAttrs (lib.getAttrFromPath prefix overrides)
        ) null (map (n: lib.take n path) (lib.range 1 (builtins.length path - 1)));

      describe =
        path:
        let
          shown = lib.concatStringsSep "." path;
          ancestor = replacingAncestor path;
          value = lib.getAttrFromPath ancestor overrides;
        in
        if lib.hasAttrByPath path overrides then
          shown
        else if ancestor == null then
          null
        else
          "${shown} (replaced by `${lib.concatStringsSep "." ancestor} = ${
            if value == null then "null" else "<${builtins.typeOf value}>"
          }`)";

      touched = builtins.filter (d: d != null) (map describe locked);
    in
    if touched != [ ] then
      let
        pronoun = if builtins.length touched == 1 then "it" else "them";
      in
      scopeFail {
        inherit option object;
        message = "${
          if option == null then "The overrides set" else "${option} overrides"
        } ${lib.concatStringsSep ", " touched}, which this package sets itself.";
        fix = "Remove ${pronoun}${lib.optionalString (option != null) " from ${option}"}.";
      }
    else
      builtins.seq scopeFail (lib.recursiveUpdate base overrides);

  # Validate Kubernetes resource quantities (`vocab/quantity.nix`).
  types.quantity = quantity.type;

  # Parse a Kubernetes quantity `q` into millicores when `resource` is "cpu"
  # and into bytes otherwise, rounded down, or return null when `q` is not a
  # valid quantity.
  parseQuantity = quantity.parse;

  # Merge package `defaults`, user `env` (`kix.options.env`), and package-owned
  # variables into an attrset for `kix.mkEnvVars`.
  #
  # Each entry in `owned` has `{ vars ? { }; names ? [ ]; from; fix ? null; }`
  # or `{ names; reason; fix ? null; }`. Without `fix`, the error tells the
  # user to remove the variable from `option`. `vars` are added to the result, while
  # `names` reserves variables delivered via `envFrom` or refused outright.
  # Throws if `env` defines any key in `vars` or `names` (even as null). The
  # error names `option`, the instance option that holds `env`. It says a
  # variable comes `from` somewhere, or that the package does not accept it
  # and why, when the group gives a `reason`.
  mergeEnv =
    {
      scope ? null,
      who ? null,
      option ? "env",
      owned ? [ ],
      defaults ? { },
    }:
    env:
    let
      scopeFail = failOf "mergeEnv" { inherit scope who; };
      hits =
        group:
        builtins.filter (n: env ? ${n}) (builtins.attrNames (group.vars or { }) ++ group.names or [ ]);
      lines = builtins.concatMap (
        group:
        let
          h = hits group;
        in
        lib.optional (h != [ ]) {
          inherit option;
          message =
            "${option} sets ${lib.concatStringsSep ", " h}, which "
            + (
              if group ? reason then
                "this package does not accept: ${group.reason}"
              else
                "${if builtins.length h == 1 then "comes" else "come"} from ${group.from}."
            );
          fix = group.fix or "Remove ${if builtins.length h == 1 then "it" else "them"} from ${option}.";
        }
      ) owned;
    in
    if lines != [ ] then
      scopeFail lines
    else
      builtins.seq scopeFail (
        defaults // env // lib.foldl' (acc: group: acc // group.vars or { }) { } owned
      );

  # Validate that `args` does not set any CLI flag in `owned`, and return
  # `args` unchanged.
  #
  # `owned` maps each refused flag to the reason and the remedy. The message
  # reads `<option> sets "<flag>", which this package does not accept:
  # <reason>`, so a reason fits a flag the package sets itself and a flag it
  # does not support. The error names the instance and its package from
  # `scope`.
  #
  # `args` is either a list of command-line words or an attrset of flags
  # keyed by flag name, the form a VictoriaMetrics CR's `extraArgs` takes.
  # List words match an owned flag exactly, as `--flag=value`, or as a short
  # flag with an attached value (such as `-c/etc/x`, which also matches
  # multi-character single-dash Go flags like `-vmodule=x` when `-v` is
  # owned). Attrset keys match an owned name exactly once their leading
  # dashes are removed.
  guardArgs =
    {
      scope ? null,
      who ? null,
      option ? "extraArgs",
      owned,
    }:
    args:
    let
      scopeFail = failOf "guardArgs" { inherit scope who; };
      isShortFlag = flag: builtins.match "-[^-]" flag != null;
      flagOf =
        arg:
        lib.findFirst (
          flag: arg == flag || lib.hasPrefix "${flag}=" arg || (isShortFlag flag && lib.hasPrefix flag arg)
        ) null (builtins.attrNames owned);
      # An attrset key names the flag without dashes, but a key written with
      # them still reaches the program, so the match ignores leading dashes.
      flagOfKey = key: builtins.head (builtins.match "-*(.*)" key);
      # Each hit as the text the user wrote and the owned flag it matched.
      hits =
        if builtins.isAttrs args then
          builtins.concatMap (
            key:
            lib.optional (owned ? ${flagOfKey key}) {
              written = key;
              flag = flagOfKey key;
            }
          ) (builtins.attrNames args)
        else
          builtins.concatMap (
            arg:
            let
              flag = flagOf arg;
            in
            lib.optional (flag != null) {
              written = arg;
              inherit flag;
            }
          ) args;
      lines = map (
        { written, flag }:
        {
          inherit option;
          message = "${option} sets \"${written}\", which this package does not accept: ${owned.${flag}}";
        }
      ) hits;
    in
    if lines != [ ] then scopeFail lines else builtins.seq scopeFail args;

  # Validate that a secret dependency `dep` declares all required `keys` (and
  # at least one key group in `anyOf` when set) in `dep.out.keys`, then return
  # `dep`. Read `keyRef` through the returned value so validation runs first.
  checkSecretKeys =
    {
      who,
      arg,
      dep,
      keys ? [ ],
      anyOf ? null,
    }:
    let
      declared = if dep.out.keys or null == null then [ ] else dep.out.keys;
      missingOf = names: builtins.filter (k: !(builtins.elem k declared)) names;
      missingKeys = missingOf keys;
      groupMet = anyOf == null || builtins.any (group: missingOf group == [ ]) anyOf;
      showGroup = group: "[${lib.concatStringsSep ", " group}]";
      wanted =
        lib.optional (missingKeys != [ ]) (lib.concatStringsSep ", " missingKeys)
        ++ lib.optional (!groupMet) "one of ${lib.concatMapStringsSep " or " showGroup anyOf}";
      declaredText = if declared == [ ] then "no keys" else lib.concatStringsSep ", " declared;
    in
    if dep == null || wanted == [ ] then
      dep
    else
      fail {
        message = "${who}: deps.${arg} resolved to secret \"${dep.out.name}\", which declares ${declaredText}; this package reads ${lib.concatStringsSep " and " wanted}.";
        fix = "Add them to that instance's keys (a SOPS secret lists them in keys), or wire another secret with deps.${arg} = ref.<ns>.<instance>.";
      };

  # Build a network policy for operand pods created at runtime by an operator,
  # or return null when no policy is needed.
  #
  # Drops `ingress`/`ingressDeny` or `egress`/`egressDeny` sections for
  # directions the cluster does not enforce (`scope.networkPolicyEnforced`),
  # because including an unenforced direction would isolate the pods in that
  # direction. Returns null when `scope` has no enforcer or all sections were
  # dropped.
  operandPolicy =
    {
      scope,
      name,
      spec,
    }:
    let
      enforced = scope.networkPolicyEnforced;
      sections = {
        ingress = [
          "ingress"
          "ingressDeny"
        ];
        egress = [
          "egress"
          "egressDeny"
        ];
      };
      unenforced =
        lib.optionals (!enforced.ingress) sections.ingress
        ++ lib.optionals (!enforced.egress) sections.egress;
      enforcedSpec = removeAttrs spec unenforced;
      hasSection = s: builtins.any (k: s ? ${k}) (sections.ingress ++ sections.egress);
    in
    if scope.networkPolicyEnforcer == null || (hasSection spec && !hasSection enforcedSpec) then
      null
    else
      scope.networkPolicyEnforcer.netpol.mkPolicy {
        mkResource = scope.mkResource;
        extraArgs = {
          inherit name;
          spec = enforcedSpec;
          labels = {
            ${kixKeys.derived} = "true";
            ${kixKeys.policyType} = "operator-managed-workload";
          };
          extraDeps = [ ];
        };
      };

  service = {
    extractPorts =
      workload:
      let
        containers = workload.rawManifest.spec.template.spec.containers or [ ];
        allPorts = builtins.concatMap (c: c.ports or [ ]) containers;
      in
      map (
        cp:
        {
          port = cp.containerPort;
          protocol = cp.protocol or "TCP";
        }
        // lib.optionalAttrs (cp ? name) {
          name = cp.name;
        }
      ) allPorts;

    fromWorkload =
      {
        name,
        type ? "ClusterIP",
        ports ? null,
        ...
      }@cfg:
      workload:
      let
        finalPorts = if ports != null then ports else service.extractPorts workload;
        firstPort = if finalPorts != [ ] then toString (builtins.head finalPorts).port else null;
        autoOutputs = lib.optionalAttrs (firstPort != null) { port = firstPort; };
        passthrough = removeAttrs cfg [
          "name"
          "type"
          "ports"
        ];

        workloadPortNames = lib.unique (
          builtins.concatMap (c: builtins.catAttrs "name" (c.ports or [ ])) (
            workload.rawManifest.spec.template.spec.containers or [ ]
          )
        );
        workloadPortNumbers = builtins.listToAttrs (
          builtins.concatMap (
            c:
            map (cp: {
              name = cp.name;
              value = cp.containerPort;
            }) (builtins.filter (cp: cp ? name) (c.ports or [ ]))
          ) (workload.rawManifest.spec.template.spec.containers or [ ])
        );
        badTargets = builtins.filter (
          p:
          (p ? targetPort)
          && builtins.isString p.targetPort
          && !(builtins.elem p.targetPort workloadPortNames)
        ) finalPorts;
        # Resolve named `targetPort` values to numbers while the workload is
        # available, because Cilium 1.19 drops egress traffic when derived
        # network-policy rules use named ports.
        resolvedPorts = map (
          p:
          if (p ? targetPort) && builtins.isString p.targetPort then
            p // { targetPort = workloadPortNumbers.${p.targetPort}; }
          else
            p
        ) finalPorts;
        _portCheck =
          if ports != null && badTargets != [ ] then
            fail {
              message =
                "service.fromWorkload '${name}': targetPort(s) [${
                  builtins.concatStringsSep ", " (map (p: "\"${p.targetPort}\"") badTargets)
                }] do not match any named container port on the workload. "
                + "Declared container ports: [${builtins.concatStringsSep ", " workloadPortNames}].";
            }
          else
            null;
      in
      # Merge passthrough fields into the generated Service so additions such
      # as `spec.clusterIP` preserve its selector and ports.
      builtins.seq _portCheck (
        lib.recursiveUpdate {
          apiVersion = "v1";
          kind = "Service";
          inherit name;
          spec = {
            inherit type;
            selector = workload.out.selector;
            ports = resolvedPorts;
          };
          outputs = autoOutputs // (cfg.outputs or { });
        } (removeAttrs passthrough [ "outputs" ])
      );
  };

  inherit (normalize) keep;

  untrackedRef = markers.mkUntrackedRef;

  providedLoadBalancerClass = markers.mkProvidedLoadBalancerClass;

  inherit (mounts)
    mount
    _injectMounts
    withMounts
    withMountsOn
    ;

  options = optionsModule;

  healthCheck = import ./health-check.nix {
    inherit
      lib
      image
      mkEnvVars
      mount
      withMountsOn
      ;
  };

  inherit (exposeModule)
    ingress
    httpRoute
    gatewayPathType
    expose
    ;

  inherit (monitorModule)
    monitor
    alerts
    reconcileErrorsAlert
    ;
}
