# Name the Kubernetes minor versions this Kix release supports.
#
# Every stable package's `meta.k8s` range accepts each version in `window`
# (the test `k8s-window-stable-packages-cover-it`), so a cluster inside the
# window builds with any set of stable packages. A new Kubernetes minor
# moves both bounds in a Kix minor release.
{
  window = {
    minVersion = "1.36";
    maxVersion = "1.37";
  };
}
