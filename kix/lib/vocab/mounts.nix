# Build volume mount descriptors and inject `volumes` and `volumeMounts` into
# workload specs.
{ lib }:

let
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

  _injectMounts =
    targetName: mounts: attrs:
    let
      validMounts = builtins.filter (m: m != null) mounts;
      volumes = map (m: { inherit (m) name; } // m.source) validMounts;

      existingVolumes = attrs.spec.template.spec.volumes or [ ];
      existingNames = builtins.catAttrs "name" existingVolumes;
      newNames = builtins.catAttrs "name" volumes;
      allNames = existingNames ++ newNames;
      seen = lib.foldl' (acc: n: acc // { ${n} = (acc.${n} or 0) + 1; }) { } allNames;
      dupes = lib.filter (n: seen.${n} > 1) (lib.attrNames seen);
      _dupeCheck =
        if dupes != [ ] then
          throw "kix.withMounts: duplicate volume name(s) [${builtins.concatStringsSep ", " dupes}]. "
          + "Pass `name = \"...\";` to kix.mount.* to disambiguate, or drop the duplicate."
        else
          null;
      volumeMounts = map (
        m:
        {
          inherit (m) name mountPath;
        }
        // lib.optionalAttrs (m ? subPath && m.subPath != null) { inherit (m) subPath; }
        // lib.optionalAttrs (m.readOnly or false) { readOnly = true; }
      ) validMounts;

      templateSpec = attrs.spec.template.spec or { };
      containers = templateSpec.containers or [ ];

      injectInto = c: c // { volumeMounts = (c.volumeMounts or [ ]) ++ volumeMounts; };

      injectedContainers =
        if targetName != null then
          map (c: if c.name == targetName then injectInto c else c) containers
        else if builtins.length containers == 1 then
          [ (injectInto (builtins.head containers)) ]
        else if containers == [ ] then
          containers
        else
          throw "withMounts: the workload has multiple containers. Use withMountsOn to select the container to mount into";
    in
    builtins.seq _dupeCheck attrs
    // {
      spec = attrs.spec // {
        template = attrs.spec.template // {
          spec = templateSpec // {
            volumes = (templateSpec.volumes or [ ]) ++ volumes;
            containers = injectedContainers;
          };
        };
      };
    };
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
          inherit mountPath;
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
        subPath ? null,
      }:
      {
        _type = "kix-mount";
        inherit name mountPath;
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
