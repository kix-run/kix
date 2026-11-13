# Build volume mount descriptors and inject `volumes` and `volumeMounts` into
# workload specs.
{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
  resourceNamespace =
    resource:
    let
      ns = resource.namespace or null;
    in
    if ns == null then
      null
    else if (ns._type or "") == "k8s-cluster-scoped" then
      null
    else
      ns.name or null;

  stampSourceNamespace =
    sourceKind: resource: sourceAttrs:
    let
      ns = resourceNamespace resource;
    in
    sourceAttrs
    // lib.optionalAttrs (ns != null) {
      _kix = {
        namespace = ns;
        source = sourceKind;
      };
    };

  # Describe a volume's source for an error message.
  describeVolume =
    v:
    let
      src = removeAttrs v [
        "name"
        "_kix"
      ];
    in
    if src ? persistentVolumeClaim then
      "the PersistentVolumeClaim '${src.persistentVolumeClaim.claimName}'"
    else if src ? configMap then
      "the ConfigMap '${src.configMap.name}'"
    else if src ? secret then
      "the Secret '${src.secret.secretName}'"
    else if src ? emptyDir then
      "an emptyDir${lib.optionalString (src.emptyDir != { }) " with ${builtins.toJSON src.emptyDir}"}"
    else if src ? hostPath then
      "the hostPath '${src.hostPath.path}'"
    else
      builtins.toJSON src;

  # Describe two sources declared under one volume name. When both read
  # the same (two Secrets of one name), add the namespace and the
  # settings that differ, such as `items` or `defaultMode`.
  describeConflict =
    a: b:
    let
      same = describeVolume a == describeVolume b;
      nsOf = v: v._kix.namespace or null;
      settingsOf =
        v:
        let
          src = removeAttrs v [
            "name"
            "_kix"
          ];
          inner = builtins.attrValues src;
        in
        if builtins.length inner == 1 && builtins.isAttrs (builtins.head inner) then
          builtins.head inner
        else
          { };
      keys = lib.unique (builtins.attrNames (settingsOf a) ++ builtins.attrNames (settingsOf b));
      differing = builtins.filter (
        k: ((settingsOf a).${k} or null) != ((settingsOf b).${k} or null)
      ) keys;
      detail =
        v:
        let
          set = lib.filterAttrs (_: val: val != null) (
            lib.genAttrs differing (k: (settingsOf v).${k} or null)
          );
        in
        lib.optionalString (same && nsOf a != nsOf b && nsOf v != null) " in namespace '${nsOf v}'"
        + lib.optionalString (same && differing != [ ]) (
          if set == { } then " without ${joinNames differing}" else " with ${builtins.toJSON set}"
        );
    in
    "${describeVolume a}${detail a} and ${describeVolume b}${detail b}";

  # "a", "a and b", or "a, b, and c".
  joinNames =
    names:
    let
      n = builtins.length names;
    in
    if n <= 1 then
      builtins.concatStringsSep "" names
    else if n == 2 then
      "${builtins.head names} and ${lib.last names}"
    else
      "${builtins.concatStringsSep ", " (lib.init names)}, and ${lib.last names}";

  # Add `mounts` to the pod template of `attrs`: each volume goes into the
  # pod's `volumes` once, and a volumeMount into every container that
  # `target` names. `target` is null (the pod's one main container), a
  # container name, or a list of names; both `containers` and
  # `initContainers` are searched. The pod template is
  # `spec.jobTemplate.spec.template.spec` when the workload has a
  # `jobTemplate` (a CronJob), else `spec.template.spec`.
  _injectMounts =
    target: mounts: attrs:
    let
      fn = if target == null then "kix.withMounts" else "kix.withMountsOn";
      workload =
        if attrs ? name then
          "workload '${attrs.name}'"
        else if attrs ? metadata.name then
          "workload '${attrs.metadata.name}'"
        else
          "the workload";

      validMounts = builtins.filter (m: m != null) mounts;
      volumes = map (m: { inherit (m) name; } // m.source) validMounts;

      isCronJob = attrs.spec ? jobTemplate;
      jobSpec = attrs.spec.jobTemplate.spec or { };
      template = if isCronJob then jobSpec.template or { } else attrs.spec.template or { };
      podSpec = template.spec or { };
      # Rebuilt with `//` at each level so that no pod field is forced
      # here: a workload that is never rendered, such as an import's, must
      # not evaluate its containers.
      withPodSpec =
        ps:
        attrs
        // {
          spec =
            attrs.spec
            // (
              if isCronJob then
                {
                  jobTemplate = attrs.spec.jobTemplate // {
                    spec = jobSpec // {
                      template = template // {
                        spec = ps;
                      };
                    };
                  };
                }
              else
                {
                  template = template // {
                    spec = ps;
                  };
                }
            );
        };

      # Two declarations of one volume name agree when their sources are
      # equal and, where both carry the `_kix` stamp, their namespaces
      # too: `==` ignores string context, so two Secrets of one name in
      # two namespaces differ only by the stamp. The first declaration is
      # kept, because its source strings carry the dependency context.
      sameVolume =
        a: b:
        removeAttrs a [ "_kix" ] == removeAttrs b [ "_kix" ]
        && (!(a ? _kix) || !(b ? _kix) || a._kix == b._kix);
      addVolume =
        acc: v:
        let
          existing = lib.findFirst (e: e.name == v.name) null acc;
        in
        if existing == null then
          acc ++ [ v ]
        else if sameVolume existing v then
          acc
        else
          fail {
            message = "${fn}: ${workload} declares the volume '${v.name}' twice with different contents: ${describeConflict existing v}.";
            fix = "Give one of them another name with name = \"...\" in kix.mount.*. The same volume mounted into several containers is allowed and needs no rename.";
          };
      mergedVolumes = lib.foldl' addVolume (podSpec.volumes or [ ]) volumes;

      volumeMounts = map (
        m:
        {
          inherit (m) name mountPath;
        }
        // lib.optionalAttrs (m ? subPath && m.subPath != null) { inherit (m) subPath; }
        // lib.optionalAttrs (m.readOnly or false) { readOnly = true; }
      ) validMounts;

      containers = podSpec.containers or [ ];
      initContainers = podSpec.initContainers or [ ];
      containerNames = builtins.catAttrs "name" containers;
      initContainerNames = builtins.catAttrs "name" initContainers;

      injectInto = c: c // { volumeMounts = (c.volumeMounts or [ ]) ++ volumeMounts; };

      names = lib.unique (if builtins.isList target then target else [ target ]);
      unknown = builtins.filter (n: !(builtins.elem n (containerNames ++ initContainerNames))) names;
      targets =
        if target == null then
          if builtins.length containers == 1 then
            containerNames
          else if containers == [ ] then
            [ ]
          else
            fail {
              message = "kix.withMounts: ${workload} has ${toString (builtins.length containers)} containers (${builtins.concatStringsSep ", " containerNames}), so Kix cannot tell which one to mount into.";
              fix = "Name the container: kix.withMountsOn \"${builtins.head containerNames}\" [ ... ], or several: kix.withMountsOn [ ${
                builtins.concatStringsSep " " (map (n: ''"${n}"'') containerNames)
              } ] [ ... ].";
            }
        else if names == [ ] then
          fail {
            message = "kix.withMountsOn: ${workload}: the list of container names is empty, so nothing would be mounted.";
            fix = "Name at least one container.";
          }
        else if unknown != [ ] then
          fail {
            message = "kix.withMountsOn: ${workload} has no container named ${
              builtins.concatStringsSep " or " (map (n: "'${n}'") unknown)
            }, so nothing would be mounted. Its ${
              if builtins.length containerNames == 1 then "container is" else "containers are"
            } ${joinNames containerNames}${
              lib.optionalString (initContainerNames != [ ])
                "; its ${
                  if builtins.length initContainerNames == 1 then "init container is" else "init containers are"
                } ${joinNames initContainerNames}"
            }.";
            fix = "Fix the name in kix.withMountsOn.";
          }
        else
          names;

      injectAll = map (c: if builtins.elem c.name targets then injectInto c else c);
    in
    withPodSpec (
      podSpec
      // {
        volumes = mergedVolumes;
        # The target check runs when the containers are read, which
        # rendering the workload always does.
        containers = builtins.seq targets (injectAll containers);
      }
      // lib.optionalAttrs (podSpec ? initContainers) { initContainers = injectAll initContainers; }
    );
