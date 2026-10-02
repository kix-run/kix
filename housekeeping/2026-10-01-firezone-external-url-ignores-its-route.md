# 2026-10-01 · `kix/packages/firezone` · firezone sets `EXTERNAL_URL` to `https://<domain>` whatever route `kix.expose` renders.

`EXTERNAL_URL = "https://${config.domain}"` hard-codes the scheme, and the required `domain` option is separate from `ingress.host`, so the route `kix.expose` renders can serve another host, or plain HTTP when no cluster issuer is wired, while firezone advertises a URL that does not answer. `self.exposure.url` describes the rendered route. firezone stays unreworked until Adam chooses between reworking and deleting it.
