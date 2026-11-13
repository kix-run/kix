+++
kind = "error"
cli = ["kix self update", "kix upgrade --preview", "kix upgrade --ack"]
id = "K4616"
+++
"Upgrade" is now the one word for moving to a newer version, and `--dry-run` the one flag for changing nothing. `kix self update` is now `kix self upgrade`, `kix upgrade --preview` is now `kix upgrade --dry-run`, and `kix upgrade --ack ID` is now `kix upgrade --acknowledge ID`. Messages that told you to run the old forms now name the new ones. The old forms fail with an error that names the new one.
