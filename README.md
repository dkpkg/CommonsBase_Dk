# DkStd_Std

`DkStd_Std` now carries the bootstrap split for dk0 packaging.

Implemented here:

- a source-bundle pin for the latest MlFront release tarball
- a `DkStd_Std.Dk0.DuneCache@2.4.2` package that repackages that tarball into
  a reusable zip artifact for all supported slots
- a `DkStd_Std.Dk0@2.4.2` recipe that stages the cache, runs a concrete
  `dune build`, and installs `bin/dk0.exe` for Windows x86_64 only

Still pending:

- the executable package for non-Windows_x86_64 slots
- validation of the toolchain/dependency bootstrap on real runners

Package targets in this repo:

- `DkStd_Std.Dk0.DuneCache@2.4.2`
- `DkStd_Std.Dk0@2.4.2`
