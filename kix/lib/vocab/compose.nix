{ lib }:

let
  markers = import ../core/markers.nix { inherit lib; };

  kixAnnotations = import ../core/annotations.nix;
  kixKeys = kixAnnotations.keys;

  normalize = import ../core/normalize.nix { inherit lib; };

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

  resolveServicePort =
    caller: port: svc:
    if port != null then
      port
    else if svc ? out.port then
      builtins.fromJSON (builtins.unsafeDiscardStringContext svc.out.port)
    else
      throw "${caller}: service '${svc.name or "unknown"}' has no out.port — specify port explicitly";
in

rec {

  # Kix's own annotation keys, from core/annotations.nix. A package that
  # writes one of Kix's keys spells it `kix.keys.<name>` rather than the
  # literal, so a domain move is a one-line change in that file.
  keys = kixKeys;

  # Typed-fact escape hatches (core/facts.nix), re-exported for package
  # authors: `kix.facts.refOnly svc.out.fqdn` (name it, don't dial it),
  # `kix.facts.connect svc.factTokens.endpoint value` (dial by a value
  # that lacks the claim, e.g. a bare intra-namespace name).
  facts = {
    inherit (import ../core/facts.nix { inherit lib; }) refOnly connect structural;
  };

  # ------------------------------------------------------------------ images
  #
  # A container image reference has three parts, and only two of them can be
  # trusted. `repository` and `tag` record what was asked for. `digest`
  # records what will actually run, because a tag can be moved after it is
  # read and a digest cannot. `kix.image.ref` renders both, so the manifest
  # stays readable and the pull stays exact:
  #
  #     image = kix.image.ref config.serverImage;
  #     # docker.io/library/nginx:1.27@sha256:0d17b1...
  #
  # Where the values come from is the other half. A cluster that decides an
  # image reference by editing its definition at deploy time has no committed
  # answer to "what is running", and a clean checkout of that definition
  # renders something that was never meant to be deployed. So the values live
  # in a pin file next to the cluster, committed, written by `kix pin`:
  #
  #     # flake.nix
  #     kix.lib.mkFlake { inherit inputs; pins = ./pins.json; clusters = { ... }; }
  #
  #     # the cluster definition, which never names the path
  #     { kix, pins, ... }:
  #     ...
  #     config.serverImage = pins.get "atlasServer";
  #
  # A cluster that wants a pin file of its own reads one directly instead:
  #
  #     let pins = kix.pins ./other-pins.json; in ...
  #
  # `pins.get` throws when the key is missing and names the command that adds
  # it. That matters more than it looks. The state that produces the error is
  # exactly the state in which the reader needs a remedy they can run.
  #
  # What this does not do: check that the digest refers to anything. Nix
  # evaluation is pure, so a well-formed invented digest passes every check
  # here. `kix pin --check` is what asks the registry, and it is meant to run
  # on every change to a pin file. See `v2_discussions/archive/138_*`.
  image =
    let
      needField =
        image: field:
        let
          v = image.${field} or null;
        in
        if v == null || v == "" then
          throw "kix.image.ref: image reference has no '${field}'. An image needs at least { repository, tag }, and got: ${builtins.toJSON image}"
        else
          v;
    in
    {
      # Render `repository:tag` plus `@digest` when a digest is pinned.
      ref =
        image:
        "${needField image "repository"}:${needField image "tag"}"
        + lib.optionalString (image.digest or null != null) "@${image.digest}";

      # True when the reference names a digest, so a package or a rule can
      # tell a resolved reference from an unresolved one.
      #
      # Public API with no caller inside Kix, deliberately. It is the obvious
      # companion question to `ref` and a package may branch on it. It cannot
      # currently serve `security.noUnresolvedPlaceholder`, which inspects
      # rendered manifest strings while this takes an image attrset; closing
      # that gap needs a rule at the package-config level, which is the one
      # `rules/security.nix` describes and does not yet have. Not dead code.
      isPinned = image: (image.digest or null) != null;
    };

  port = name: containerPort: {
    inherit name containerPort;
    protocol = "TCP";
  };

  mkEnvVars =
    attrs:
    lib.mapAttrsToList (name: value: { inherit name value; }) (lib.filterAttrs (_: v: v != null) attrs);

  mkEnv = attrs: raw: (mkEnvVars attrs) ++ raw;

  parseGi =
    s:
    let
      str = builtins.unsafeDiscardStringContext (toString s);
      matchTi = builtins.match "([0-9]+)Ti" str;
      matchGi = builtins.match "([0-9]+)Gi" str;
      matchMi = builtins.match "([0-9]+)Mi" str;
    in
    if matchTi != null then
      (builtins.fromJSON (builtins.head matchTi)) * 1024
    else if matchGi != null then
      builtins.fromJSON (builtins.head matchGi)
    else if matchMi != null then
      (builtins.fromJSON (builtins.head matchMi)) / 1024
    else
      null;

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
        # name -> containerPort, for resolving named targetPorts below.
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
        # The Service is written with numeric targetPorts even when the
        # author named them. The netpol layer copies targetPort into every
        # consumer's egress rule, and cilium drops egress traffic on a
        # named port (verified on cilium 1.19: the same rule passes with
        # the number). The name still identifies the port on the workload;
        # here it is resolved once, where the workload is in hand.
        resolvedPorts = map (
          p:
          if (p ? targetPort) && builtins.isString p.targetPort then
            p // { targetPort = workloadPortNumbers.${p.targetPort}; }
          else
            p
        ) finalPorts;
        _portCheck =
          if ports != null && badTargets != [ ] then
            throw "service.fromWorkload '${name}': targetPort(s) [${
              builtins.concatStringsSep ", " (map (p: "\"${p.targetPort}\"") badTargets)
            }] do not match any named container port on the workload. "
            + "Declared container ports: [${builtins.concatStringsSep ", " workloadPortNames}]."
          else
            null;
      in
      builtins.seq _portCheck {
        apiVersion = "v1";
        kind = "Service";
        inherit name;
        spec = {
          inherit type;
          selector = workload.out.selector;
          ports = resolvedPorts;
        };
        outputs = autoOutputs // (cfg.outputs or { });
      }
      // removeAttrs passthrough [ "outputs" ];
  };

  ingress = {
    fromService =
      {
        name,
        host,
        path ? "/",
        pathType ? "Prefix",
        port ? null,
        className ? null,
        tls ? [ ],
        ...
      }@cfg:
      svc:
      let
        servicePort = resolveServicePort "ingress.fromService" port svc;
        passthrough = removeAttrs cfg [
          "name"
          "host"
          "path"
          "pathType"
          "port"
          "className"
          "tls"
        ];
      in
      {
        apiVersion = "networking.k8s.io/v1";
        kind = "Ingress";
        inherit name;
        spec = {
          rules = [
            {
              inherit host;
              http.paths = [
                {
                  inherit path pathType;
                  backend.service = {
                    name = svc.out.name;
                    port.number = servicePort;
                  };
                }
              ];
            }
          ];
        }
        // lib.optionalAttrs (className != null) { ingressClassName = className; }
        // lib.optionalAttrs (tls != [ ]) { inherit tls; };
      }
      // passthrough;
  };

  httpRoute = {
    fromService =
      {
        name,
        host,
        parentRef,
        path ? "/",
        pathType ? "PathPrefix",
        port ? null,
        # Gateway API HTTPRoute per-rule timeouts, e.g.
        # { request = "0s"; backendRequest = "0s"; } to disable (needed for
        # long-lived streaming backends). null → omit (Envoy's 15s default).
        timeouts ? null,
        ...
      }@cfg:
      svc:
      let
        servicePort = resolveServicePort "httpRoute.fromService" port svc;
        passthrough = removeAttrs cfg [
          "name"
          "host"
          "parentRef"
          "path"
          "pathType"
          "port"
          "timeouts"
        ];
      in
      {
        apiVersion = "gateway.networking.k8s.io/v1";
        kind = "HTTPRoute";
        inherit name;
        spec = {
          parentRefs = [
            (
              {
                name = parentRef.name;
              }
              // lib.optionalAttrs (parentRef ? namespace) { namespace = parentRef.namespace; }
            )
          ];
          hostnames = [ host ];
          rules = [
            (
              {
                matches = [
                  {
                    path = {
                      type = pathType;
                      value = path;
                    };
                  }
                ];
                backendRefs = [
                  {
                    name = svc.out.name;
                    port = servicePort;
                  }
                ];
              }
              // lib.optionalAttrs (timeouts != null) { inherit timeouts; }
            )
          ];
        };
      }
      // passthrough;
  };

  inherit (normalize) keep;

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
        # A ConfigMap volume is read-only whatever the mount says; this
        # writes it on the mount too, where a reader of the pod looks.
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
          throw "withMounts: multiple containers — use withMountsOn to target a specific one";
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

  withMounts = _injectMounts null;

  withMountsOn = containerName: _injectMounts containerName;

  untrackedRef = markers.mkUntrackedRef;

  options = {
    # A package's image, declared once so every package spells the digest
    # slot the same way and `kix pin` has somewhere to put a resolution.
    #
    #   options.image = kix.options.image {
    #     repository = "docker.io/library/nginx";
    #     tag = "1.27";
    #   };
    #
    # The cluster then overrides the whole attrset from its pin file:
    #
    #   config.image = pins.get "web";
    #
    # `digest` defaults to null rather than to a value, because a null that
    # says "not resolved yet" is worth more than a plausible-looking string
    # that was never checked against a registry.
    image =
      {
        repository,
        tag,
        digest ? null,
        pullPolicy ? "IfNotPresent",
      }:
      lib.mkOption {
        description = "Container image for this instance. Set it from a pin file (`kix.pins`) so the deployed reference is committed and resolved.";
        default = {
          inherit
            repository
            tag
            digest
            pullPolicy
            ;
        };
        type = lib.types.submodule {
          options = {
            repository = lib.mkOption {
              type = lib.types.str;
              description = "Image repository, registry host included.";
            };
            tag = lib.mkOption {
              type = lib.types.str;
              description = "Image tag. What was asked for.";
            };
            digest = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Resolved manifest digest, `sha256:` followed by 64 hex characters. What will actually run. Null means not resolved.";
            };
            pullPolicy = lib.mkOption {
              type = lib.types.str;
              default = "IfNotPresent";
              description = "imagePullPolicy for containers using this image.";
            };
            sourceRev = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Revision of the source the image was built from, when Kix built it. Null for upstream images.";
            };
            promotedBy = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Who resolved this pin, for the record. Null when unknown.";
            };
            resolvedAt = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "When this pin was resolved, RFC 3339. Null when unknown.";
            };
            note = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Whatever a person wanted to say about this pin. Kix never reads it and a promotion never discards it. Declared here for the same reason as the three fields above: a pin carries its own record-keeping, and the option accepts the whole pin rather than a subset of it.";
            };
          };
        };
      };

    ingress = {
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Ingress hostname. Null = auto-derive from cluster.domain.";
      };
      annotations = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra ingress annotations.";
      };
    };

    monitor = {
      enabled = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable metrics endpoint and monitoring resources (ServiceMonitor, PrometheusRules) when prometheus is available.";
      };
      interval = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Scrape interval (e.g. \"30s\"). Null = use Prometheus default.";
      };
    };

    # For packages with a kix.healthCheck probe; the helper reads both.
    healthCheck = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Run the package's post-deploy probe (kix.healthCheck) once its resources are ready. A failing probe fails the deploy before the activation switches.";
      };
      retryFor = lib.mkOption {
        type = lib.types.int;
        default = 90;
        description = "Seconds the probe keeps re-checking before it gives up, so a target still restarting from the rollout does not fail the deploy. The Job's deadline is sized from it.";
      };
    };
  };

  # A post-deploy health probe. The probe is a Job in the package's own
  # namespace whose script dials the things it checks through addresses
  # passed in as env vars from `out.*` values. Everything else is the
  # machinery every workload already has: the addresses carry the
  # dependency edges, so the Job runs after its targets are ready and the
  # netpol plugin opens the same egress a real consumer gets; the deploy
  # engine treats a Job as ready when it succeeds and as failed when
  # backoffLimit is exceeded, so a failing probe fails the deploy exactly
  # like a pod that never came up. The pod resolves names through cluster
  # DNS over the pod network, the path consumers actually use.
  #
  #   options.healthCheck = kix.options.healthCheck;   # enable, retryFor
  #   build = [
  #     ({ self, vmCluster, ... }: { ... })
  #     (kix.healthCheck {
  #       env = { self, deps, ... }: {
  #         VMSELECT_URL = deps.vmCluster.out.serviceUrl;
  #         AGENT_REPLICAS = self.vmAgent.out.replicas;
  #       };
  #       script = builtins.readFile ./health-check.py;
  #     })
  #   ];
  #
  # Two parts are rendered: `<partName>Script`, a ConfigMap holding the
  # script under a stable name, and `<partName>`, the Job that mounts it at
  # /probe and runs it. The Job always waits for the package root, so it
  # runs after the package it belongs to without anyone remembering to say
  # so; `requires` adds to that. It carries `kix.run/rerun = "on-change"`
  # (core/annotations.nix): the deploy engine deletes and recreates a Job
  # with that annotation whenever its identity hash differs from the one
  # the cluster last ran, or when the live Job failed. So under
  # `kix deploy` and `kix rollback` the probe runs again when it, or
  # anything upstream of what it checks, changes, and never otherwise. The
  # operator diffs against live objects instead of the activation record,
  # so once `ttlSecondsAfterFinished` has reaped a finished Job the
  # operator's next reconcile creates and runs it again.
  #
  # `script` is Python by default (`runtimes.python`, the official slim
  # image pinned by digest, standard library only). A non-zero exit fails
  # the probe. Keep the script in a file next to the package so it can be
  # read, linted and run by hand. The helper owns the probe's time budget:
  # it hands the script its retry window as `RETRY_FOR` and sizes the
  # Job's `activeDeadlineSeconds` to fit that window plus one worst-case
  # round of checks (`roundBudget`), because the Job deadline deletes the
  # pod and leaves no output behind. The script's part of the contract is
  # to give up once `RETRY_FOR` has passed and to keep one round of checks
  # under `roundBudget`. On failure the last lines the script printed
  # travel on the pod (terminationMessagePolicy FallbackToLogsOnError) and
  # the deploy prints them under the failure line.
  #
  # The probe pod carries its own labels, never the package's selector
  # labels: a Service selecting the package's pods must not route traffic
  # to the probe. It runs as nobody with a read-only root filesystem and no
  # service account token; the probe talks to Services, never to the API
  # server.
  healthCheck =
    let
      # The public renderer; see `kix.image` above. Kept as a local name so
      # the call sites below read the same as they always did.
      imageRef = image.ref;

      # Seconds one worst-case round of checks may take: every query timing
      # out, plus the pause before the next round. The deadline always
      # leaves this much room after the retry window. The shipped probes
      # make at most six requests a round at a 10 s timeout, then pause 10 s.
      roundBudget = 90;

      # Bump a digest with `crane digest <repository>:<tag>` (the multi-arch
      # index digest, which is what containerd resolves).
      runtimes = {
        python = {
          image = {
            repository = "docker.io/library/python";
            tag = "3.13-slim";
            digest = "sha256:9d2e5553305c7c7b0097999bb17187c69b921ccd6bc9d40e4bb5ebe652c00285";
          };
          file = "health-check.py";
          interpreter = [ "python3" ];
          # No bytecode cache next to the script: the root filesystem is
          # read-only and /probe is a ConfigMap.
          env.PYTHONDONTWRITEBYTECODE = "1";
        };
        shell = {
          image = {
            repository = "docker.io/curlimages/curl";
            tag = "8.14.1";
            digest = "sha256:9a1ed35addb45476afa911696297f8e115993df459278ed036182dd2cd22b67b";
          };
          file = "health-check.sh";
          interpreter = [
            "/bin/sh"
            "-eu"
          ];
          env = { };
        };
      };
    in
    {
      inherit runtimes roundBudget;
      __functor =
        _:
        # Every callback receives the same `{ self, config, deps }`: `self`
        # is the package's build result, `config` its evaluated options,
        # `deps` every dependency-injected package some entry of the
        # package declares, keyed by argument name.
        {
          script,
          # -> attrset of env var name to value. Values from `out.*` carry
          # context; that is what gives the Job its edges. Nulls are
          # dropped. `RETRY_FOR` is set by the helper.
          env ? (_: { }),
          # -> bool. False renders nothing. The default reads the option
          # set `kix.options.healthCheck` when the package declares it, and
          # is true when it does not.
          when ? ({ config, ... }: config.healthCheck.enable or true),
          # -> seconds the script keeps re-checking before it gives up.
          # Same default rule as `when`; 90 when the package has no option.
          retryFor ? ({ config, ... }: config.healthCheck.retryFor or 90),
          # -> resources the probe waits for beyond the package root, which
          # it always waits for.
          requires ? (_: [ ]),
          partName ? "healthCheck",
          # { image = { repository; tag; digest; }; file; interpreter; env; }.
          # One of `kix.healthCheck.runtimes`, or a package's own.
          runtime ? runtimes.python,
          # Job deadline. Null sizes it from the retry window; a value must
          # leave `roundBudget` after the window, or the build fails.
          activeDeadlineSeconds ? null,
          # Seconds a finished Job stays before Kubernetes removes it.
          ttlSecondsAfterFinished ? 3600,
        }:
        {
          self,
          config,
          scope,
          deps,
          ...
        }:
        let
          name = scope.instanceName;
          scriptPart = "${partName}Script";
          ctx = {
            inherit self config deps;
          };
          retry = retryFor ctx;
          deadline = if activeDeadlineSeconds == null then retry + roundBudget else activeDeadlineSeconds;
          userEnv = env ctx;
          # The package root as a resource: a bare part, or the wrapper
          # form `{ resource; out; }`.
          rootRes =
            let
              r = self.root;
            in
            r.resource or r;
          # An env value computed from the root already carries the edge;
          # listing it again would draw the redundant-requires warning.
          dialsRoot = builtins.hasAttr (builtins.unsafeDiscardStringContext rootRes.outPath) (
            builtins.getContext (builtins.toJSON userEnv)
          );
        in
        if !(when ctx) then
          { }
        else if deadline < retry + roundBudget then
          throw "kix.healthCheck (${name}): activeDeadlineSeconds ${toString deadline} leaves no room for a round of checks after the ${toString retry}s retry window; it must be at least ${toString (retry + roundBudget)}"
        else
          {
            ${scriptPart} = scope.mkResource {
              apiVersion = "v1";
              kind = "ConfigMap";
              name = "${name}-health-script";
              data.${runtime.file} = script;
            };

            ${partName} =
              {
                name = "${name}-health";
                requires = requires ctx ++ lib.optional (!dialsRoot) rootRes;
                annotations.${kixKeys.rerun} = kixAnnotations.values.rerunOnChange;
                spec = {
                  backoffLimit = 0;
                  activeDeadlineSeconds = deadline;
                  inherit ttlSecondsAfterFinished;
                  template = {
                    metadata.labels = {
                      "app.kubernetes.io/name" = "${name}-health";
                      "app.kubernetes.io/component" = "health-check";
                    };
                    spec = {
                      restartPolicy = "Never";
                      automountServiceAccountToken = false;
                      securityContext = {
                        runAsNonRoot = true;
                        runAsUser = 65534;
                        runAsGroup = 65534;
                        seccompProfile.type = "RuntimeDefault";
                      };
                      containers = [
                        {
                          name = "probe";
                          image = imageRef runtime.image;
                          command = runtime.interpreter ++ [ "/probe/${runtime.file}" ];
                          env = mkEnvVars (
                            (runtime.env or { })
                            // {
                              RETRY_FOR = toString retry;
                            }
                            // userEnv
                          );
                          terminationMessagePolicy = "FallbackToLogsOnError";
                          securityContext = {
                            runAsNonRoot = true;
                            allowPrivilegeEscalation = false;
                            readOnlyRootFilesystem = true;
                            capabilities.drop = [ "ALL" ];
                          };
                          resources = {
                            requests = {
                              cpu = "50m";
                              memory = "64Mi";
                            };
                            limits.memory = "128Mi";
                          };
                        }
                      ];
                    };
                  };
                };
              }
              |> withMountsOn "probe" [
                (mount.configMap self.${scriptPart} {
                  mountPath = "/probe";
                  readOnly = true;
                })
              ]
              |> scope.mkJob;
          };
    };

  expose =
    {
      service ? null,
      paths ? null,
      partName ? "ingress",
      defaultAnnotations ? { },
      port ? null,
      tlsSecretName ? null,
      tlsSecret ? null,
      tlsSecretPart ? null,
      # Gateway API mode only: per-rule HTTPRoute timeouts, e.g.
      # { request = "0s"; } to disable the default 15s request timeout for
      # long-lived streaming backends. Ignored in Ingress (nginx) mode.
      timeouts ? null,
    }:
    {
      self,
      config,
      clusterConfig,
      scope,
      lib,
      gateway ? null,
      ingressNginx ? null,
      clusterIssuer ? null,
      ...
    }:
    let
      name = scope.instanceName;

      _modeCheck =
        if service == null && paths == null then
          throw "kix.expose (${name}): one of `service` or `paths` must be set."
        else if service != null && paths != null then
          throw "kix.expose (${name}): `service` and `paths` are mutually exclusive."
        else
          null;

      svc = if service != null then self.${service} else null;

      effectiveTlsSecret = if tlsSecretPart != null then self.${tlsSecretPart} else tlsSecret;

      _tlsSecretNsCheck =
        if effectiveTlsSecret != null then
          let
            secretNs =
              if (effectiveTlsSecret.namespace._type or "") == "k8s-cluster-scoped" then
                null
              else
                effectiveTlsSecret.namespace.name or null;
          in
          if secretNs != null && secretNs != scope.namespaceName then
            throw "kix.expose (${name}): tlsSecret '${effectiveTlsSecret.name or "?"}' is in namespace "
            + "\"${secretNs}\" but the Ingress is in namespace \"${scope.namespaceName}\". "
            + "Kubernetes ingress controllers only read TLS secrets from the Ingress's own namespace."
          else
            null
        else if tlsSecretName != null then
          if builtins.getContext tlsSecretName == { } then
            throw "kix.expose (${name}): tlsSecretName \"${tlsSecretName}\" is a raw string literal. "
            + "Use `tlsSecret = someSecretResource` (resource form — also enables cross-namespace validation), "
            + "`tlsSecretName = someSecret.out.name` (tracked string), "
            + "or `tlsSecretName = kix.untrackedRef \"...\"` to opt out explicitly."
          else
            null
        else
          null;

      tlsSecretNameEffective =
        if effectiveTlsSecret != null then
          effectiveTlsSecret.out.name
        else if tlsSecretName != null then
          tlsSecretName
        else
          "${name}-tls";

      clusterDomain = clusterConfig.cluster.domain or null;
      configHost = (config.ingress or { }).host or null;
      effectiveHost =
        if configHost != null then
          configHost
        else if clusterDomain != null then
          "${name}.${clusterDomain}"
        else
          null;

      hasGateway = gateway != null && gateway ? out.gatewayRef;

      hasIngress = ingressNginx != null;

      useGateway =
        hasGateway
        && (
          if hasIngress then
            throw "kix.expose (${name}): both 'gateway' and 'ingressNginx' are present. Wire exactly one via deps in the cluster definition."
          else
            true
        );
      useIngress = hasIngress && !hasGateway;

      hasExposure = (useGateway || useIngress) && effectiveHost != null;
      hasTls = hasExposure && useIngress && clusterIssuer != null;

      configAnnotations = (config.ingress or { }).annotations or { };

      multiPathRules =
        let
          buildPath =
            p:
            let
              backendSvc = self.${p.service};
              autoPort =
                if backendSvc ? out.port then
                  builtins.fromJSON (builtins.unsafeDiscardStringContext backendSvc.out.port)
                else
                  throw "kix.expose (${name}): paths entry for service '${p.service}' has no out.port — specify `port` explicitly.";
              svcPort = p.port or autoPort;
            in
            {
              inherit (p) path;
              pathType = p.pathType or "Prefix";
              backend.service = {
                name = backendSvc.out.name;
                port.number = svcPort;
              };
            };
        in
        [
          {
            host = effectiveHost;
            http.paths = map buildPath paths;
          }
        ];
    in
    builtins.seq _modeCheck {
      ${partName} =
        if hasExposure && useGateway then
          if paths != null then
            throw "kix.expose (${name}): `paths` (multi-backend) is not yet supported in Gateway API mode."
          else
            svc
            |> httpRoute.fromService (
              {
                inherit name;
                host = effectiveHost;
                parentRef = gateway.out.gatewayRef;
              }
              // lib.optionalAttrs (port != null) { inherit port; }
              // lib.optionalAttrs (timeouts != null) { inherit timeouts; }
            )
            |> scope.mkResource

        else if hasExposure && useIngress then
          builtins.seq _tlsSecretNsCheck (
            (
              if paths != null then
                {
                  apiVersion = "networking.k8s.io/v1";
                  kind = "Ingress";
                  inherit name;
                  annotations = defaultAnnotations // configAnnotations;
                  spec = {
                    ingressClassName = ingressNginx.out.ingressClassName;
                    rules = multiPathRules;
                  }
                  // lib.optionalAttrs hasTls {
                    tls = [
                      {
                        hosts = [ effectiveHost ];
                        secretName = tlsSecretNameEffective;
                      }
                    ];
                  };
                }
              else
                svc
                |> ingress.fromService (
                  {
                    inherit name;
                    host = effectiveHost;
                    className = ingressNginx.out.ingressClassName;
                    tls = lib.optional hasTls {
                      hosts = [ effectiveHost ];
                      secretName = tlsSecretNameEffective;
                    };
                    annotations = defaultAnnotations // configAnnotations;
                  }
                  // lib.optionalAttrs (port != null) { inherit port; }
                )
            )
            |> (if hasTls then clusterIssuer.out.withCert else lib.id)
            |> scope.mkResource
          )

        else
          null;
    };

  # `name`, `monitorPart` and `rulesPart` let a package with several
  # metrics Services (harbor: core, registry, jobservice, exporter) call
  # this once per Service without the parts or the resource names
  # colliding. The defaults are the single-Service case.
  monitor =
    {
      service,
      port ? "metrics",
      path ? "/metrics",
      alerts ? { },
      extraEndpoints ? [ ],
      extraLabels ? { },
      name ? null,
      monitorPart ? "serviceMonitor",
      rulesPart ? "prometheusRules",
    }:
    {
      self,
      config,
      scope,
      lib,
      prometheus ? null,
      ...
    }:
    let
      monitorName = if name != null then name else scope.instanceName;
      svc = self.${service};

      metricsConfig = config.metrics or { };
      metricsEnabled = (metricsConfig.enabled or true) && prometheus != null;
      scrapeInterval = (metricsConfig.interval or null);

      primaryEndpoint = {
        port = if builtins.isInt port then null else port;
        targetPort = if builtins.isInt port then port else null;
        scheme = "http";
        inherit path;
      }
      // lib.optionalAttrs (scrapeInterval != null) {
        interval = scrapeInterval;
      };
      endpoints = [ (lib.filterAttrs (_: v: v != null) primaryEndpoint) ] ++ extraEndpoints;

      alertRules = lib.mapAttrsToList (
        alertName: alertDef:
        {
          alert = alertName;
          expr = alertDef.expr;
          labels = {
            severity = alertDef.severity or "warning";
          }
          // (alertDef.labels or { });
          annotations =
            { }
            // lib.optionalAttrs (alertDef ? description) {
              description = alertDef.description;
            }
            // lib.optionalAttrs (alertDef ? summary) {
              summary = alertDef.summary;
            }
            // lib.optionalAttrs (alertDef ? runbook_url) {
              runbook_url = alertDef.runbook_url;
            }
            // (alertDef.annotations or { });
        }
        // lib.optionalAttrs (alertDef ? "for") {
          "for" = alertDef."for";
        }
      ) alerts;
      hasAlerts = alerts != { };
    in
    {
      ${monitorPart} =
        if metricsEnabled then
          prometheus.out.mkServiceMonitor scope {
            name = monitorName;
            labels = extraLabels;
            spec = {
              namespaceSelector.matchNames = [ scope.namespaceName ];
              selector.matchLabels = svc.out.selector;
              inherit endpoints;
            };
          }
        else
          null;

      ${rulesPart} =
        if metricsEnabled && hasAlerts then
          prometheus.out.mkPrometheusRule scope {
            name = "${monitorName}-alerts";
            labels = extraLabels;
            spec = {
              groups = [
                {
                  name = "${monitorName}-alerts";
                  rules = alertRules;
                }
              ];
            };
          }
        else
          null;
    };

}
