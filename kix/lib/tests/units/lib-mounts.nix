# Tests for kix.withMounts and kix.withMountsOn (vocab/mounts.nix): which
# containers receive the mounts, where the pod template is, and how a
# volume declared twice is handled.

{ lib, kixlib, ... }:

let
  inherit (kixlib) mount withMounts withMountsOn;

  # A PersistentVolumeClaim whose name carries string context, as a
  # resource built by scope.mkResource does.
  pvc = {
    out.name = builtins.toFile "data-claim" "";
    namespace.name = "app";
  };

  container = name: {
    inherit name;
    image = "example";
  };

  deployment = podSpec: {
    name = "app";
    spec.template.spec = podSpec;
  };

  mountsOf = name: workload: (lib.findFirst (c: c.name == name) null workload).volumeMounts or [ ];
  mainMounts = name: workload: mountsOf name workload.spec.template.spec.containers;
  initMounts = name: workload: mountsOf name workload.spec.template.spec.initContainers;
  volumeNames = workload: map (v: v.name) workload.spec.template.spec.volumes;

  throws = v: !(builtins.tryEval (builtins.deepSeq v true)).success;

  tmp = mount.emptyDir {
    name = "tmp";
    mountPath = "/tmp";
  };
  data = mount.pvc pvc { mountPath = "/data"; };
in
{
  # A list of names mounts into each named container and no other, and
  # declares each volume once.
  lib-mounts-list-of-names =
    let
      w = withMountsOn [ "web" "sidecar" ] [ tmp ] (deployment {
        containers = [
          (container "web")
          (container "sidecar")
          (container "other")
        ];
      });
    in
    map (m: m.mountPath) (mainMounts "web" w) == [ "/tmp" ]
    && map (m: m.mountPath) (mainMounts "sidecar" w) == [ "/tmp" ]
    && mainMounts "other" w == [ ]
    && volumeNames w == [ "tmp" ];

  # A name is searched in initContainers too, and a workload without
  # initContainers does not gain an empty list of them.
  lib-mounts-init-container-target =
    let
      w = withMountsOn [ "migrate" "web" ] [ data ] (deployment {
        initContainers = [ (container "migrate") ];
        containers = [ (container "web") ];
      });
      plain = withMounts [ data ] (deployment {
        containers = [ (container "web") ];
      });
    in
    map (m: m.mountPath) (initMounts "migrate" w) == [ "/data" ]
    && map (m: m.mountPath) (mainMounts "web" w) == [ "/data" ]
    && !(plain.spec.template.spec ? initContainers);

  # Without a name, the one main container receives the mounts, and init
  # containers do not count.
  lib-mounts-main-container-only =
    let
      w = withMounts [ tmp ] (deployment {
        initContainers = [ (container "migrate") ];
        containers = [ (container "web") ];
      });
    in
    map (m: m.mountPath) (mainMounts "web" w) == [ "/tmp" ] && initMounts "migrate" w == [ ];

  # A CronJob's pod template is under spec.jobTemplate.
  lib-mounts-cronjob-path =
    let
      w = withMounts [ tmp ] {
        name = "nightly";
        spec.jobTemplate.spec.template.spec.containers = [ (container "job") ];
      };
      pod = w.spec.jobTemplate.spec.template.spec;
    in
    map (v: v.name) pod.volumes == [ "tmp" ]
    && map (m: m.mountPath) (mountsOf "job" pod.containers) == [ "/tmp" ]
    && !(w.spec ? template);

  # The same volume mounted from two calls, and twice at different paths
  # in one call, is declared once. The first declaration stays, with the
  # dependency context its claim name carries.
  lib-mounts-identical-volume-once =
    let
      sub = mount.pvc pvc {
        mountPath = "/data/sub";
        subPath = "sub";
      };
      w =
        lib.pipe
          (deployment {
            initContainers = [ (container "migrate") ];
            containers = [
              (container "web")
              (container "sidecar")
            ];
          })
          [
            (withMountsOn "web" [
              data
              sub
            ])
            (withMountsOn [ "migrate" "sidecar" ] [ data ])
          ];
      volumes = w.spec.template.spec.volumes;
    in
    map (v: v.name) volumes == [ (builtins.unsafeDiscardStringContext pvc.out.name) ]
    && builtins.getContext (builtins.head volumes).persistentVolumeClaim.claimName != { }
    &&
      map (m: m.mountPath) (mainMounts "web" w) == [
        "/data"
        "/data/sub"
      ]
    && map (m: m.mountPath) (mainMounts "sidecar" w) == [ "/data" ]
    && map (m: m.mountPath) (initMounts "migrate" w) == [ "/data" ];

  # Two volumes of one name with different sources fail the build, whether
  # the first came from a mount or was written in the pod spec.
  lib-mounts-different-source-throws =
    let
      clash = mount.emptyDir {
        name = builtins.unsafeDiscardStringContext pvc.out.name;
        mountPath = "/scratch";
      };
      twoCalls = lib.pipe (deployment { containers = [ (container "web") ]; }) [
        (withMounts [ data ])
        (withMounts [ clash ])
      ];
      withSpec = withMounts [ tmp ] (deployment {
        containers = [ (container "web") ];
        volumes = [
          {
            name = "tmp";
            emptyDir.sizeLimit = "1Gi";
          }
        ];
      });
    in
    throws twoCalls && throws withSpec;

  # Two Secrets of one name in two namespaces are two volumes, so they
  # fail the build under one volume name; the same Secret from the same
  # namespace is one volume.
  lib-mounts-different-namespace-throws =
    let
      tls =
        ns:
        mount.secret {
          out.name = "tls";
          namespace.name = ns;
        } { mountPath = "/${ns}"; };
      twoNamespaces =
        withMounts
          [
            (tls "app")
            (tls "platform")
          ]
          (deployment {
            containers = [ (container "web") ];
          });
      oneNamespace =
        withMounts
          [
            (tls "app")
            (tls "app")
          ]
          (deployment {
            containers = [ (container "web") ];
          });
    in
    throws twoNamespaces && volumeNames oneNamespace == [ "tls" ];

  # A name that matches no container fails the build.
  lib-mounts-unknown-name-throws =
    let
      w = withMountsOn "wbe" [ tmp ] (deployment {
        initContainers = [ (container "migrate") ];
        containers = [ (container "web") ];
      });
      partly = withMountsOn [ "web" "typo" ] [ tmp ] (deployment {
        containers = [ (container "web") ];
      });
    in
    throws w && throws partly;

  # withMounts on a pod with several main containers fails the build.
  lib-mounts-with-mounts-several-containers-throws = throws (
    withMounts [ tmp ] (deployment {
      containers = [
        (container "web")
        (container "sidecar")
      ];
    })
  );

  # emptyDir, secret, and the other constructors take readOnly, which
  # appears on the volumeMount only when set.
  lib-mounts-read-only =
    let
      ro = mount.emptyDir {
        name = "tmp";
        mountPath = "/tmp";
        readOnly = true;
      };
      secret = mount.secret pvc {
        mountPath = "/secret";
        readOnly = true;
      };
      w =
        lib.pipe
          (deployment {
            initContainers = [ (container "init") ];
            containers = [ (container "web") ];
          })
          [
            (withMountsOn "init" [ tmp ])
            (withMountsOn "web" [
              ro
              secret
            ])
          ];
    in
    map (m: m.readOnly or null) (mainMounts "web" w) == [
      true
      true
    ]
    && map (m: m.readOnly or null) (initMounts "init" w) == [ null ]
    &&
      volumeNames w == [
        "tmp"
        (builtins.unsafeDiscardStringContext pvc.out.name)
      ];
}
