# 2026-09-27 · `kix/packages/{immich,immich-machine-learning}` · The immich server image is v3.0.3 but the machine-learning image is v2.0.0, and the server's OCR jobs fail against it.

Immich expects both images at the same release. On kind, uploading a photo
ran the v3 OCR job, and the v2 worker answered 500 with "ValueError: Unknown
model combination: None, detection, ocr". Thumbnails, CLIP and faces still
worked. Nothing ties the two `image.tag` defaults together, so bumping one
package leaves the other behind.
