# DkStd_Std

`DkStd_Std` is the bootstrap scaffold for the core dk standard tooling.

This repository is only a bootstrap scaffold for the planned
`DkStd_Std.Dk0.DuneCache@2.4.2` and `DkStd_Std.Dk0@2.4.2` packages.
The future `Dk0@2.4.2` package will consume the latest MlFront release
tarball, but the concrete build recipe is intentionally deferred.

Repository scaffold:

- `etc/dk/v/DkStd_Std/` — package notes and future values files.
- `dist-*.u` — placeholder distribution scripts for the planned release
  matrix.

The planned package targets in this repository are:

- `DkStd_Std.Dk0.DuneCache@2.4.2`
- `DkStd_Std.Dk0@2.4.2`

`Dk0@2.4.2` is intended to package the `bin/dk0.exe` executable built from the
latest MlFront release tarball.
