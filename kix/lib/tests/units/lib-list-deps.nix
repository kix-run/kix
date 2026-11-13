# Tests for a list of refs in `deps.<arg>`. Each element resolves and is
# checked as a single `deps.<arg> = ref.<ns>.<inst>` is (eval/resolve.nix
# `resolveArg`), and the package receives a list of instance handles. The
# messages are read from eval/resolve.nix loaded through `caught`, which
# turns `throw` into `{ thrown = <message>; }`.

{
  lib,
  k8s,
  kixlib,
  kixKeys,
  mkCluster,
  baseInstances,
  manifests,
  ofKind,
  byName,
  evalFails,
  ...
}:

let
  # `kix.fail` (core/error.nix) is loaded the same way, so its errors are
  # caught too.
  caught = builtins.scopedImport {
    throw = message: { thrown = message; };
    import = path: if baseNameOf path == "error.nix" then caught path else import path;
  };
  resolveCaught = caught ../../eval/resolve.nix { inherit lib kixlib; };

  # A ConfigMap named `name` whose `marker` a consumer can inject.
  target =
    {
      name,
      metaExtra ? { },
    }:
    {
      meta = {
        version = "test";
      }
      // metaExtra;
      options.marker = lib.mkOption {
        type = lib.types.str;
        default = "unset";
      };
      build =
        {
          self,
          scope,
          config,
          ...
        }:
        {
          cm = scope.mkResource {
            apiVersion = "v1";
            kind = "ConfigMap";
            inherit name;
            extra.data.marker = config.marker;
          };
          root = self.cm;
        };
    };

  # Records the type of `logins` and the names of the instances it holds.
  consumer = {
    meta.version = "test";
    deps.logins.config.marker = "injected";
    build =
      {
        self,
        scope,
        logins,
        ...
      }:
      {
        cm = scope.mkResource {
          apiVersion = "v1";
          kind = "ConfigMap";
          name = "consumer";
          extra.data = {
            type = builtins.typeOf logins;
            names = builtins.concatStringsSep "," (map (l: l.out.name) (lib.toList logins));
          };
        };
        root = self.cm;
      };
  };

  clusterWith =
    extra: logins:
    mkCluster [
      baseInstances
      (
        { ref, ... }:
        lib.recursiveUpdate {
          instances.infra.a.package = target { name = "login-a"; };
          instances.infra.b = {
            package = target { name = "login-b"; };
            optional = true;
          };
          instances.appns.consumer = {
            package = consumer;
            deps.logins = logins ref;
          };
        } extra
      )
    ];

  consumerData = cluster: (byName "consumer" (ofKind "ConfigMap" (manifests cluster))).data;
  markerOf =
    name: cluster: (byName name (ofKind "ConfigMap" (manifests cluster))).data.marker or "absent";
  dependsOn = m: (m.metadata.annotations or { }).${kixKeys.dependsOn} or "";
  dependsOnPart =
    cluster: ns: inst:
    lib.hasInfix (k8s.extractStoreHash cluster.instances.${ns}.${inst}.raw.cm.outPath) (
      dependsOn (byName "consumer" (ofKind "ConfigMap" (manifests cluster)))
    );
