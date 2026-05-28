[
  {
    group = "tutorials/02-hello-world";
    page = "/docs/tutorials/02-local-setup-and-first-run/";
    cwd = "kix-examples/";
    commands = [
      {
        name = "list-clusters";
        args = [
          "list"
          "clusters"
        ];
      }
      {
        name = "list-packages";
        args = [
          "list"
          "packages"
          "--cluster"
          "02-hello-world"
        ];
      }
    ];
  }
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
        # Tree view: line order encodes hierarchy. Drift comparison must
        # preserve it, otherwise sibling reorders or depth shifts get hidden.
        sortLines = false;
      }
    ];
  }
]
