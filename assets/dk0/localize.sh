#!/bin/sh
# Localize wrapper for CommonsBase_Dk.Dk0Localize.F_LocalizeSource.
# Runs from the object build root, where the rule has extracted the raw MlFront
# source into mlfront/ (get-asset -n 1 stripped the archive's version-specific
# top-level dir). Puts /usr/bin on PATH so the localize script's awk/sed resolve
# on every platform (MSYS2 maps /usr/bin to the dash tree on Windows, as the build
# wrapper relies on), descends into mlfront/, then runs the checked-in
# ci/localize-pristine.sh from the source root. That script stamps the version
# into each *.opam.template -> <pkg>.opam and copies dune-project.template ->
# dune-project; its `git describe` fails without a .git checkout and falls back to
# ci/version.source.sh (2.4.2).
set -e
PATH=/usr/bin:$PATH; export PATH
cd mlfront
exec sh ci/localize-pristine.sh
