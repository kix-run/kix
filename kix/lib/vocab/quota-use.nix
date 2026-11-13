# Compute the minimum resource usage of a namespace's workloads and compare it
# against the namespace's ResourceQuotas. `buildCluster` fails the build when
# the minimum usage exceeds a quota, because Kubernetes admission will reject
# some of those objects at deploy time.
#
# Usage is an attrset keyed by the same names a ResourceQuota's `spec.hard`
# uses: `pods`, `requests.cpu`, `limits.memory`, `requests.storage`,
# `persistentvolumeclaims`, `services`, `count/<resource>.<group>`, and so on.
# Values are integers: millicores for CPU, and base units (bytes or counts)
# for everything else. A key that is missing counts as zero.
#
# Built-in workload kinds with a known minimum pod count are included
# automatically, counted by their pods and containers only. Custom resources
# are included when their CRD declares `usesAtLeast` (via `scope.mkCRD` or
# `scope.mkCRDRef`): a function from the custom resource to its usage, keyed
# as above. Values may be integers or quantity strings (`"20Gi"`, `"500m"`).
# Packages build that usage with `kix.usage` (`ofPod`, `times`, `add`).
#
# A refusal also lists what it could not count, so the reader knows the real
# usage may be higher: DaemonSets and CronJobs by name, and custom resources
# without `usesAtLeast` grouped by kind. A kind whose `usesAtLeast` returns
# `{ }` runs nothing and is left out of the message.
{ lib }:

