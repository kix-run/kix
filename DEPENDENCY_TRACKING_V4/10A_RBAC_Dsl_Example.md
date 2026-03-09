Since Claude is quite a novice in nix. Let me show how "50% Rbac" code is not an excuse to keep cert-manager messy.
This is just an example I came up with to keep rbac clean - and I would love the whole package level resource definition to be this clean

```nix
let
  inherit (kixlib'.rbac.dsl)
    group core grant grantWith
    # Intents — what a controller does with a resource:
    #
    #   watch            — passively observe          (get, list, watch)
    #   reconcile        — own the reconcile loop     (watch + update/patch status + manage finalizers)
    #   own              — manage child objects        (watch + create, delete)
    #   readWrite        — full lifecycle, no patch    (watch + create, update, delete)
    #   full             — unrestricted mutation       (readWrite + patch)
    #   watchAndFinalize — observe + set finalizers    (watch + update /finalizers)
    #   emit             — produce events              (create, patch)
    #   allow            — escape hatch: explicit verbs
    #   restrictTo       — scope to specific resourceNames
    watch reconcile own readWrite full
    watchAndFinalize emit allow restrictTo;

  # API group aliases — no more raw strings scattered everywhere
  cm    = group "cert-manager.io";
  acme  = group "acme.cert-manager.io";
  gw    = group "gateway.networking.k8s.io";
  net   = group "networking.k8s.io";
  certs = group "certificates.k8s.io";
  authz = group "authorization.k8s.io";
  ocp   = group "route.openshift.io";

in mkRoleSet {
  subjects = controllerSubjects;

  roles = {

    # ── Issuer controllers ──────────────────────────────────────────

    "cert-manager-controller-issuers" = grant [
      cm.issuers   |> reconcile
      core.secrets |> readWrite
      core.events  |> emit
    ];

    "cert-manager-controller-clusterissuers" = grant [
      cm.clusterissuers |> reconcile
      core.secrets      |> readWrite
      core.events       |> emit
    ];

    # ── Certificate lifecycle ───────────────────────────────────────

    "cert-manager-controller-certificates" = grant [
      cm.certificates        |> reconcile       # watch certs, update status, manage finalizers
      cm.certificaterequests |> reconcile       # same for CSRs
      cm.clusterissuers      |> watch           # look up issuer config
      cm.issuers             |> watch
      acme.orders            |> own             # create/delete ACME orders as children
      core.secrets           |> full            # store issued certs + read CA bundles
      core.events            |> emit
    ];

    # ── ACME flow ───────────────────────────────────────────────────

    "cert-manager-controller-orders" = grant [
      acme.orders       |> reconcile            # drive order state machine
      acme.challenges   |> own                  # spawn challenges for each order
      cm.clusterissuers |> watch                # resolve issuer references
      cm.issuers        |> watch
      core.secrets      |> watch                # read ACME account keys
      core.events       |> emit
    ];

    "cert-manager-controller-challenges" = grant [
      acme.challenges        |> reconcile       # drive challenge solvers
      cm.issuers             |> watch           # look up solver config
      cm.clusterissuers      |> watch
      core.secrets           |> watch           # read solver credentials
      core.events            |> emit
      core.pods              |> own             # spin up HTTP01 solver pods
      core.services          |> own             # expose solver pods
      net.ingresses          |> readWrite       # create/update solver ingresses
      gw.httproutes          |> readWrite       # or gateway API equivalents
      ocp."routes/custom-host" |> allow [ "create" ]  # OpenShift solver route
    ];

    # ── Ingress/Gateway shim ────────────────────────────────────────

    "cert-manager-controller-ingress-shim" = grant [
      cm.certificates        |> readWrite       # create certs for annotated ingresses
      cm.certificaterequests |> readWrite
      cm.issuers             |> watch           # resolve issuer annotations
      cm.clusterissuers      |> watch
      net.ingresses          |> watchAndFinalize  # watch ingresses, set cleanup finalizer
      gw.gateways            |> watchAndFinalize
      gw.httproutes          |> watchAndFinalize
      core.events            |> emit
    ];

    # ── Signer permissions ──────────────────────────────────────────

    "cert-manager-controller-approve:cert-manager-io" = grantWith {
      labels = controllerLabels.all // { "app.kubernetes.io/component" = "cert-manager"; };
    } [
      cm.signers
        |> restrictTo [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]
        |> allow [ "approve" ]
    ];

    "cert-manager-controller-certificatesigningrequests" = grantWith {
      labels = controllerLabels.all // { "app.kubernetes.io/component" = "cert-manager"; };
    } [
      certs.certificatesigningrequests          |> watch
      certs.certificatesigningrequests          |> allow [ "update" ]
      certs."certificatesigningrequests/status" |> allow [ "update" "patch" ]
      certs.signers
        |> restrictTo [ "issuers.cert-manager.io/*" "clusterissuers.cert-manager.io/*" ]
        |> allow [ "sign" ]
      authz.subjectaccessreviews |> allow [ "create" ]
    ];

  };
}
```
