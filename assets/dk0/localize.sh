#!/bin/sh
# Localize wrapper for CommonsBase_Dk.Dk0Localize.F_LocalizeSource.
# Runs from the object build root, where the raw MlFront source was extracted to
# mlfront-2.4.2/. Puts /usr/bin on PATH so the localize script's awk/sed resolve
# on every platform (MSYS2 maps /usr/bin to the dash tree on Windows, as the
# build wrapper relies on), then runs the checked-in ci/localize-pristine.sh from
# the source root. That script stamps the version into each *.opam.template ->
# <pkg>.opam and copies dune-project.template -> dune-project; its `git describe`
# fails without a .git checkout and falls back to ci/version.source.sh (2.4.2).
set -e
PATH=/usr/bin:$PATH; export PATH
cd mlfront-2.4.2
exec sh ci/localize-pristine.sh
