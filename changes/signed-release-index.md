+++
kind = "error"
id = "K5221"
+++
Kix now checks the signature of the release index before it installs or offers a release, and refuses an index that is not signed with a key built into Kix, that expired, or that is older than one it has already accepted. kix.run signs a fresh index every day. If you set `KIX_RELEASE_SOURCE` to a mirror of kix.run, copy `releases/index.json.sig` along with `releases/index.json`, and copy both again at least once a week, because an index expires seven days after kix.run made it. A mirror without the signature makes Kix stop with `[K5221]`. An expired index stops Kix from choosing a release, but a version named exactly, as `flake.lock` names it, still installs with a warning.
