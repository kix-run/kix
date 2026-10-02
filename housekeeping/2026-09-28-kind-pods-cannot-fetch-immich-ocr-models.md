# 2026-09-28 · `kix/packages/immich-machine-learning` · On a local kind cluster the OCR models fail to download, so OCR jobs return 500.

The worker fetches PP-OCRv5 from `cdn-lfs-cn-1.modelscope.cn`. From a kind
pod the TLS handshake times out every time, while the host fetches the same
URL in about a second. After two failed loads the worker answers "Failed to
load model 'PP-OCRv5_mobile'" without retrying until its process restarts.

The cause is the host network, not Kix. Checked on 2026-10-02 (W6 kind run
K2b): the host's uplink has MTU 1400, the kind bridge 1500, and the
modelscope CDN path drops path MTU discovery. The kind node container times
out too, and reaches the CDN at once with a route of `mtu 1400`. With the
Cilium value `MTU = 1400` on the `cilium` instance, the OCR models download
in two seconds and OCR, CLIP, and face models all load.

The package's world:443 `model-download` intent is needed: without it
Cilium drops the worker's connections to Hugging Face and the CLIP download
never finishes. To test OCR on kind on such a host, set the Cilium MTU to
the uplink's.
