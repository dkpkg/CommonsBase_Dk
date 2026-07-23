#!/bin/sh
# Localize wrapper for CommonsBase_Dk.Dk0.MlFrontSource.
#
# The form extracts the raw MlFront GitLab archive UNSTRIPPED into src/, so it
# lands as a single src/MlFront-<version>/ directory (GitLab names an archive's
# top directory <project>-<ref>, and here <ref> is the full pipeline version,
# e.g. MlFront-2.4.2.282/). Puts /usr/bin on PATH so the localize script's
# awk/sed resolve on every platform (MSYS2 maps /usr/bin to the dash tree on
# Windows).
#
# The version is DERIVED from that directory name -- it is never hardcoded here.
# The GitLab archive has no .git, so the versions that a real (git-tag) build
# would inject are lost, and both dk0/dk1 --version and the generated .opam files
# would otherwise fall back to the base 2.4.2. Two things carry the full version:
#
#   1. ci/version.source.sh: ci/localize-pristine.sh stamps its VERSION into each
#      <pkg>.opam, so the packages carry the full version.
#   2. dune-project.template `(version ...)`: at build time the MlFront_Core
#      Version.ml rule runs `getver -semver ... dune-project.template`, and its
#      output is MlFront_Core.MlFrontConstants.mlfront_version -- what dk0/dk1
#      --version print. getver reads the full 4-part version here and prints the
#      semver form (e.g. 2.4.2.282 -> 2.4.2+rev-282), identical to what a real
#      release that sets MLFRONT_BUILD_VERSION produces. Only the version is
#      changed, so mlfront_version stays a semver for its other consumers
#      (import identity, cache DB filename).
#
# Finally the directory is renamed to the fixed name mlfront/ that packaging and
# the generic build rule expect.
set -e
PATH=/usr/bin:$PATH; export PATH
d=$(ls -d src/MlFront-*/ 2>/dev/null | head -1)
if [ -z "$d" ]; then
  echo "localize.sh: no src/MlFront-<version>/ directory found" >&2
  exit 1
fi
version=$(basename "${d%/}" | sed 's|^MlFront-||')
printf 'VERSION="%s"\n' "$version" > "${d}ci/version.source.sh"
# `sed -i` is not portable: BSD sed (macOS) reads the next argument as a
# mandatory backup suffix, so it swallows the s|...| script. Edit via a temp
# file, which works on GNU, BSD and MSYS2 sed alike.
sed "s|(version [^)]*)|(version ${version})|" "${d}dune-project.template" > "${d}dune-project.template.localized"
mv "${d}dune-project.template.localized" "${d}dune-project.template"
( cd "$d" && sh ci/localize-pristine.sh )
mv "$d" mlfront
