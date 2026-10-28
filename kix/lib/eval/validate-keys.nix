# Validate that workload env vars, volume `items`, and `subPath` mounts
# reference keys declared on their target Secret or ConfigMap (check 22).
{ lib }:

let
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;

  safeList = v: if builtins.isList v then v else [ ];

  # Helm charts can render `data: null`, whereas Nix's `or` only handles
  # missing attributes.
  attrNamesOf = v: if builtins.isAttrs v then builtins.attrNames v else [ ];

  splitList = s: builtins.filter (x: x != "") (map lib.trim (lib.splitString "," (toString s)));

  nsOf = r: r.metadata.namespace or "cluster-scoped";

  getPodSpec =
    r:
    if r.kind == "CronJob" then
      r.spec.jobTemplate.spec.template.spec or { }
    else
      r.spec.template.spec or { };

  cedesData =
    r:
    builtins.any (
      p: lib.hasPrefix "data" p || lib.hasPrefix "binaryData" p || lib.hasPrefix "stringData" p
    ) (splitList ((r.metadata.annotations or { }).${kixKeys.cedeFields} or ""));
in
{
  # Validate that env vars, volume `items`, and `subPath` mounts reference keys
  # that exist on their target Secret or ConfigMap. Known keys come from
  # `kix.run/secret-keys` on `scope.mkSecret`, `kix.run/import-secret-keys` on
  # Secret refs, and `data` or `binaryData` on ConfigMaps. Skip optional
  # references, `kix.untrackedRef` names, Secret resources without
  # `kix.run/secret-keys`, and resources that cede their data fields.
  checkKeyReads =
    {
      workloads,
      byId,
      importIds,
      externalNames,
    }:
    let
      # Return `{ keys }` when the target's keys are known,
      # `{ noKeysListed = true }` for a Secret ref without declared keys, or
      # null when unchecked.
      declaredKeys =
        objKind: ns: name:
        let
          id = "${objKind}/${ns}/${name}";
          r = byId.${id};
          anns = r.metadata.annotations or { };
          refAnns = importIds.${id};
        in
        if externalNames ? "${ns}/${name}" then
          null
        else if byId ? ${id} then
          if cedesData r then
            null
          else if objKind == "Secret" then
            if anns ? ${kixKeys.secretKeys} then { keys = splitList anns.${kixKeys.secretKeys}; } else null
          else
            {
              keys = attrNamesOf (r.data or null) ++ attrNamesOf (r.binaryData or null);
            }
        else if objKind == "Secret" && importIds ? ${id} then
          if refAnns ? ${kixKeys.importSecretKeys} then
            { keys = splitList refAnns.${kixKeys.importSecretKeys}; }
          else
            { noKeysListed = true; }
        else
          null;

      keyReadsOf =
        w:
        let
          ps = getPodSpec w;
          containers = safeList (ps.containers or [ ]) ++ safeList (ps.initContainers or [ ]);
          volumes = safeList (ps.volumes or [ ]);
          volumesByName = builtins.listToAttrs (
            map (v: {
              name = v.name or "";
              value = v;
            }) volumes
          );
          itemReads =
            objKind: obj: items: where:
            map (it: {
              inherit objKind obj where;
              key = it.key;
              subPath = null;
            }) (builtins.filter (it: it ? key) (safeList items));

          envReads = builtins.concatMap (
            c:
            builtins.concatMap (
              ev:
              let
                read =
                  objKind: ref:
                  if ref == null || (ref.optional or false) || !(ref ? name) || !(ref ? key) then
                    [ ]
                  else
                    [
                      {
                        inherit objKind;
                        obj = ref.name;
                        key = ref.key;
                        where = "env ${ev.name or "?"} of container ${c.name or "?"}";
                        subPath = null;
                      }
                    ];
              in
              read "Secret" (ev.valueFrom.secretKeyRef or null)
              ++ read "ConfigMap" (ev.valueFrom.configMapKeyRef or null)
            ) (safeList (c.env or [ ]))
          ) containers;

          volumeReads = builtins.concatMap (
            v:
            let
              where = "volume ${v.name or "?"} items";
              sec = v.secret or null;
              cm = v.configMap or null;
              sources = safeList ((v.projected or { }).sources or [ ]);
            in
            (
              if sec != null && !(sec.optional or false) && sec ? secretName then
                itemReads "Secret" sec.secretName (sec.items or [ ]) where
              else
                [ ]
            )
            ++ (
              if cm != null && !(cm.optional or false) && cm ? name then
                itemReads "ConfigMap" cm.name (cm.items or [ ]) where
              else
                [ ]
            )
            ++ builtins.concatMap (
              s:
              let
                ps' = s.secret or null;
                pc = s.configMap or null;
              in
              (
                if ps' != null && !(ps'.optional or false) && ps' ? name then
                  itemReads "Secret" ps'.name (ps'.items or [ ]) where
                else
                  [ ]
              )
              ++ (
                if pc != null && !(pc.optional or false) && pc ? name then
                  itemReads "ConfigMap" pc.name (pc.items or [ ]) where
                else
                  [ ]
              )
            ) sources
          ) volumes;

          # A subPath into a Secret or ConfigMap volume without `items`
          # names a key by its first path segment.
          subPathReads = builtins.concatMap (
            c:
            builtins.concatMap (
              m:
              let
                v = volumesByName.${m.name or ""} or { };
                sub = m.subPath or "";
                key = builtins.head (lib.splitString "/" sub);
                read = objKind: obj: {
                  inherit objKind obj key;
                  where = "container ${c.name or "?"}";
                  subPath = {
                    inherit sub;
                    mountPath = m.mountPath or "?";
                  };
                };
                noItems = src: safeList (src.items or [ ]) == [ ];
              in
              if sub == "" then
                [ ]
              else if
                v ? secret && !(v.secret.optional or false) && v.secret ? secretName && noItems v.secret
              then
                [ (read "Secret" v.secret.secretName) ]
              else if
                v ? configMap && !(v.configMap.optional or false) && v.configMap ? name && noItems v.configMap
              then
                [ (read "ConfigMap" v.configMap.name) ]
              else
                [ ]
            ) (safeList (c.volumeMounts or [ ]))
          ) containers;
        in
        envReads ++ volumeReads ++ subPathReads;
    in
    builtins.concatMap (
      w:
      let
        ns = nsOf w;
        who = "${w.kind} ${ns}/${w.metadata.name}";
      in
      builtins.concatMap (
        read:
        let
          decl = declaredKeys read.objKind ns read.obj;
          listText = keys: if keys == [ ] then "no keys" else "keys ${builtins.concatStringsSep ", " keys}";
        in
        if decl == null then
          [ ]
        else if decl ? noKeysListed then
          [
            "${who} reads key '${read.key}' of Secret '${read.obj}' (${read.where}), whose scope.mkSecretRef declares no keys, so the deploy cannot check the Secret holds it. List the keys the pod reads in keys."
          ]
        else if builtins.elem read.key decl.keys then
          [ ]
        else if read.subPath != null then
          [
            "${who} mounts subPath '${read.subPath.sub}' of ${read.objKind} '${read.obj}' at ${read.subPath.mountPath} (${read.where}), and ${read.objKind} '${read.obj}' declares ${listText decl.keys}, not '${read.key}'. The kubelet would mount an empty directory there: the container fails to start if its image has a file at ${read.subPath.mountPath}, and otherwise reads a directory instead of the file. Add the key to the ${read.objKind}, or mount a declared one."
          ]
        else
          [
            "${who} reads key '${read.key}' of ${read.objKind} '${read.obj}' (${read.where}), which declares ${listText decl.keys}. The container would not start. Add the key to the ${read.objKind}, or read a declared one."
          ]
      ) (lib.unique (keyReadsOf w))
    ) workloads;
}
