+++
kind = "fixed"
+++
`kix plan` names an object that left the build but that another Kix cluster still deploys once, as in `= ConfigMap/shared@ns still deployed by Kix cluster b`, instead of printing its name twice. The `detail` of such a `prune` entry in `-o json` no longer repeats the object's name.
