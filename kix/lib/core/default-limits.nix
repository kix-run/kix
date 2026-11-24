# The values of `cluster.defaultLimits`. "package" keeps the limit a
# package gives by default, and "none" leaves it out.
{
  modes = [
    "package"
    "none"
  ];

  # The value in a cluster that leaves the option unset.
  default = {
    cpu = "package";
    memory = "package";
  };
}
