# The Immich release that `immich` and `immich-machine-learning` default to.
# Upstream publishes immich-server and immich-machine-learning under one tag,
# and the server calls machine-learning endpoints of its own release, so a
# bump changes `version` and both digests together.
let
  version = "3.4.2";
in
{
  inherit version;
  tag = "v${version}";

  # Multi-arch index digests of `tag` (`crane digest <repository>:<tag>`).
  digests = {
    server = "sha256:fc880c1bf665b4aab1e74c15e56ab871225989cd546536e6b77e771869af06bd";
    machineLearning = "sha256:739405742a79bd7447227c553bb62ed5491aa36acf00bc667af7f9c93b6fae91";
  };
}
