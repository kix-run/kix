# githubConfigUrl as the controller parses it (ParseGitHubConfigFromURL in
# github/actions/actions.go): a host, then an organization, a repository, or
# enterprises/<name>. Upstream also accepts a URL without a scheme, which
# `problem` refuses. runner-set.nix and the arc-runner-set package both
# check it.
rec {
  trimTrailingSlashes =
    s:
    let
      m = builtins.match "(.*[^/])/*" s;
    in
    if m == null then s else builtins.head m;

  # null for an accepted URL, else the reason it is refused.
  problem =
    url:
    if builtins.match "https?://[^/]+/[^/]+(/[^/]+)?" (trimTrailingSlashes url) != null then
      null
    else
      "must be http(s)://<host>/ followed by <org>, <org>/<repo>, or enterprises/<name>; got \"${url}\".";
}