let
  inherit (import ../core/error.nix { inherit lib; }) fail;
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

  # Multiply every value of a usage by `n`.
  times = n: use: lib.mapAttrs (_: v: v * n) (normalize use);

  ofPods = n: spec: times n (ofPodSpec spec);

  # Turn a declared usage into integers: parse quantity strings, and drop
  # keys whose value is null (unknown, so counted as zero).
  normalize =
    use:
    lib.mapAttrs (
      key: v:
      if builtins.isInt v then
        v
      else
        let
          parsed = parse key v;
        in
        if parsed == null then
          fail "kix: usage ${key} = ${builtins.toJSON v} is not a Kubernetes quantity"
        else
          parsed
    ) (lib.filterAttrs (_: v: v != null) use);

  # Keys that count objects rather than measure a resource. Their values
  # print as plain numbers.
  isCount =
    key:
    builtins.elem key [
      "pods"
      "services"
      "secrets"
      "configmaps"
      "persistentvolumeclaims"
      "replicationcontrollers"
      "resourcequotas"
    ]
    || lib.hasPrefix "services." key
    || lib.hasPrefix "count/" key
    || lib.hasSuffix "/persistentvolumeclaims" key;
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

  # Helpers for a CRD's `usesAtLeast`, exposed to packages as `kix.usage`.
  helpers = {
    # One pod's usage from its regular containers (a list of containers, or
    # a pod spec with `containers`). Applies Kubernetes' rule that a
    # container's missing request counts as its limit, and sets `pods = 1`.
    ofPod =
      containersOrSpec:
      ofPodSpec (
        if builtins.isList containersOrSpec then { containers = containersOrSpec; } else containersOrSpec
      );
    # Multiply a usage by a number of pods or copies.
    inherit times;
    # Add a list of usages together.
    add = uses: sum (map normalize uses);
  };

  # Return the minimum quota usage of `manifest`, or null when the kind cannot
  # be counted statically (DaemonSet, CronJob, or a custom resource without
  # `usesAtLeast`). `minReplicas` is the `minReplicas` of a targeting
  # HorizontalPodAutoscaler, if any. `declared` is the CRD's `usesAtLeast`
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
      normalize (declared manifest)
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

  # Return the usage key a quota key charges. Kubernetes accepts `cpu`,
  # `memory`, and `ephemeral-storage` as shorthand for `requests.<resource>`.
  chargedKey =
    key:
    if
      builtins.elem key [
        "cpu"
        "memory"
        "ephemeral-storage"
      ]
    then
      "requests.${key}"
    else
      key;

  # Match a quota key and hard limit against `use`, returning `{ used; limit; }`
  # or null when the limit does not parse. A key no workload reports, such as
  # `services` when no custom resource declares any, is used 0, so it never
  # refuses a build.
  compare =
    use: key: hard:
    let
      limit = parse key hard;
    in
    if limit == null then
      null
    else
      {
        used = use.${chargedKey key} or 0;
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
    else if isCount key then
      toString n
    else if exact (1024 * 1024 * 1024) then
      "${toString (n / (1024 * 1024 * 1024))}Gi"
    else if exact (1024 * 1024) then
      "${toString (n / (1024 * 1024))}Mi"
    else if exact 1024 then
      "${toString (n / 1024)}Ki"
    else
      toString n;

  # Describe an amount of `key` with its unit, such as "2 pods" or
  # "30Gi requests.storage".
  amount =
    key: n:
    if key == "pods" then
      "${toString n} ${if n == 1 then "pod" else "pods"}"
    else
      "${format key n} ${key}";

  # Name the objects Kubernetes rejects once `key` is at its limit.
  rejectedBy =
    key:
    if lib.hasPrefix "services" key then
      "Services"
    else if key == "persistentvolumeclaims" || lib.hasSuffix ".storage" key then
      "PersistentVolumeClaims"
    else if
      key == "pods" || isCpu key || lib.hasSuffix "memory" key || lib.hasSuffix "ephemeral-storage" key
    then
      "pods"
    else
      "objects";

  # Explain why `useOf` returns null for a built-in kind.
  uncountedReason =
    kind:
    if kind == "DaemonSet" then
      "1 pod per matching node (Kix does not know how many nodes the cluster has)"
    else if kind == "CronJob" then
      "pods start on a schedule (Kix does not know how many run at once)"
    else
      "usage is only known at deploy time";

  # Return one error message per quota key in `quotas` (`{ name; hard; }`)
  # that the minimum usage of `resources` and `customResources`
  # (`{ manifest; usesAtLeast; }`) exceeds. Each message lists the objects
  # that make up the total and the objects Kix could not count.
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
          kind = plain m.kind;
          custom = false;
          use = useOf {
            manifest = m;
            minReplicas = minReplicas.${nameOf m} or null;
          };
        }) (builtins.filter (m: builtins.elem (m.kind or "") podKinds) resources)
        ++ map (c: {
          name = nameOf c.manifest;
          kind = plain c.manifest.kind;
          custom = true;
          use = useOf {
            inherit (c) manifest;
            declared = c.usesAtLeast;
          };
        }) customResources;

      # A declared usage of `{ }` says the kind runs nothing, so its objects
      # appear in neither list.
      counted = builtins.filter (f: f.use != null && f.use != { }) found;
      notCounted = builtins.filter (f: f.use == null) found;
      notCountedBuiltin = builtins.filter (f: !f.custom) notCounted;
      notCountedCustom = builtins.filter (f: f.custom) notCounted;
      total = sum (map (f: f.use) counted);

      # Group uncounted custom resources by kind, largest group first.
      customGroups = lib.sort (a: b: a.count > b.count || (a.count == b.count && a.kind < b.kind)) (
        lib.mapAttrsToList (kind: fs: {
          inherit kind;
          count = builtins.length fs;
        }) (builtins.groupBy (f: f.kind) notCountedCustom)
      );

      customGroupNames = builtins.concatStringsSep ", " (
        map (g: "${toString g.count} ${g.kind}") customGroups
      );

      # The built-in kinds Kix cannot count only use what their pods use, so
      # they are left out of the list for a key that counts something else
      # (storage, services, object counts).
      notCountedLinesFor =
        key:
        lib.optionals (rejectedBy key == "pods") (
          map (f: "    ${f.name}: ${uncountedReason f.kind}") notCountedBuiltin
        )
        ++ lib.optional (customGroups != [ ]) (
          if rejectedBy key == "pods" then
            "    ${customGroupNames}: pod usage is not declared by their packages (most custom resources create no pods, but Kix cannot verify this)"
          else
            "    ${customGroupNames}: usage is not declared by their packages (Kix cannot verify what they use)"
        );

      messageFor =
        quota: key: hard: used:
        let
          charged = chargedKey key;
          contributing = builtins.filter (f: (f.use.${charged} or 0) > 0) counted;
          notCountedLines = notCountedLinesFor key;
          fix =
            if key == "pods" then
              "run fewer pods"
            else if isCount key then
              "create fewer ${key}"
            else
              "use less ${key}";
        in
        builtins.concatStringsSep "\n" (
          [
            "namespace \"${namespace}\" exceeds ResourceQuota \"${quota.name}\" for ${key} (uses at least ${format key used}, limit is ${plain hard})"
            "  Kubernetes will reject ${rejectedBy key} over this limit at deploy time."
            ""
            "  Counted (${amount key used}):"
          ]
          ++ map (f: "    ${f.name}: ${amount key f.use.${charged}}") contributing
          ++ lib.optionals (notCountedLines != [ ]) (
            [
              ""
              "  Not counted (actual usage may be higher):"
            ]
            ++ notCountedLines
          )
          ++ [
            ""
            "  To fix this, raise the ${key} limit in \"${quota.name}\" or ${fix} in namespace \"${namespace}\"."
          ]
        );

      overOf =
        quota:
        builtins.filter (x: x != null) (
          lib.mapAttrsToList (
            key: hard:
            let
              c = compare total key hard;
            in
            if c != null && c.used > c.limit then messageFor quota key hard c.used else null
          ) quota.hard
        );
    in
    lib.concatMap overOf quotas;
}
