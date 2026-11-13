# Warn when a Job under `kix.run/rerun` reads a Secret or ConfigMap that Kix
# builds, but its pod template carries no `checksum/*` annotation for it.
#
# The deploy engine reruns such a Job only when its `kix.run/rerun-hash`
# changes, and that hash covers the Job's own manifest. A new value in a
# Secret the Job reads reaches the hash only through a checksum annotation.
#
# The check reads string context, so it needs no name matching. A reference
# whose name came from a Kix-built object's `out.name` carries that object's
# store path, and so does its `out.contentHash`. A checksum annotation covers
# the reference when its value carries the same path. A Secret named by a
# plain string, or imported with `mkSecretRef`, carries no such path and is
# skipped, because Kix does not know its content.
{ lib, ... }:

let
  kixKeys = (import ../../core/annotations.nix).keys;

  lst = x: if builtins.isList x then x else [ ];

  # Return `{ kind; name; }` for every Secret and ConfigMap a pod spec reads
  # through volumes, projected volumes, env, or envFrom.
  podSpecReads =
    podSpec:
    let
      ref = kind: name: lib.optional (name != null) { inherit kind name; };
      fromSecret = obj: field: ref "Secret" (obj.${field} or null);
      fromConfigMap = obj: ref "ConfigMap" (obj.name or null);
      containers =
        lst (podSpec.containers or [ ])
        ++ lst (podSpec.initContainers or [ ])
        ++ lst (podSpec.ephemeralContainers or [ ]);
    in
    builtins.concatMap (
      v:
      fromSecret (v.secret or { }) "secretName"
      ++ fromConfigMap (v.configMap or { })
      ++ builtins.concatMap (
        src: fromSecret (src.secret or { }) "name" ++ fromConfigMap (src.configMap or { })
      ) (lst (v.projected.sources or [ ]))
    ) (lst (podSpec.volumes or [ ]))
    ++ builtins.concatMap (
      c:
      builtins.concatMap (
        e:
        fromSecret (e.valueFrom.secretKeyRef or { }) "name"
        ++ fromConfigMap (e.valueFrom.configMapKeyRef or { })
      ) (lst (c.env or [ ]))
      ++ builtins.concatMap (
        ef: fromSecret (ef.secretRef or { }) "name" ++ fromConfigMap (ef.configMapRef or { })
      ) (lst (c.envFrom or [ ]))
    ) containers;

  pathsOf = s: if builtins.isString s then builtins.attrNames (builtins.getContext s) else [ ];

  # Return the warnings for every Job in `resources` that reads a Secret or
  # ConfigMap from `readable` (store path to resource) without a checksum
  # annotation whose value carries that resource's store path.
  unhashedReads =
    { resources, readable }:
    builtins.concatMap (
      r:
      let
        m = r.rawManifest or { };
        template = m.spec.template or { };
        annotations = template.metadata.annotations or { };
        covered = lib.genAttrs (builtins.concatMap pathsOf (
          lib.mapAttrsToList (k: v: if lib.hasPrefix "checksum/" k then v else null) annotations
        )) (_: true);
        missing = builtins.filter (read: read.kind == read.target.kind && !(covered ? ${read.path})) (
          builtins.concatMap (
            read:
            map (
              path:
              read
              // {
                inherit path;
                target = readable.${path};
              }
            ) (builtins.filter (p: readable ? ${p}) (pathsOf read.name))
          ) (podSpecReads (template.spec or { }))
        );
        jobName =
          let
            ns = m.metadata.namespace or null;
            name = builtins.unsafeDiscardStringContext (m.metadata.name or "?");
          in
          if ns == null then name else "${builtins.unsafeDiscardStringContext ns}/${name}";
        prefix = if r ? _builtBy then "[${r._builtBy}] " else "";
      in
      if (m.kind or null) != "Job" || !((m.metadata.annotations or { }) ? ${kixKeys.rerun}) then
        [ ]
      else
        lib.unique (
          map (
            read:
            let
              name = builtins.unsafeDiscardStringContext read.name;
            in
            "${prefix}Job ${jobName} has ${kixKeys.rerun}: ${
              m.metadata.annotations.${kixKeys.rerun}
            } and reads ${read.kind} ${name}, "
            + "but its pod template has no checksum annotation for it, so it will not run again when that ${read.kind} changes. "
            + "Add `\"checksum/${name}\" = <resource>.out.contentHash` to the pod template annotations."
          ) missing
        )
    ) resources;
in
{
  config.hooks.clusterProcessors.rerun = ctx: {
    warnings =
      let
        readable = builtins.listToAttrs (
          map
            (r: {
              name = builtins.unsafeDiscardStringContext r.outPath;
              value = r;
            })
            (
              builtins.filter (
                r:
                builtins.elem (r.kind or null) [
                  "Secret"
                  "ConfigMap"
                ]
                && r ? out.contentHash
              ) ctx.resources
            )
        );
      in
      unhashedReads {
        inherit (ctx) resources;
        inherit readable;
      };
  };
}
