+++
kind = "fixed"
+++
Every library warning about an instance now starts with the instance's namespace and name in brackets, such as `[monitoring/prometheus]`. Before, the warning that Kix skipped a `meta.compatibleWith` check did not name the instance, and other warnings named it in different forms.
