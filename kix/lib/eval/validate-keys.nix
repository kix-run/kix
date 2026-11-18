# Validate that workload env vars, volume `items`, and `subPath` mounts
# reference keys declared on their target Secret or ConfigMap (check 22).
{ lib }:

let
  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;

  podSpec = import ../core/pod-spec.nix { inherit lib; };

  # Helm charts can render `data: null`, whereas Nix's `or` only handles
  # missing attributes.
  attrNamesOf = v: if builtins.isAttrs v then builtins.attrNames v else [ ];

  util = import ../core/util.nix { inherit lib; };
  inherit (util) splitList;
  nsOf = util.namespaceOf;

  cedesData =
    r:
    builtins.any (
      p: lib.hasPrefix "data" p || lib.hasPrefix "binaryData" p || lib.hasPrefix "stringData" p
    ) (splitList (r.metadata.annotations.${kixKeys.cedeFields} or ""));
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
        map (r: {
          objKind = r.kind;
          obj = r.name;
          inherit (r) key where subPath;
        }) (builtins.filter (r: r.key != null && !r.optional) (podSpec.reads (podSpec.podSpecOf w)));
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