in
{
  # The package receives both handles in order. The consumer depends on
  # both, its config injection reaches both, and the optional one is
  # activated by being named.
  lib-list-deps-list-reaches-package =
    let
      cluster = clusterWith { } (ref: [
        ref.infra.a
        ref.infra.b
      ]);
      data = consumerData cluster;
    in
    (
      data.type == "list"
      && data.names == "login-a,login-b"
      && dependsOnPart cluster "infra" "a"
      && dependsOnPart cluster "infra" "b"
      && markerOf "login-a" cluster == "injected"
      && markerOf "login-b" cluster == "injected"
    )
    || throw "list deps: ${
      builtins.toJSON {
        inherit data;
        a = markerOf "login-a" cluster;
        b = markerOf "login-b" cluster;
      }
    }";

  # A single ref still binds one handle, not a list.
  lib-list-deps-single-ref-unchanged =
    let
      cluster = clusterWith { } (ref: ref.infra.a);
      data = consumerData cluster;
    in
    (
      data.type == "set"
      && data.names == "login-a"
      && dependsOnPart cluster "infra" "a"
      && markerOf "login-a" cluster == "injected"
      && markerOf "login-b" cluster == "absent"
    )
    || throw "single ref: ${builtins.toJSON data}";

  # An element naming a shelf package that nothing auto-instantiated fails
  # the build, and the message names the requester, the dependency, and the
  # element.
  lib-list-deps-missing-element-fails =
    let
      fails = evalFails (
        clusterWith { availablePackages.shelf.package = target { name = "shelf"; }; } (ref: [
          ref.infra.a
          ref.appns.shelf
        ])
      );
      message =
        (resolveCaught.checkRefTargets {
          instances.appns.consumer.deps.logins = [
            {
              _type = "kix-ref";
              namespace = "infra";
              instanceName = "a";
            }
            {
              _type = "kix-ref";
              namespace = "appns";
              instanceName = "shelf";
            }
          ];
          mergedInstances.infra.a = { };
        }).thrown or "";
    in
    (
      fails
      && lib.hasInfix "appns/consumer: deps.logins lists ref.appns.shelf, which is not a declared instance" message
    )
    || throw "missing element: fails=${builtins.toJSON fails} message=${message}";

  # An element in another namespace whose package declares
  # meta.scope = "namespace" is refused, as a single ref to it is. The same
  # list from that namespace builds.
  lib-list-deps-cross-namespace-scoped-refused =
    let
      scoped = {
        instances.infra.c.package = target {
          name = "login-c";
          metaExtra.scope = "namespace";
        };
      };
      listFails = evalFails (
        clusterWith scoped (ref: [
          ref.infra.a
          ref.infra.c
        ])
      );
      singleFails = evalFails (clusterWith scoped (ref: ref.infra.c));
      sameNamespace = mkCluster [
        baseInstances
        (
          { ref, ... }:
          {
            instances.infra.a.package = target { name = "login-a"; };
            instances.infra.c = scoped.instances.infra.c;
            instances.infra.consumer = {
              package = consumer;
              deps.logins = [
                ref.infra.a
                ref.infra.c
              ];
            };
          }
        )
      ];
    in
    (listFails && singleFails && (consumerData sameNamespace).names == "login-a,login-c")
    || throw "cross-namespace: list fails ${builtins.toJSON listFails}, single fails ${builtins.toJSON singleFails}";

  # A list that mixes refs with other values is refused.
  lib-list-deps-mixed-list-refused =
    let
      result = resolveCaught.resolveArg {
        argName = "logins";
        resolutionIndex.byKey = { };
        requesterNamespace = "appns";
        hasDefault = false;
        requester = "appns/consumer";
        requesterName = "consumer";
        explicitOverride = [
          {
            _type = "kix-ref";
            namespace = "infra";
            instanceName = "a";
          }
          "literal"
        ];
      };
    in
    lib.hasInfix "appns/consumer: instances.appns.consumer.deps.logins is a list that mixes ref" (
      result.thrown or ""
    )
    || throw "mixed list: ${builtins.toJSON result}";

  # A list of instance handles in `deps.<arg>` records dependency links for each
  # handle so the annotation-domain check recognizes operators declared in the list.
  lib-list-deps-direct-handles-record-dep-links =
    let
      handle = ns: inst: {
        _meta = {
          namespaceName = ns;
          instanceName = inst;
        };
      };
      cluster = mkCluster [
        baseInstances
        {
          scorecard = {
            enable = true;
            rules.architecture = import ../../rules/architecture.nix { inherit lib; };
          };
          instances.infra.op1.package = target {
            name = "op1";
            metaExtra.annotationDomains = [ "op1.example.io" ];
          };
          instances.infra.op2.package = target {
            name = "op2";
            metaExtra.annotationDomains = [ "op2.example.io" ];
          };
          instances.appns.writer = {
            package = {
              meta.version = "test";
              build =
                {
                  self,
                  scope,
                  operators ? [ ],
                  ...
                }:
                {
                  cm = scope.mkResource {
                    apiVersion = "v1";
                    kind = "ConfigMap";
                    name = "writer-${toString (builtins.length operators)}";
                    annotations = {
                      "op1.example.io/enabled" = "true";
                      "op2.example.io/enabled" = "true";
                    };
                  };
                  root = self.cm;
                };
            };
            deps.operators = [
              (handle "infra" "op1")
              (handle "infra" "op2")
            ];
          };
        }
      ];
      findings = builtins.filter (f: lib.hasSuffix "annotationDomainOwnership" (f.rule or "")) (
        (cluster.scorecardReport or { findings = [ ]; }).findings
      );
      depIds = map (l: l.id) cluster.instances.appns.writer._depLinks;
    in
    (findings == [ ] && builtins.elem "infra/op1" depIds && builtins.elem "infra/op2" depIds)
    || throw "direct handle list dep links: findings=${builtins.toJSON findings} depIds=${builtins.toJSON depIds}";
}
