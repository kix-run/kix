+++
kind = "fixed"
+++
When an object is removed from one Kix cluster's build while another Kix cluster still deploys it, `kix plan` now prints the object's name once (`= ConfigMap/shared@ns still deployed by Kix cluster b`) instead of twice, and no longer repeats the name in `prune` entry `detail` strings in `-o json`.
