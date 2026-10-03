# 2026-10-03 · `cli/kix/src/eval/store_graph.rs` · A live import marker joins every build package that lists it, including packages not yet on the cluster.

`StoreGraph::synthesize` puts a live object under each build package listing its path, because one `secret-ref-*` marker can be listed by several packages. A package that is new in the build and imports an existing marker therefore gets that marker on the old side, and `kix diff` shows the package as updated rather than added.
