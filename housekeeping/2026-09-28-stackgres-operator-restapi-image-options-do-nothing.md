# 2026-09-28 · `kix/packages/stackgres-operator` · `restapi.image` and `adminui.image` change nothing that is deployed.

The two options feed only `out.extraImages`. The operator picks the restapi
and admin-ui images itself from `OPERATOR_IMAGE_VERSION`, so an instance that
sets either option sees no effect, and a pinned digest for them is ignored.
