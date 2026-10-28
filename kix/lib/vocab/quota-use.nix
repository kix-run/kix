# Compute the minimum resource usage of a namespace's workloads and compare it
# against the namespace's ResourceQuotas. `buildCluster` fails the build when
# the minimum usage exceeds a quota, because Kubernetes admission will reject
# some of those pods at deploy time.
#
# Usage is represented as an attrset keyed by ResourceQuota metric names:
# `pods`, plus `requests.<resource>` and `limits.<resource>` for each container
# resource. Values are integers: millicores for CPU, and base units (bytes or
# counts) for everything else.
#
# Built-in workload kinds with a known minimum pod count are included
# automatically. Custom resources are included when their CRD declares
# `runsAtLeast` (via `scope.mkCRD` or `scope.mkCRDRef`), which returns a list
# of pod groups `[ { pods = <count>; resources = <container resources>; } ]`.
{ lib }:

let
  quantity = import ./quantity.nix { inherit lib; };

  listOr = v: if v == null then [ ] else v;

  plain = v: builtins.unsafeDiscardStringContext (toString v);

  isCpu = name: name == "cpu" || lib.hasSuffix ".cpu" name;

  # Parse a Kubernetes quantity into an integer, or return null if unparseable.
  parse =
    name: q:
    let
      parsed = builtins.tryEval (quantity.parse (if isCpu name then "cpu" else "memory") q);
    in
    if parsed.success then parsed.value else null;

  # Parse an integer field, returning `default` when it is null or non-numeric
  # (for example, when a Helm chart renders `replicas: null`).
  intOr =
    default: v:
    let
      parsed = builtins.tryEval (lib.toIntBase10 (plain v));
    in
    if builtins.isInt v then
      v
    else if v != null && parsed.success then
      parsed.value
    else
      default;

  # Convert a container's `resources` attrset into quota usage metrics.
  # Kubernetes defaults an omitted request to the resource's limit.
  ofResources =
    resources:
    let
      limits = resources.limits or { };
      requests = limits // (resources.requests or { });
      prefixed =
        prefix: values:
        lib.filterAttrs (_: v: v != null) (
          lib.mapAttrs' (name: v: lib.nameValuePair "${prefix}.${name}" (parse name v)) values
        );
    in
    prefixed "requests" requests // prefixed "limits" limits;

  sum = lib.foldl' (
    acc: u:
    lib.zipAttrsWith (_: builtins.foldl' builtins.add 0) [
      acc
      u
    ]
  ) { };

  # Sum the resource usage of a single pod's regular containers. Init
  # containers are omitted so this lower bound never exceeds what Kubernetes
  # charges (the greater of the regular container sum and the largest init
  # container).
  ofPodSpec =
    spec:
    sum (map (c: ofResources (c.resources or { })) (listOr (spec.containers or [ ]))) // { pods = 1; };

  ofPods = n: spec: lib.mapAttrs (_: v: v * n) (ofPodSpec spec);
  # Built-in kinds that create pods. DaemonSets and CronJobs are listed so
  # `refusals` can report them as uncounted; their minimum pod count is not
  # known statically.
  podKinds = [
    "Pod"
    "Deployment"
    "ReplicaSet"
    "StatefulSet"
    "ReplicationController"
    "Job"
    "CronJob"
    "DaemonSet"
  ];
