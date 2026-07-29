# Typed facts — the semantic channel beside the derivation record.
#
# String context carries two distinct things through evaluation:
#
#   identity paths   the derivation record: "this value was computed from
#                    resource X". Maximal, exact, never filtered. Drives
#                    kix.dev/depends-on and the deploy DAG.
#   fact tokens      typed claims riding the same channel: "using this value
#                    means dialing an L4 endpoint {selector, ports, ns}".
#                    Read back by interpreters (edge analysis, netpol);
#                    stripped before sealing so they never enter the store DAG.
#
# A fact token is a content-addressed store path whose NAME encodes the kind
# (`kix-fact-<kind>`) and whose CONTENT is the full payload as JSON — the
# token is self-describing, so interpreters need `readFile`, not a registry.
# That kills the two failure modes registries had: cross-instance
# collectibility holes and fixpoint hazards at interceptor call sites.
#
# Facts are DEPENDENCY-FREE ON PURPOSE: the payload never references the
# producer's identity path. A producer's seal churns on every content change
# (image bump), but its endpoint fact only changes when the *semantics*
# change (selector/ports/ns) — so tokens are write-once-read-many across
# evals, and the fact is the claim, not the claimant. Ordering never needs
# the fact→producer link: the identity path always co-travels in the same
# context (direct references), and store-DAG transitivity covers indirected
# ones.
#
# Seal semantics per resource kind (core/resource.nix applies this):
#   emit       producers mint facts onto address-shaped out fields
#   conduct    non-workload resources re-emit absorbed facts on their own
#              out.* — a ConfigMap carrying postgres's fqdn hands the
#              endpoint fact to whoever mounts it (indirection is the
#              default case, not a special one)
#   terminate  workloads absorb facts and do not re-emit: their pods are
#              the ones dialing. Termination is what interpreters project
#              into egress holes / DNS waits.

{ lib }:

let
  markers = import ./markers.nix { inherit lib; };
in

rec {
  # ---- vocabulary ---------------------------------------------------------
  # Closed set, validated at mint. One kind today; api-surface (webhook
  # ingress) and podSet (operator operands) are the known next entries.
  kinds = {
    endpoint = {
      # "dialing me reaches pods selected by `selector` in `namespace` on
      # `ports`" — everything netpol/DNS need, nothing they don't.
      requiredFields = [
        "name"
        "namespace"
        "selector"
        "ports"
      ];
    };
    refonly = {
      # acknowledgment minted by `refOnly`: "this value names endpoint
      # ns/name deliberately without dialing it" — suppresses the
      # observed-vs-declared lint and the conservative DNS dep for exactly
      # that endpoint.
      requiredFields = [
        "name"
        "namespace"
      ];
    };
  };

  factPrefix = "kix-fact-";

  # Terminators absorb facts without re-emitting them: their pods are the
  # ones dialing. Everything else conducts (re-emits absorbed facts on its
  # own out.*) — a ConfigMap is a carrier, not a caller.
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
            + "but no `podSelector` — termination-by-CR opens holes for the OPERAND pods, "
            + "and only the CRD owner can name them (a function `cr: { ... }` over the raw "
            + "manifest, or a static label attrset)."
          )
        else
          null;
    in
    builtins.seq _enum (builtins.seq _sel entry);

  # A "foreign" apiVersion group is CRD territory: kix's core table can't
  # know whether the kind's controller dials absorbed endpoints — the
  # CRD-owning package declares it on the CRD (mkCRD/mkCRDRef factBehavior
  # arg), or the cluster overrides per "group/Kind". Builtin groups (no
  # dot, or *.k8s.io) and kix's own CRs are exempt.
  isForeignGroup =
    apiVersion:
    let
      group = if lib.hasInfix "/" apiVersion then builtins.head (lib.splitString "/" apiVersion) else "";
    in
    lib.hasInfix "." group && !(lib.hasSuffix ".k8s.io" group) && group != "kix.dev";

  isFactPath = p: lib.hasPrefix factPrefix (markers.pathName p);

  # ---- minting ------------------------------------------------------------

  # mkFact "endpoint" { name; namespace; selector; ports; }
  # → context attrset ({ <token-path> = { path = true; }; }) ready for
  #   builtins.appendContext. The token file is written once per distinct
  #   payload (content-addressed; the daemon write is idempotent).
  mkFact =
    kind: payload:
    let
      spec =
        kinds.${kind}
          or (throw "mkFact: unknown fact kind '${kind}' — known: ${builtins.concatStringsSep ", " (builtins.attrNames kinds)}");
      missing = builtins.filter (f: !(payload ? ${f})) spec.requiredFields;
      checked =
        if missing != [ ] then
          throw "mkFact ${kind}: missing payload field(s): ${builtins.concatStringsSep ", " missing}"
        else
          payload;
      # payload values may carry context (e.g. a selector derived from a
      # sealed sibling); toFile would then embed store references and tie the
      # token's identity to the producer's — exactly what dependency-freedom
      # forbids. Discard deeply: facts are data.
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

  # ---- context surgery ----------------------------------------------------

  # Split a context attrset into the two channels.
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

  # ---- readback -----------------------------------------------------------

  readFact = p: builtins.fromJSON (builtins.readFile p);

  # All facts carried by a string (e.g. a workload's manifest JSON),
  # optionally filtered by kind. Deduped by token path for free (context is
  # a set).
  factsFromString =
    s: map readFact (builtins.filter isFactPath (builtins.attrNames (builtins.getContext s)));

  factsOfKind = kind: s: builtins.filter (f: f.kind == kind) (factsFromString s);

  # ---- user-facing escape hatches ----------------------------------------

  # "I name it, I don't dial it": keep the derivation record (ordering),
  # drop the semantic claim. For the rare case where an address-shaped
  # value is used structurally (labels, display strings). Each stripped
  # endpoint is replaced by a `refonly` acknowledgment so the deliberate
  # non-dial travels with the value (suppressing the lint and the
  # conservative DNS dep at whatever workload eventually absorbs it).
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

  # Stamp an endpoint fact onto a value that lacks one — e.g. a bare
  # `out.name` used as an intra-namespace host. Takes the producing
  # resource (anything with out.factTokens.endpoint) or a raw fact ctx.
  connect = factCtx: s: builtins.appendContext s factCtx;
}
