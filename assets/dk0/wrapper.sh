#!/bin/sh
# Build wrapper for CommonsBase_Dk.Dk0Build.F_BuildLockedPackage.
# Invoked as: <shell> wrapper.sh <gate> <arch> <argv...>
#   <gate>  a ${SLOTABS.<abi>} path used only to scope the command to one slot;
#           dropped here.
#   <arch>  "-" on Unix (no MSVC), or the vcvarsall arch (x64/x86) on Windows.
#   <argv>  the opam build/install command.
# The wrapper chdirs into s/, stages the dependency prefix p/ on the toolchain
# environment (absolute paths derived from $PWD; dk0 exposes no build-dir
# variable and dune rejects relative toolchain paths), rewrites the token @IP@
# to the absolute ip/ install prefix, and execs the command. On Windows it runs
# under MSYS2's dash (whose runtime translates the unix-form PATH to Windows form
# for the native dune.exe/cl.exe children) and self-activates MSVC.
set -e
shift             # drop <gate>
arch=$1; shift    # "-" on Unix, x64/x86 on Windows
root=$(pwd)
cd s
# The source is extracted (by 7zz) without stripping its single top-level
# directory. Descend into that sole directory when it is the only entry in s/,
# so the build runs from the source root on every platform.
count=0; only=
for e in * .[!.]*; do [ -e "$e" ] || continue; count=$((count + 1)); only=$e; done
if [ "$count" -eq 1 ] && [ -d "$only" ]; then cd "$only"; fi
if [ "$arch" != "-" ]; then
  # Windows: MSYS2's coreutils (tr, sed, cygpath) live in /usr/bin, which the
  # MSYS2 runtime maps to the tree dash.exe was launched from. Put it on PATH so
  # those tools resolve before importing the MSVC environment.
  PATH="/usr/bin:$PATH"; export PATH
  vsw="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  vsdir=$("$vsw" -latest -products '*' \
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
    -property installationPath | tr -d '\r')
  # Use the 8.3 short path so no spaces (hence no quotes) are handed to cmd.exe:
  # MSYS2 mangles embedded quotes when it builds the native command line. Invoke
  # cmd.exe by full path because /usr/bin is now ahead of System32 on PATH.
  vcvars=$(cygpath -d "$(cygpath -u "$vsdir")/VC/Auxiliary/Build/vcvarsall.bat")
  cmdexe=$(cygpath -u "${COMSPEC:-C:\\Windows\\System32\\cmd.exe}")
  msvcenv=$(MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 \
    "$cmdexe" //c "call $vcvars $arch >nul 2>nul && set" | tr -d '\r')
  for v in INCLUDE LIB LIBPATH; do
    val=$(printf '%s\n' "$msvcenv" | sed -n "s/^$v=//p")
    [ -n "$val" ] && export "$v=$val"
  done
  winpath=$(printf '%s\n' "$msvcenv" | sed -n 's/^[Pp][Aa][Tt][Hh]=//p')
  [ -n "$winpath" ] && PATH="$(cygpath -up "$winpath"):$PATH"
  # Mixed form (forward slashes, C:/dir): a valid Windows path with no
  # backslashes, so a build path like .../t/p/464/... does not become an sed
  # backreference (\4) when a configure script substitutes @IP@ into a command.
  OCAMLPATH=$(cygpath -m "$root/p/lib")
  ipabs=$(cygpath -m "$root/ip")
  conf="$root/p/lib/findlib.conf"
  [ -f "$conf" ] && export OCAMLFIND_CONF=$(cygpath -m "$conf")
else
  OCAMLPATH="$root/p/lib"
  ipabs="$root/ip"
  conf="$root/p/lib/findlib.conf"
  [ -f "$conf" ] && export OCAMLFIND_CONF="$conf"
fi
export OCAMLPATH
# topkg packages' pkg.ml starts with `#use "topfind"`. findlib installs topfind
# into the OCaml stdlib dir, which here is the read-only, per-build DkML compiler
# object, so it never persists. ocamlfind's build instead captures topfind into
# its own lib/findlib prefix (see the lock's ocamlfind install), so point the
# toplevel there via OCAML_TOPLEVEL_PATH.
if [ -f "$root/p/lib/findlib/topfind" ]; then
  if [ "$arch" != "-" ]; then
    export OCAML_TOPLEVEL_PATH=$(cygpath -m "$root/p/lib/findlib")
  else
    export OCAML_TOPLEVEL_PATH="$root/p/lib/findlib"
  fi
fi
PATH="$root/p/bin:$PATH"; export PATH
# ocamlbuild's configure.make defaults its install dirs to `opam config var bin`
# (which would leak the host opam switch) and its Windows build passes no prefix.
# Point its install variables at this build's ip/ prefix. Harmless for other
# packages; on Unix the opam build passes these as make arguments that win.
export OCAMLBUILD_PREFIX="$ipabs"
export OCAMLBUILD_BINDIR="$ipabs/bin"
export OCAMLBUILD_LIBDIR="$ipabs/lib"
export OCAMLBUILD_MANDIR="$ipabs/man"
if [ "$arch" = "-" ]; then
  # The DkML Unix compiler's native_pack_linker is baked to its own build-time
  # path (not relocated), so `ocamlopt -pack` fails when that script is absent.
  # Recreate it as a thin wrapper over the configured C compiler. (Proper fix
  # belongs in the DkML compiler packaging.)
  oconf=$(ocamlopt.opt -config 2>/dev/null || ocamlopt -config 2>/dev/null)
  npl=$(printf '%s\n' "$oconf" | sed -n 's/^native_pack_linker: *//p' | cut -d' ' -f1)
  if [ -n "$npl" ] && [ ! -f "$npl" ]; then
    cc=$(printf '%s\n' "$oconf" | sed -n 's/^c_compiler: *//p' | cut -d' ' -f1)
    if mkdir -p "$(dirname "$npl")" 2>/dev/null; then
      printf '#!/bin/sh\nexec %s "$@"\n' "$cc" > "$npl" && chmod +x "$npl"
    fi
  fi
fi
if [ "$arch" != "-" ]; then
  # DkML ships ocamlc.exe/ocamlopt.exe but not the ocamlc.opt/ocamlopt.opt
  # aliases some Makefiles invoke. Native make runs "ocamlc.opt" through
  # CreateProcess, which treats .opt as the extension and does not append .exe;
  # since DkML is native-only, provide copies named exactly ocamlc.opt /
  # ocamlopt.opt on PATH (p/bin, searched first). DkML's compiler is relocatable
  # (finds stdlib relative to the exe), so the copies need OCAMLLIB pointed at
  # the real stdlib.
  ocamlc=$(command -v ocamlc.exe 2>/dev/null || true)
  if [ -n "$ocamlc" ]; then
    export OCAMLLIB=$(cygpath -m "$("$ocamlc" -where | tr -d '\r')")
    mkdir -p "$root/p/bin"
    for t in ocamlc ocamlopt ocamllex ocamldep ocamlmklib; do
      if [ ! -f "$root/p/bin/$t.opt" ]; then
        s=$(command -v "$t.exe" 2>/dev/null || true)
        [ -n "$s" ] && cp "$s" "$root/p/bin/$t.opt"
      fi
    done
  fi
  # topkg packages with a myocamlbuild.ml plugin trip ocamlbuild's hygiene check
  # on Windows: the plugin's own compiled files (myocamlbuild.obj/.cmi/.cmx) land
  # in _build and are flagged as leftover, aborting the build (Unix ocamlbuild
  # handles the same plugin fine). Point topkg's ocamlbuild tool at a shim that
  # adds -no-hygiene. topkg's Conf.tool reads a HOST_OS_/BUILD_OS_-prefixed env
  # for the tool command and spawns it through cmd.exe, so use a .cmd shim in
  # p/bin (first on PATH) that calls the real ocamlbuild via PATH (as topkg does
  # by default) with -no-hygiene prepended. Uses the PATH-resolved name, not the
  # shim's own directory, because topkg runs the shim from the package source dir.
  printf '@ocamlbuild -no-hygiene %%*\r\n' > "$root/p/bin/ocamlbuild-nh.cmd"
  export HOST_OS_OCAMLBUILD=ocamlbuild-nh
  export BUILD_OS_OCAMLBUILD=ocamlbuild-nh
fi
# Install an opam <pkg>.install file (packages with no explicit install field,
# e.g. topkg-based ones): copy each listed file into ip/ under the section's
# conventional directory. A leading "?" marks an optional source; {"dest"}
# renames. Invoked as: @INSTALL@ <pkg>.
if [ "$1" = "@INSTALL@" ]; then
  pkg=$2
  inst="$pkg.install"
  [ -f "$inst" ] || exit 0
  awk -v pkg="$pkg" '
    function secdir(s) {
      if (s=="lib"||s=="libexec") return "lib/" pkg
      if (s=="lib_root"||s=="libexec_root") return "lib"
      if (s=="stublibs") return "lib/stublibs"
      if (s=="toplevel") return "lib/toplevel"
      if (s=="bin") return "bin"; if (s=="sbin") return "sbin"
      if (s=="share") return "share/" pkg
      if (s=="share_root") return "share"
      if (s=="etc") return "etc/" pkg
      if (s=="doc") return "doc/" pkg
      if (s=="man") return "man"
      return "" }
    /^[a-zA-Z_]+:/ { h=$0; sub(/:.*/,"",h); sd=secdir(h); next }
    (sd!="") && /"/ {
      line=$0; n=0
      while (match(line, /"[^"]*"/)) {
        q[++n]=substr(line,RSTART+1,RLENGTH-2); line=substr(line,RSTART+RLENGTH) }
      if (n>=1) {
        src=q[1]; opt=0
        if (substr(src,1,1)=="?") { opt=1; src=substr(src,2) }
        if (n>=2) dest=q[2]; else { dest=src; sub(/.*\//,"",dest) }
        print opt "\t" src "\t" sd "/" dest } }
  ' "$inst" > .dk-install-list
  while IFS="$(printf '\t')" read -r opt src rel; do
    tgt="$ipabs/$rel"
    if [ -f "$src" ]; then
      mkdir -p "$(dirname "$tgt")"; cp "$src" "$tgt"
    elif [ "$opt" = "0" ]; then
      echo "install: required file missing: $src" >&2; exit 1
    fi
  done < .dk-install-list
  rm -f .dk-install-list
  exit 0
fi
# Consumer half of the dune-package prefix normalization: staged dependency
# dune-packages carry the fixed token @DK0_IP@ where their producer's install
# prefix was (see the producer half below), so their `sections` are independent
# of where the producer built. Point them at THIS build's staged prefix p/.
# Idempotent (the token is gone after the first rewrite).
pabs="$root/p"
[ "$arch" != "-" ] && pabs=$(cygpath -m "$pabs")
for f in "$root"/p/lib/*/dune-package; do
  [ -f "$f" ] || continue
  if grep -q '@DK0_IP@' "$f"; then
    sed "s#@DK0_IP@#$pabs#g" "$f" > "$f.dk-tmp" && mv "$f.dk-tmp" "$f"
  fi
done
# Rewrite @IP@ -> absolute ip/ in every argument (POSIX-safe rotation).
n=$#
while [ "$n" -gt 0 ]; do
  a=$1; shift
  case "$a" in
    *@IP@*) a=$(printf '%s' "$a" | sed "s#@IP@#$ipabs#g") ;;
  esac
  set -- "$@" "$a"
  n=$((n - 1))
done
"$@"
rc=$?
# Producer half of the dune-package prefix normalization: `dune install` bakes
# the resolved absolute prefix into the emitted dune-package `sections`, which
# would make install.zip vary with the build directory and defeat the
# content-addressed Pkg objects. Rewrite that prefix to the fixed token
# @DK0_IP@ (no-op until the install step has written dune-package files).
if [ "$rc" = 0 ]; then
  for f in "$root"/ip/lib/*/dune-package; do
    [ -f "$f" ] || continue
    if grep -q "$ipabs" "$f"; then
      sed "s#$ipabs#@DK0_IP@#g" "$f" > "$f.dk-tmp" && mv "$f.dk-tmp" "$f"
    fi
  done
fi
exit $rc
