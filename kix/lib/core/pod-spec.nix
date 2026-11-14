# Read the Secrets and ConfigMaps a pod spec references.
#
# The key check (`eval/validate-keys.nix`), the Helm ordering
# (`helm-dag.nix`), and the Job rerun hash (`core/resource.nix`) all ask which
# objects a pod reads. They share this reader so they agree about every pod.
# A `name` keeps its string context, so a caller can tell which Kix resource
# it came from.
{ lib }:

let
  # Helm charts can render explicit nulls, which `or` does not catch.
  safeList = v: if builtins.isList v then v else [ ];
  safeAttrs = v: if builtins.isAttrs v then v else { };
in
rec {
  # Return the pod spec of a workload manifest, or `{ }` when it has none.
  podSpecOf =
    r:
    let
      spec = safeAttrs (r.spec or { });
      template =
        if (r.kind or null) == "CronJob" then
          safeAttrs ((safeAttrs ((safeAttrs (spec.jobTemplate or { })).spec or { })).template or { })
        else
          safeAttrs (spec.template or { });
    in
    safeAttrs (template.spec or { });

  # Return one entry for each Secret or ConfigMap reference in `podSpec`:
  # `{ kind; name; key; optional; where; subPath; }`.
  #
  # `key` is the data key the reference reads, or null when it reads the whole
  # object (`envFrom`, or a volume without keyed `items`). A volume with keyed
  # `items` gives one entry per item. A `subPath` mount into a whole-object
  # volume gives an extra entry whose key is the first path segment and whose
  # `subPath` is `{ sub; mountPath; }`. Every other entry has `subPath = null`.
  # Containers, init containers, and ephemeral containers all count.
  reads =
    podSpec:
    let
      containers =
        safeList (podSpec.containers or [ ])
        ++ safeList (podSpec.initContainers or [ ])
        ++ safeList (podSpec.ephemeralContainers or [ ]);

      entry = kind: name: key: optional: where: {
        inherit
          kind
          name
          key
          optional
          where
          ;
        subPath = null;
      };

      # A Secret volume names its object in `secretName`; a projected Secret
      # source and every ConfigMap use `name`.
      sourceReads =
        kind: nameField: src: where:
        let
          s = safeAttrs src;
          name = s.${nameField} or null;
          optional = s.optional or false;
          keyed = builtins.filter (it: builtins.isAttrs it && it ? key) (safeList (s.items or [ ]));
        in
        if name == null then
          [ ]
        else if keyed != [ ] then
          map (it: entry kind name it.key optional "${where} items") keyed
        else
          [ (entry kind name null optional where) ];

      volumeReads = builtins.concatMap (
        v:
        let
          where = "volume ${v.name or "?"}";
        in
        lib.optionals (v ? secret) (sourceReads "Secret" "secretName" v.secret where)
        ++ lib.optionals (v ? configMap) (sourceReads "ConfigMap" "name" v.configMap where)
        ++ builtins.concatMap (
          s:
          lib.optionals (s ? secret) (sourceReads "Secret" "name" s.secret where)
          ++ lib.optionals (s ? configMap) (sourceReads "ConfigMap" "name" s.configMap where)
        ) (safeList ((safeAttrs (v.projected or { })).sources or [ ]))
      ) (safeList (podSpec.volumes or [ ]));

      envReads = builtins.concatMap (
        c:
        builtins.concatMap (
          ev:
          let
            where = "env ${ev.name or "?"} of container ${c.name or "?"}";
            vf = safeAttrs (ev.valueFrom or { });
            read =
              kind: ref:
              let
                r = safeAttrs ref;
              in
              lib.optional (r ? name && r.name != null) (
                entry kind r.name (r.key or null) (r.optional or false) where
              );
          in
          read "Secret" (vf.secretKeyRef or null) ++ read "ConfigMap" (vf.configMapKeyRef or null)
        ) (safeList (c.env or [ ]))
        ++ builtins.concatMap (
          ef:
          let
            where = "envFrom of container ${c.name or "?"}";
            read =
              kind: ref:
              let
                r = safeAttrs ref;
              in
              lib.optional (r ? name && r.name != null) (entry kind r.name null (r.optional or false) where);
          in
          read "Secret" (ef.secretRef or null) ++ read "ConfigMap" (ef.configMapRef or null)
        ) (safeList (c.envFrom or [ ]))
      ) containers;

      volumesByName = builtins.listToAttrs (
        map (v: lib.nameValuePair (v.name or "") v) (safeList (podSpec.volumes or [ ]))
      );

      # A subPath into a Secret or ConfigMap volume without `items` names a
      # key by its first path segment.
      subPathReads = builtins.concatMap (
        c:
        builtins.concatMap (
          m:
          let
            v = volumesByName.${m.name or ""} or { };
            sub = m.subPath or "";
            whole = src: safeList ((safeAttrs src).items or [ ]) == [ ];
            read =
              kind: src: name:
              entry kind name (builtins.head (lib.splitString "/" sub)) (src.optional or false
              ) "container ${c.name or "?"}"
              // {
                subPath = {
                  inherit sub;
                  mountPath = m.mountPath or "?";
                };
              };
          in
          if sub == "" then
            [ ]
          else if v ? secret && (v.secret.secretName or null) != null && whole v.secret then
            [ (read "Secret" v.secret v.secret.secretName) ]
          else if v ? configMap && (v.configMap.name or null) != null && whole v.configMap then
            [ (read "ConfigMap" v.configMap v.configMap.name) ]
          else
            [ ]
        ) (safeList (c.volumeMounts or [ ]))
      ) containers;
    in
    envReads ++ volumeReads ++ subPathReads;
}
