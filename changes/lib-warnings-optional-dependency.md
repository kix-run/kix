+++
kind = "changed"
cli = ["kix check"]
+++
The warning that an optional dependency matches only an instance in another namespace is no longer a scorecard finding of the rule `dependencies.optionalInOtherNamespace`. `kix check` lists it with the other library warnings: on the `eval` row in `-o json`, and under the rule `kix/library-warning` in `-o sarif`. It now appears even when the scorecard is off.
