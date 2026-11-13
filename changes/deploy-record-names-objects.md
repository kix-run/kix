+++
kind = "added"
state = true
+++
A deploy now stores the kind, namespace, and name of each object in its deployment record, beside the list of objects it already stored. `kix status` uses them to name a missing object on any machine, including one that does not have the build. For a record written by an earlier version of Kix, `kix status` names a missing object only when Kix's local store holds the build, and shows the start of its identity hash otherwise. Earlier versions of Kix ignore the new field.
