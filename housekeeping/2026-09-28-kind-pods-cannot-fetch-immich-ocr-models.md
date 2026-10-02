# 2026-09-28 · `kix/packages/immich-machine-learning` · On a local kind cluster the OCR models fail to download, so OCR jobs return 500.

The worker fetches PP-OCRv5 from `cdn-lfs-cn-1.modelscope.cn`. From the
kind pod the TLS handshake timed out every time, while the host fetched
the same URL in one second and the Hugging Face models loaded fine.
After two failed loads the worker answers "Failed to load model
'PP-OCRv5_mobile'" without retrying until its process restarts. To test
OCR on kind, copy the two `.onnx` files into
`/cache/ocr/PP-OCRv5_mobile/{detection,recognition}/model.onnx` and kill
PID 1 in the container, which keeps the emptyDir.

immich-machine-learning now declares a world:443 `model-download` intent.
Nobody has run OCR on kind since, so it is open whether that intent or the
handshake timeout above was the cause.
