+++
kind = "error"
library = ["kix.options.oidc", "kix.options.mail"]
id = "K0106"
+++
For packages that sign users in or send mail: `kix.options.oidc` is now
`kix.contracts.oidc.options`, and `kix.options.mail` is now
`kix.contracts.smtp.options`. The old names fail with an error that gives the
new one.