in
rec {
  inherit ofPodSpec sum podKinds;

  # Return the minimum quota usage of `manifest`, or null when the kind cannot
  # be counted statically (DaemonSet, CronJob, or a custom resource without
  # `runsAtLeast`). `minReplicas` is the `minReplicas` of a targeting
  # HorizontalPodAutoscaler, if any. `declared` is the CRD's `runsAtLeast`
  # function, if any.
  useOf =
    {
      manifest,
      minReplicas ? null,
      declared ? null,
    }:
    let
      kind = plain (manifest.kind or "");
      spec = manifest.spec or { };
      template = (spec.template or { }).spec or { };
      parallelism = intOr 1 (spec.parallelism or null);
    in
    if declared != null then
      sum (
        map (g: ofPods (intOr 1 g.pods) { containers = [ { resources = g.resources or { }; } ]; }) (
          declared manifest
        )
      )
    else if kind == "Pod" then
      ofPodSpec spec
    else if
      builtins.elem kind [
        "Deployment"
        "ReplicaSet"
        "StatefulSet"
        "ReplicationController"
      ]
    then
      ofPods (if minReplicas != null then minReplicas else intOr 1 (spec.replicas or null)) template
    else if kind == "Job" && (spec.suspend or false) == true then
      ofPods 0 template
    else if kind == "Job" then
      ofPods (lib.min parallelism (intOr parallelism (spec.completions or null))) template
    else
      null;

  # Match a quota key and hard limit against `use`, returning `{ used; limit; }`
  # or null when the key is not tracked (such as storage or object counts).
  # Kubernetes accepts `cpu`, `memory`, and `ephemeral-storage` as shorthand
  # for `requests.<resource>`.
  compare =
    use: key: hard:
    let
      charged =
        if key == "pods" then
          "pods"
        else if
          builtins.elem key [
            "cpu"
            "memory"
            "ephemeral-storage"
          ]
        then
          "requests.${key}"
        else if
          (lib.hasPrefix "requests." key || lib.hasPrefix "limits." key) && key != "requests.storage"
        then
          key
        else
          null;
      limit = parse key hard;
    in
    if charged == null || limit == null then
      null
    else
      {
        used = use.${charged} or 0;
        inherit limit;
      };

  # Format an integer usage value for `key` as a Kubernetes quantity string.
  format =
    key: n:
    let
      exact = unit: n >= unit && lib.mod n unit == 0;
    in
    if isCpu key then
      (if lib.mod n 1000 == 0 then toString (n / 1000) else "${toString n}m")
    else if key == "pods" then
      toString n
    else if exact (1024 * 1024 * 1024) then
      "${toString (n / (1024 * 1024 * 1024))}Gi"
    else if exact (1024 * 1024) then
      "${toString (n / (1024 * 1024))}Mi"
    else if exact 1024 then
      "${toString (n / 1024)}Ki"
    else
      toString n;

  # Return one error message per ResourceQuota in `quotas` (`{ name; hard; }`)
  # that the minimum usage of `resources` and `customResources`
  # (`{ manifest; runsAtLeast; }`) exceeds.
  refusals =
    {
      namespace,
      quotas,
      resources,
      customResources ? [ ],
    }:
    let
      nameOf = m: "${plain m.kind}/${plain m.metadata.name}";

      minReplicas = builtins.listToAttrs (
        map
          (
            m:
            lib.nameValuePair "${plain m.spec.scaleTargetRef.kind}/${plain m.spec.scaleTargetRef.name}" (
              intOr 1 (m.spec.minReplicas or null)
            )
          )
          (
            builtins.filter (
              m: (m.kind or "") == "HorizontalPodAutoscaler" && (m.spec.scaleTargetRef or { }) ? name
            ) resources
          )
      );

      found =
        map (m: {
          name = nameOf m;
          use = useOf {
            manifest = m;
            minReplicas = minReplicas.${nameOf m} or null;
          };
        }) (builtins.filter (m: builtins.elem (m.kind or "") podKinds) resources)
        ++ map (c: {
          name = nameOf c.manifest;
          use = useOf {
            inherit (c) manifest;
            declared = c.runsAtLeast;
          };
        }) customResources;

      counted = builtins.filter (f: f.use != null) found;
      notCounted = builtins.filter (f: f.use == null) found;
      total = sum (map (f: f.use) counted);

      overOf =
        quota:
        builtins.filter (x: x != null) (
          lib.mapAttrsToList (
            key: hard:
            let
              c = compare total key hard;
            in
            if c != null && c.used > c.limit then
              "${key}: at least ${format key c.used}, quota ${plain hard}"
            else
              null
          ) quota.hard
        );

      names = fs: builtins.concatStringsSep ", " (map (f: f.name) fs);
    in
    lib.concatMap (
      quota:
      let
        over = overOf quota;
      in
      lib.optional (over != [ ]) (
        "namespace ${namespace} needs more than ResourceQuota ${quota.name} allows (${builtins.concatStringsSep "; " over}), "
        + "so Kubernetes would refuse some of its pods. Counted: ${names counted}."
        + lib.optionalString (notCounted != [ ]) " Not counted: ${names notCounted}."
        + " Raise the quota or run less in the namespace."
      )
    ) quotas;
}
