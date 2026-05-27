[
  {
    group = "tutorials/06-service-dep";
    page = "/docs/tutorials/06-first-local-package-and-service-to-service-dependency/";
    cwd = "kix-examples/";
    commands = [
      {
        name = "check";
        args = [
          "check"
          "06-service-dep"
        ];
      }
      {
        name = "graph-tree";
        args = [
          "graph"
          "06-service-dep"
          "--format"
          "tree"
        ];
      }
    ];
  }
]