in
{
  mount = {
    pvc =
      resource:
      {
        mountPath,
        name ? null,
        readOnly ? false,
        subPath ? null,
      }:
      if resource == null then
        null
      else
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath readOnly;
          ${if subPath != null then "subPath" else null} = subPath;
          source = stampSourceNamespace "pvc" resource {
            persistentVolumeClaim.claimName = resource.out.name;
          };
        };

    configMap =
      resource:
      {
        mountPath,
        name ? null,
        # ConfigMap volumes are always read-only. Setting `readOnly = true`
        # also records `readOnly` on the container's `volumeMounts` entry.
        readOnly ? false,
        subPath ? null,
        items ? null,
        defaultMode ? null,
      }:
      if resource == null then
        null
      else
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath readOnly;
          ${if subPath != null then "subPath" else null} = subPath;
          source = stampSourceNamespace "configMap" resource {
            configMap = {
              name = resource.out.name;
            }
            // lib.optionalAttrs (items != null) { inherit items; }
            // lib.optionalAttrs (defaultMode != null) { inherit defaultMode; };
          };
        };

    secret =
      resource:
      {
        mountPath,
        name ? null,
        readOnly ? false,
        subPath ? null,
        items ? null,
        defaultMode ? null,
      }:
      if resource == null then
        null
      else
        {
          _type = "kix-mount";
          name = if name != null then name else builtins.unsafeDiscardStringContext resource.out.name;
          inherit mountPath readOnly;
          ${if subPath != null then "subPath" else null} = subPath;
          source = stampSourceNamespace "secret" resource {
            secret = {
              secretName = resource.out.name;
            }
            // lib.optionalAttrs (items != null) { inherit items; }
            // lib.optionalAttrs (defaultMode != null) { inherit defaultMode; };
          };
        };

    emptyDir =
      {
        mountPath,
        name,
        medium ? null,
        sizeLimit ? null,
        readOnly ? false,
        subPath ? null,
      }:
      {
        _type = "kix-mount";
        inherit name mountPath readOnly;
        ${if subPath != null then "subPath" else null} = subPath;
        source.emptyDir =
          { }
          // lib.optionalAttrs (medium != null) { inherit medium; }
          // lib.optionalAttrs (sizeLimit != null) { inherit sizeLimit; };
      };

    hostPath =
      {
        mountPath,
        name,
        hostPath,
        type ? "DirectoryOrCreate",
        readOnly ? false,
        subPath ? null,
      }:
      {
        _type = "kix-mount";
        inherit name mountPath readOnly;
        ${if subPath != null then "subPath" else null} = subPath;
        source.hostPath = {
          path = hostPath;
          inherit type;
        };
      };
  };

  inherit _injectMounts;
  withMounts = _injectMounts null;
  withMountsOn = containerName: _injectMounts containerName;
}
