# Encode and read typed facts in Nix string context.
#
# Resource identity paths record dependencies used for deployment ordering.
# Fact tokens describe endpoint use for edge analysis, network policies, and
# DNS dependencies. core/resource.nix removes fact tokens before sealing the
# manifest so they do not become references in its store path.
#
# A token is a store file named kix-fact-<kind> containing { kind; payload; }
# as JSON. Payload string context is discarded before writing, so the token
# depends on the payload values without referencing producer identity paths.
# Changing a producer's image therefore leaves its endpoint token unchanged
# when the endpoint's name, namespace, selector, and ports stay the same.
# Deployment ordering uses the separately retained resource identity context.
#
# core/resource.nix attaches endpoint facts to address outputs. Conducting
# resources forward absorbed facts through their outputs: a ConfigMap can
# pass an endpoint fact to a workload that mounts it. Terminating resources
# consume those facts without forwarding them; their endpoint use determines
# network policy and DNS dependencies. terminatorKinds supplies the defaults,
# which a resource's factBehavior declaration can override.

{ lib }:

let
  kixAnnotations = import ./annotations.nix;
  kixKeys = kixAnnotations.keys;
  markers = import ./markers.nix { inherit lib; };
in

rec {
  # Supported fact kinds and required payload fields, checked by mkFact.
  kinds = {
    endpoint = {
      # Pods reached through an endpoint, used to derive network policies.
      requiredFields = [
        "name"
        "namespace"
        "selector"
        "ports"
      ];
    };
    refonly = {
      # Records a reference without a connection to this endpoint. Suppresses
      # the observed-vs-declared lint and conservative DNS dependency for it.
      requiredFields = [
        "name"
        "namespace"
      ];
    };
  };

  factPrefix = "kix-fact-";

  # These workload kinds consume endpoint facts; other kinds forward them.
  terminatorKinds = [
    "Deployment"
    "StatefulSet"
    "DaemonSet"
    "Job"
  ];

  conducts = kind: !(builtins.elem kind terminatorKinds);

  # Shape check for a factBehavior declaration ({ endpoint; podSelector? }),
  # shared by the CRD-declaration site (mkCRD/mkCRDRef args) and the
  # cluster.factBehavior override. `source` names the declarer in errors.
  validateBehavior =
    source: kindKey: entry:
    let
      endpoint =
        entry.endpoint
          or (throw "kix: factBehavior for '${kindKey}' (${source}) must set `endpoint` to \"terminate\" or \"conduct\"");
      _enum =
        if
          !(builtins.elem endpoint [
            "terminate"
            "conduct"
          ])
        then
          throw "kix: factBehavior for '${kindKey}' (${source}): endpoint must be \"terminate\" or \"conduct\", got '${toString endpoint}'"
        else
          null;
      _sel =
        if
          endpoint == "terminate"
          && !(
            builtins.isFunction (entry.podSelector or null) || builtins.isAttrs (entry.podSelector or null)
          )
        then
          throw (
            "kix: factBehavior for '${kindKey}' (${source}) declares endpoint = \"terminate\" "
            + "but has no valid `podSelector`. Kix needs the labels of the pods created by the controller "
            + "to generate their network policies. Set podSelector to a function `cr: { ... }` of the "
            + "manifest, or to an attribute set of pod labels."
          )
        else
          null;
    in
    builtins.seq _enum (builtins.seq _sel entry);

  # Custom API groups need factBehavior from their CRD declaration or a
  # cluster override keyed by "group/Kind". Groups without a dot, *.k8s.io,
  # and Kix's own group are exempt from this check.
  isForeignGroup =
    apiVersion:
    let
      group = if lib.hasInfix "/" apiVersion then builtins.head (lib.splitString "/" apiVersion) else "";
    in
    lib.hasInfix "." group && !(lib.hasSuffix ".k8s.io" group) && group != kixAnnotations.group;

  isFactPath = p: lib.hasPrefix factPrefix (markers.pathName p);

  # Return string context { <token-path> = { path = true; }; } for
  # builtins.appendContext. Reject unknown kinds and missing required fields.
  # Identical kind and payload values produce the same token path.
  mkFact =
    kind: payload:
    let
      spec =
        kinds.${kind}
          or (throw "mkFact: unknown fact kind '${kind}'. Supported kinds: ${builtins.concatStringsSep ", " (builtins.attrNames kinds)}");
      missing = builtins.filter (f: !(payload ? ${f})) spec.requiredFields;
      checked =
        if missing != [ ] then
          throw "mkFact ${kind}: missing payload field(s): ${builtins.concatStringsSep ", " missing}"
        else
          payload;
      # Remove context recursively so payload values derived from resources
      # do not add store references to the fact token.
      plain = discardCtxDeep checked;
      token = builtins.toFile "${factPrefix}${kind}" (
        builtins.toJSON {
          inherit kind;
          payload = plain;
        }
      );
    in
    builtins.getContext "${token}";

  discardCtxDeep =
    value:
    if builtins.isString value then
      builtins.unsafeDiscardStringContext value
    else if builtins.isAttrs value then
      lib.mapAttrs (_: discardCtxDeep) value
    else if builtins.isList value then
      map discardCtxDeep value
    else
      value;

  # Separate fact tokens from resource identity and other string context.
  partitionCtx = ctx: {
    facts = lib.filterAttrs (p: _: isFactPath p) ctx;
    rest = lib.filterAttrs (p: _: !isFactPath p) ctx;
  };

  # Rebuild a string with facts removed (pre-seal strip: fact tokens must
  # never become store references of the sealed manifest).
  stripFacts =
    s:
    builtins.appendContext (builtins.unsafeDiscardStringContext s) (partitionCtx (
      builtins.getContext s
    )).rest;

  readFact = p: builtins.fromJSON (builtins.readFile p);

  # Read facts carried by a string. Context keys deduplicate token paths;
  # factsOfKind additionally filters the decoded records by kind.
  factsFromString =
    s: map readFact (builtins.filter isFactPath (builtins.attrNames (builtins.getContext s)));

  factsOfKind = kind: s: builtins.filter (f: f.kind == kind) (factsFromString s);

  # For endpoint values used as labels or display text rather than addresses.
  # Remove facts while preserving resource identity context for ordering.
  # Replace each endpoint fact with a refonly record, suppressing that endpoint's
  # observed-vs-declared lint and conservative DNS dependency at the consumer.
  refOnly =
    s:
    let
      ctx = builtins.getContext s;
      parts = partitionCtx ctx;
      acks = builtins.foldl' (
        acc: p:
        let
          f = readFact p;
        in
        if f.kind == "endpoint" then
          acc
          // mkFact "refonly" {
            inherit (f.payload) name namespace;
          }
        else
          acc
      ) { } (builtins.attrNames parts.facts);
    in
    builtins.appendContext (builtins.unsafeDiscardStringContext s) (parts.rest // acks);

  # Attach fact context to a value that lacks it, such as a bare service name:
  # connect svc.factTokens.endpoint svc.out.name
  connect = factCtx: s: builtins.appendContext s factCtx;

  # Mark an output as descriptive data, such as a replica count or label.
  # mkResource applies refOnly when sealing it, retaining ordering context
  # and replacing endpoint facts with refonly records.
  structural = value: {
    _type = "kix-structural-output";
    inherit value;
  };
  isStructural = v: builtins.isAttrs v && (v._type or null) == "kix-structural-output";
}
