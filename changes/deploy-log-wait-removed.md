+++
kind = "changed"
cli = ["kix deploy --log-format json"]
+++
The JSON deploy log no longer lists `wait` as a value of a node's `kind`. Only a consumer cluster's wait for its platform's copy of Kix's CRDs produced it, and Kix now installs those CRDs itself.
