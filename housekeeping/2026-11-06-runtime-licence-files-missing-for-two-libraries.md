# 2026-11-06 · `cli/runtime/legal.py` · THIRD_PARTY_LICENSES has no licence text for boehm-gc and libexecinfo.

legal.py looks for LICENSE, COPYING, and NOTICE files at the top of each
source and in doc/. boehm-gc keeps its licence in README.md and
libexecinfo in its source file headers, so their entries give only the
licence name. The build prints "no licence file found in the source of".
