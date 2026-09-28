# 2026-09-27 · `kix/packages/cloudflared`, `kix/packages/dns-exporter` · Both packages ignore `image.pullPolicy`.

Both packages declare `image` with `kix.options.image`, which has a
`pullPolicy` field defaulting to `IfNotPresent`, but neither container sets
`imagePullPolicy`. Setting `config.image.pullPolicy = "Always"` has no effect
on the rendered Deployment. Rendering `imagePullPolicy = config.image.pullPolicy`
would add the field to every cluster that runs either package, so it was left
out of the change that moved them onto `kix.options.image`.
