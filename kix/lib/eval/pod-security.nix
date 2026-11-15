# Check rendered pod templates against the Kubernetes Pod Security Standards
# (https://kubernetes.io/docs/concepts/security/pod-security-standards/).
#
# When a namespace sets `pod-security.kubernetes.io/enforce`, Kubernetes
# rejects pods that violate that level. `violations` inspects a manifest's pod
# template at a given level and returns each disallowed field with the value
# to set.
#
# Checked fields:
#   - baseline: host namespaces, privileged containers, Windows HostProcess,
#     hostPath volumes, host ports, capabilities outside the baseline set,
#     Unconfined seccomp profiles, and non-Default /proc mounts.
#   - restricted (in addition to baseline): volume types,
#     allowPrivilegeEscalation, runAsNonRoot, runAsUser 0, seccomp profiles,
#     and capabilities.
#
# AppArmor, SELinux options, sysctls, and Windows restricted-level exemptions
# (`spec.os.name: windows`) are not checked here and remain enforced by
# cluster admission at deploy time.

{ lib }:

let
  inherit (import ../core/util.nix { inherit lib; }) attrsOr listOr plain;
  workloadKinds = import ../core/workload-kinds.nix { inherit lib; };
  podSpecReader = import ../core/pod-spec.nix { inherit lib; };

  # Return the pod spec of a built-in pod kind's manifest, or null for any
  # other manifest.
  podSpecOf = m: if workloadKinds.isPodKind m then podSpecReader.podSpecOf m else null;

  baselineCapabilities = [
    "AUDIT_WRITE"
    "CHOWN"
    "DAC_OVERRIDE"
    "FOWNER"
    "FSETID"
    "KILL"
    "MKNOD"
    "NET_BIND_SERVICE"
    "SETFCAP"
    "SETGID"
    "SETPCAP"
    "SETUID"
    "SYS_CHROOT"
  ];

  restrictedVolumeTypes = [
    "configMap"
    "csi"
    "downwardAPI"
    "emptyDir"
    "ephemeral"
    "persistentVolumeClaim"
    "projected"
    "secret"
  ];

  podWhere = "pod";

  containersOf =
    pod:
    map (c: {
      where = "container '${plain (c.name or "?")}'";
      sc = attrsOr (c.securityContext or null);
      inherit c;
    }) (listOr (pod.containers or null))
    ++ map (c: {
      where = "init container '${plain (c.name or "?")}'";
      sc = attrsOr (c.securityContext or null);
      inherit c;
    }) (listOr (pod.initContainers or null));

  podSc = pod: attrsOr (pod.securityContext or null);

  baseline =
    pod:
    let
      podContext = podSc pod;
      containers = containersOf pod;
      perContainer =
        f:
        lib.concatMap (
          x:
          map (problem: {
            inherit (x) where;
            inherit problem;
          }) (f x)
        ) containers;
    in
    map
      (field: {
        where = podWhere;
        problem = "${field} is true; remove it";
      })
      (
        builtins.filter (f: pod.${f} or false == true) [
          "hostNetwork"
          "hostPID"
          "hostIPC"
        ]
      )
    ++ lib.optional ((attrsOr (podContext.windowsOptions or null)).hostProcess or false == true) {
      where = podWhere;
      problem = "securityContext.windowsOptions.hostProcess is true; remove it";
    }
    ++ lib.optional ((attrsOr (podContext.seccompProfile or null)).type or null == "Unconfined") {
      where = podWhere;
      problem = "securityContext.seccompProfile.type is Unconfined; set RuntimeDefault";
    }
    ++ map (v: {
      where = podWhere;
      problem = "volume '${plain (v.name or "?")}' is a hostPath volume; use another volume type";
    }) (builtins.filter (v: v ? hostPath) (listOr (pod.volumes or null)))
    ++ perContainer (
      { c, sc, ... }:
      let
        added = listOr ((attrsOr (sc.capabilities or null)).add or null);
      in
      lib.optional (sc.privileged or false == true) "securityContext.privileged is true; remove it"
      ++ lib.optional (
        (attrsOr (sc.windowsOptions or null)).hostProcess or false == true
      ) "securityContext.windowsOptions.hostProcess is true; remove it"
      ++ lib.optional (
        (attrsOr (sc.seccompProfile or null)).type or null == "Unconfined"
      ) "securityContext.seccompProfile.type is Unconfined; set RuntimeDefault"
      ++ lib.optional (
        !(builtins.elem (sc.procMount or null) [
          null
          "Default"
        ])
      ) "securityContext.procMount is ${plain sc.procMount}; remove it"
      ++ map (cap: "securityContext.capabilities.add has ${plain cap}; remove it") (
        builtins.filter (cap: !(builtins.elem cap baselineCapabilities)) added
      )
      ++ map (
        p: "port ${toString (p.containerPort or "?")} sets hostPort ${toString p.hostPort}; remove it"
      ) (builtins.filter (p: (p.hostPort or 0) != 0) (listOr (c.ports or null)))
    );

  # Check restricted-only fields so `baseline pod ++ restricted pod` does not
  # duplicate findings.
  restricted =
    pod:
    let
      podContext = podSc pod;
      containers = containersOf pod;
      perContainer =
        f:
        lib.concatMap (
          x:
          map (problem: {
            inherit (x) where;
            inherit problem;
          }) (f x)
        ) containers;
      podSeccomp = (attrsOr (podContext.seccompProfile or null)).type or null;
    in
    map
      (v: {
        where = podWhere;
        problem = "volume '${plain (v.name or "?")}' is of type ${
          builtins.concatStringsSep ", " (builtins.attrNames (removeAttrs v [ "name" ]))
        }; use one of ${builtins.concatStringsSep ", " restrictedVolumeTypes}";
      })
      (
        builtins.filter (
          v:
          !(v ? hostPath)
          && builtins.any (t: !(builtins.elem t restrictedVolumeTypes)) (
            builtins.attrNames (removeAttrs v [ "name" ])
          )
        ) (listOr (pod.volumes or null))
      )
    ++ lib.optional (podContext.runAsNonRoot or null == false) {
      where = podWhere;
      problem = "securityContext.runAsNonRoot is false; set it to true";
    }
    ++ lib.optional (podContext.runAsUser or null == 0) {
      where = podWhere;
      problem = "securityContext.runAsUser is 0; set a non-zero user";
    }
    ++ perContainer (
      { sc, ... }:
      let
        capabilities = attrsOr (sc.capabilities or null);
        added = listOr (capabilities.add or null);
      in
      lib.optional (sc.allowPrivilegeEscalation or null != false)
        "securityContext.allowPrivilegeEscalation is ${
          if sc.allowPrivilegeEscalation or null == true then "true" else "unset"
        }; set it to false"
      ++ lib.optional (
        sc.runAsNonRoot or null == false
      ) "securityContext.runAsNonRoot is false; set it to true"
      ++
        lib.optional (sc.runAsNonRoot or null == null && podContext.runAsNonRoot or null == null)
          "securityContext.runAsNonRoot is unset here and on the pod; set it to true on the container or in the pod's securityContext"
      ++ lib.optional (sc.runAsUser or null == 0) "securityContext.runAsUser is 0; set a non-zero user"
      ++
        lib.optional (((attrsOr (sc.seccompProfile or null)).type or null) == null && podSeccomp == null)
          "securityContext.seccompProfile.type is unset here and on the pod; set RuntimeDefault (or Localhost) on the container or in the pod's securityContext"
      ++ lib.optional (
        !(builtins.elem "ALL" (listOr (capabilities.drop or null)))
      ) "securityContext.capabilities.drop does not include ALL; set it to [ \"ALL\" ]"
      ++ map (
        cap:
        "securityContext.capabilities.add has ${plain cap}; remove it (only NET_BIND_SERVICE is allowed)"
      ) (builtins.filter (cap: cap != "NET_BIND_SERVICE" && builtins.elem cap baselineCapabilities) added)
    );
in
{
  # Return Pod Security Standards violations for `manifest` at `level`
  # ("privileged", "baseline", or "restricted") as `[ { where, problem } ]`.
  violations =
    level: manifest:
    let
      pod = podSpecOf manifest;
    in
    if pod == null || level == "privileged" then
      [ ]
    else if level == "baseline" then
      baseline pod
    else
      baseline pod ++ restricted pod;
}
