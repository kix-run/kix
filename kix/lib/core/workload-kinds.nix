# The built-in Kubernetes kinds that create pods, and what Kix knows about
# each. Code that asks "is this a workload?" picks the list below that
# matches the question.
{ lib }:

let
  util = import ./util.nix { inherit lib; };

  template = [
    "spec"
    "template"
  ];

  # `group` is the API group. `template` is the path to the pod template, or
  # null when the object is a pod itself. `builder` is the scope builder a
  # package must use for the kind, or null when Kix has none. `serves` marks
  # a controller that keeps its pods running. `selector` marks a built kind
  # whose `spec.selector` claims its pods. `replicas` marks a kind that runs
  # `spec.replicas` pods. `spread` marks a kind whose replicas get topology
  # spread constraints.
  kinds = {
    Pod = {
      group = "";
      template = null;
    };
    ReplicationController = {
      group = "";
      inherit template;
      replicas = true;
    };
    ReplicaSet = {
      group = "apps";
      inherit template;
      replicas = true;
    };
    Deployment = {
      group = "apps";
      inherit template;
      builder = "scope.mkDeployment";
      serves = true;
      selector = true;
      replicas = true;
      spread = true;
    };
    StatefulSet = {
      group = "apps";
      inherit template;
      builder = "scope.mkStatefulSet";
      serves = true;
      selector = true;
      replicas = true;
      spread = true;
    };
    DaemonSet = {
      group = "apps";
      inherit template;
      builder = "scope.mkDaemonSet";
      serves = true;
      selector = true;
    };
    Job = {
      group = "batch";
      inherit template;
      builder = "scope.mkJob";
      selector = true;
    };
    CronJob = {
      group = "batch";
      template = [
        "spec"
        "jobTemplate"
        "spec"
        "template"
      ];
      builder = "scope.mkCronJob";
    };
  };

  kindsWhere = flag: builtins.attrNames (lib.filterAttrs (_: k: k.${flag} or false) kinds);
in
rec {
  inherit kinds;

  # Every built-in kind that creates pods.
  podKinds = builtins.attrNames kinds;

  # The kinds a package builds with a typed scope builder, never with
  # `scope.mkResource`. Their pods get the pod validators, network policy
  # edges, and DNS ordering, and they consume the endpoint facts in their
  # manifest.
  builtKinds = builtins.attrNames (lib.filterAttrs (_: k: k ? builder) kinds);

  # The builder a package must use for each kind in `builtKinds`.
  builderFor = lib.mapAttrs (_: k: k.builder) (lib.filterAttrs (_: k: k ? builder) kinds);

  # The controllers that keep their pods running: Deployment, StatefulSet,
  # and DaemonSet.
  servingKinds = kindsWhere "serves";

  # The built kinds whose `spec.selector` claims their pods.
  selectorKinds = kindsWhere "selector";

  # The kinds that run `spec.replicas` pods.
  replicaKinds = kindsWhere "replicas";

  # The kinds whose replicas get topology spread constraints.
  spreadKinds = kindsWhere "spread";

  # Return whether `m` is a manifest of a built-in pod kind, checking its API
  # group as well as its kind.
  isPodKind =
    m:
    let
      kind = m.kind or "";
    in
    kinds ? ${kind} && kinds.${kind}.group == util.groupOf (util.plain (m.apiVersion or ""));

  # Return the path to the pod template of a manifest of `kind`, or null when
  # the object is a pod itself. A kind outside the table keeps its pod
  # template at `spec.template`, as most custom workload kinds do.
  templatePathOf = kind: if kinds ? ${kind} then kinds.${kind}.template else template;
}
