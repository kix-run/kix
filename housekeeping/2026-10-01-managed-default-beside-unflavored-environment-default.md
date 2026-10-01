# 2026-10-01 · `kix/lib/vocab/storage-class.nix` · A cluster with no flavour can get two default StorageClasses.

`kix.storage.mkClasses` refuses a class annotated
`storageclass.kubernetes.io/is-default-class` only when
`cluster.roles.storageClasses.binding` is `"shadowable"`, which a flavour
sets when its environment has a default class. Without a flavour the
binding is unset, so a `storage-classes` instance can annotate a default on
a cluster whose environment already has one. The apiserver then holds two
defaults and gives unclassed claims the newest one.
