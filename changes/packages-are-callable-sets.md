+++
kind = "silent"
+++
If your project calls `builtins.isFunction` or `builtins.functionArgs` on a built-in package such as `packages.harbor`, replace them with `lib.isFunction` and `lib.functionArgs`. Passing a built-in package as `package` or calling it directly works as before. Built-in packages are now callable attribute sets that carry `.id`, so `builtins.isFunction` returns `false` on them and `builtins.functionArgs` fails with `'functionArgs' requires a function`.
