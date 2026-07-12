local M = {
  id = "CommonsBase_Dk.Dk0Build@2.4.2"
}

-- Generic locked-opam-package builder (v1: Unix slots; Windows/MSVC is the
-- plan's step 5). One instance builds ONE package from a dk-opam-lock JSONC:
--   * reads the lock through a files-expression continuation (no 1024-byte
--     subshell cap; the lock is also a declared input asset),
--   * stages each dependency's install.zip object into a private prefix p/,
--   * fetches and untars the locked source into s/,
--   * interprets the opam build:/install: fields (name/jobs/bin/lib/man
--     vars, %{...}% interpolation, dev/with-test/with-doc/ocaml:* filters),
--   * emits the installed prefix as a single install.zip.
--
-- lua-ml notes: no gsub/gmatch/break/#; module-level locals are nil inside
-- rule functions, so helpers live in a unique global table; boolean table
-- values are unreliable, so sets store the key as its own string value.
CommonsBase_Dk__Dk0Build__2_4_2 = {}
CommonsBase_Dk__Dk0Build__2_4_2.NULL = {}

rules, _uirules = build.newrules(M)

CommonsBase_Dk__Dk0Build__2_4_2.SLOTS = {
  "Release.Windows_x86_64", "Release.Windows_x86",
  "Release.Linux_x86_64", "Release.Linux_x86", "Release.Linux_arm64",
  "Release.Darwin_x86_64", "Release.Darwin_arm64"
}

-- Packages provided by toolchain objects or purely virtual: never built and
-- never staged as dependency objects.
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED = {}
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["ocaml"] = "ocaml"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["ocaml-base-compiler"] = "ocaml-base-compiler"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["ocaml-config"] = "ocaml-config"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["ocaml-options-vanilla"] = "ocaml-options-vanilla"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["base-unix"] = "base-unix"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["base-threads"] = "base-threads"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["base-bigarray"] = "base-bigarray"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["dune"] = "dune"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["flexdll"] = "flexdll"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["conf-mingw-w64-gcc-x86_64"] = "conf-mingw-w64-gcc-x86_64"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["host-arch-x86_64"] = "host-arch-x86_64"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["host-arch-x86_32"] = "host-arch-x86_32"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["host-arch-arm64"] = "host-arch-arm64"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["host-system-mingw"] = "host-system-mingw"
CommonsBase_Dk__Dk0Build__2_4_2.PROVIDED["host-system-other"] = "host-system-other"

function CommonsBase_Dk__Dk0Build__2_4_2.iswhite(c)
  local b = string.byte(c)
  return b == 32 or b == 9 or b == 13 or b == 10
end

-- Coerce a value to a genuine Lua string. lua-ml stores a purely-numeric string
-- literal (e.g. opam's `jobs` -> "4") as a number, and dk0 serializes the rule's
-- returned table by Lua type, emitting a JSON number where the values parser
-- demands a string argv token. Rebuild the decimal digits by hand (lua-ml has no
-- string.format); non-integral or non-numeric values fall through unchanged.
function CommonsBase_Dk__Dk0Build__2_4_2.numstr(v)
  if type(v) == "string" then return v end
  if type(v) ~= "number" then return tostring(v) end
  if v ~= v - (v % 1) then return tostring(v) end   -- non-integral: leave as-is
  if v == 0 then return "0" end
  local n = v
  local neg = false
  if n < 0 then neg = true; n = -n end
  local digits = ""
  while n >= 1 do
    local d = n % 10
    local di = d - (d % 1)
    digits = string.sub("0123456789", di + 1, di + 1) .. digits
    n = (n - d) / 10
  end
  if neg then digits = "-" .. digits end
  return digits
end

function CommonsBase_Dk__Dk0Build__2_4_2.join(tbl, sep)
  -- Iterate by sequential index, not next(): lua-ml `next` visits integer keys
  -- in hash order, which scrambles argv where token order is load-bearing (e.g.
  -- `dune build -p NAME`). lua-ml has no `#`, so walk tbl[1], tbl[2], ... .
  local r = nil
  local i = 1
  while tbl[i] ~= nil do
    if r == nil then r = tostring(tbl[i]) else r = r .. sep .. tostring(tbl[i]) end
    i = i + 1
  end
  if r == nil then return "" end
  return r
end

function CommonsBase_Dk__Dk0Build__2_4_2.indexof(s, ch, i)
  local n = string.len(s)
  local j = i
  while j <= n do
    if string.sub(s, j, j) == ch then return j end
    j = j + 1
  end
  return nil
end

function CommonsBase_Dk__Dk0Build__2_4_2.lastindexof(s, ch)
  local n = string.len(s)
  local j = n
  while j >= 1 do
    if string.sub(s, j, j) == ch then return j end
    j = j - 1
  end
  return nil
end

function CommonsBase_Dk__Dk0Build__2_4_2.endswith(s, suffix)
  local ls = string.len(s)
  local lf = string.len(suffix)
  if lf > ls then return false end
  return string.sub(s, ls - lf + 1) == suffix
end

-- Sanitize an opam package name into a module id segment: uppercase first
-- letter, "-" and "." become "_" (ocaml-compiler-libs -> Ocaml_compiler_libs).
function CommonsBase_Dk__Dk0Build__2_4_2.modsegment(name)
  local out = ""
  local i = 1
  local n = string.len(name)
  while i <= n do
    local c = string.sub(name, i, i)
    if c == "-" or c == "." then c = "_" end
    if i == 1 then c = string.upper(c) end
    out = out .. c
    i = i + 1
  end
  return out
end

-- Tokenize a raw opam build:/install: field into command groups.
-- Group = { toks = {tok...}, filter = TEXT or nil }
-- tok   = { kind = "str"|"ident", v = TEXT, filter = TEXT or nil }
-- A field without surrounding brackets is one group (opam collapses
-- single-command fields when printing).
function CommonsBase_Dk__Dk0Build__2_4_2.tokenize_field(raw)
  local H = CommonsBase_Dk__Dk0Build__2_4_2
  local groups = {}
  local bare = { toks = {} }
  local cur = nil
  local lasttok = nil
  local lastgroup = nil
  local i = 1
  local n = string.len(raw)
  while i <= n do
    local c = string.sub(raw, i, i)
    if H.iswhite(c) then
      i = i + 1
    elseif c == "[" then
      cur = { toks = {} }
      lasttok = nil
      lastgroup = nil
      i = i + 1
    elseif c == "]" then
      assert(cur ~= nil, "unbalanced ] in opam field: " .. raw)
      table.insert(groups, cur)
      lastgroup = cur
      lasttok = nil
      cur = nil
      i = i + 1
    elseif c == "{" then
      local close = H.indexof(raw, "}", i + 1)
      assert(close ~= nil, "unbalanced { in opam field: " .. raw)
      local ftext = string.sub(raw, i + 1, close - 1)
      if lasttok ~= nil then
        lasttok.filter = ftext
      elseif lastgroup ~= nil then
        lastgroup.filter = ftext
      else
        assert(false, "filter with no preceding token in opam field: " .. raw)
      end
      i = close + 1
    elseif c == "\"" then
      local out = ""
      local j = i + 1
      local done = false
      while j <= n and not done do
        local d = string.sub(raw, j, j)
        if d == "\\" then
          out = out .. string.sub(raw, j + 1, j + 1)
          j = j + 2
        elseif d == "\"" then
          done = true
          j = j + 1
        else
          out = out .. d
          j = j + 1
        end
      end
      local tok = { kind = "str", v = out }
      if cur ~= nil then table.insert(cur.toks, tok) else table.insert(bare.toks, tok) end
      lasttok = tok
      lastgroup = nil
      i = j
    else
      local ident = ""
      local j = i
      local stop = false
      while j <= n and not stop do
        local d = string.sub(raw, j, j)
        if H.iswhite(d) or d == "[" or d == "]" or d == "{" or d == "}" or d == "\"" then
          stop = true
        else
          ident = ident .. d
          j = j + 1
        end
      end
      local tok = { kind = "ident", v = ident }
      if cur ~= nil then table.insert(cur.toks, tok) else table.insert(bare.toks, tok) end
      lasttok = tok
      lastgroup = nil
      i = j
    end
  end
  if bare.toks[1] ~= nil then table.insert(groups, bare) end
  return groups
end

-- Split a dotted numeric version into an array of integer segments.
function CommonsBase_Dk__Dk0Build__2_4_2.version_parts(v)
  local out = {}
  local seg = ""
  local i = 1
  local n = string.len(v)
  while i <= n do
    local c = string.sub(v, i, i)
    if c == "." then table.insert(out, tonumber(seg) or 0); seg = ""
    elseif c >= "0" and c <= "9" then seg = seg .. c end
    i = i + 1
  end
  table.insert(out, tonumber(seg) or 0)
  return out
end

-- Compare dotted numeric versions: true when a >= b ("4.14.3" >= "4.02.0").
function CommonsBase_Dk__Dk0Build__2_4_2.version_ge(a, b)
  local pa = CommonsBase_Dk__Dk0Build__2_4_2.version_parts(a)
  local pb = CommonsBase_Dk__Dk0Build__2_4_2.version_parts(b)
  local i = 1
  while pa[i] ~= nil or pb[i] ~= nil do
    local xa = pa[i] or 0
    local xb = pb[i] or 0
    if xa > xb then return true end
    if xa < xb then return false end
    i = i + 1
  end
  return true
end

-- Evaluate an opam filter expression. Supports the shapes in the MlFront
-- lock: IDENT, !IDENT, A & B, A | B, and `ocaml:version OP "str"`.
-- Errors loudly on anything else so gaps surface per package.
function CommonsBase_Dk__Dk0Build__2_4_2.eval_filter(ftext, fenv, pkg)
  local H = CommonsBase_Dk__Dk0Build__2_4_2
  local words = {}
  local i = 1
  local n = string.len(ftext)
  while i <= n do
    local c = string.sub(ftext, i, i)
    if H.iswhite(c) then
      i = i + 1
    elseif c == "\"" then
      local close = H.indexof(ftext, "\"", i + 1)
      assert(close ~= nil, "unbalanced quote in filter: " .. ftext)
      table.insert(words, { k = "str", v = string.sub(ftext, i + 1, close - 1) })
      i = close + 1
    elseif c == "!" or c == "&" or c == "|" then
      table.insert(words, { k = "op", v = c })
      i = i + 1
    elseif c == ">" or c == "<" or c == "=" then
      local two = string.sub(ftext, i, i + 1)
      if two == ">=" or two == "<=" then
        table.insert(words, { k = "op", v = two })
        i = i + 2
      else
        table.insert(words, { k = "op", v = c })
        i = i + 1
      end
    else
      local j = i
      local ident = ""
      local stop = false
      while j <= n and not stop do
        local d = string.sub(ftext, j, j)
        if H.iswhite(d) or d == "!" or d == "&" or d == "|" or d == ">" or d == "<" or d == "=" or d == "\"" then
          stop = true
        else
          ident = ident .. d
          j = j + 1
        end
      end
      table.insert(words, { k = "ident", v = ident })
      i = j
    end
  end

  local st = { idx = 1 }
  local acc = H.filter_atom(words, st, fenv, pkg, ftext)
  while words[st.idx] ~= nil do
    local op = words[st.idx]
    assert(op.k == "op" and (op.v == "&" or op.v == "|"),
      "unsupported filter connective in `" .. ftext .. "` for package " .. pkg)
    st.idx = st.idx + 1
    local rhs = H.filter_atom(words, st, fenv, pkg, ftext)
    if op.v == "&" then acc = acc and rhs else acc = acc or rhs end
  end
  return acc
end

-- Evaluate one filter atom ([!]* IDENT [OP "str"]) advancing st.idx. lua-ml
-- has no nested named local functions, so the closed-over state is passed in.
function CommonsBase_Dk__Dk0Build__2_4_2.filter_atom(words, st, fenv, pkg, ftext)
  local H = CommonsBase_Dk__Dk0Build__2_4_2
  local negate = false
  while words[st.idx] ~= nil and words[st.idx].k == "op" and words[st.idx].v == "!" do
    negate = not negate
    st.idx = st.idx + 1
  end
  local wtok = words[st.idx]
  assert(wtok ~= nil and wtok.k == "ident",
    "unsupported filter `" .. ftext .. "` for package " .. pkg)
  st.idx = st.idx + 1
  local value
  local nexttok = words[st.idx]
  if nexttok ~= nil and nexttok.k == "op" and nexttok.v ~= "&" and nexttok.v ~= "|" and nexttok.v ~= "!" then
    local op = nexttok.v
    st.idx = st.idx + 1
    local rhs = words[st.idx]
    assert(rhs ~= nil and rhs.k == "str",
      "unsupported comparison in filter `" .. ftext .. "` for package " .. pkg)
    st.idx = st.idx + 1
    local lhs = fenv.strings[wtok.v]
    assert(lhs ~= nil, "unknown filter variable `" .. wtok.v .. "` in `" .. ftext .. "` for package " .. pkg)
    if op == ">=" then value = H.version_ge(lhs, rhs.v)
    elseif op == "<=" then value = H.version_ge(rhs.v, lhs)
    elseif op == "=" then value = (lhs == rhs.v)
    else assert(false, "unsupported operator `" .. op .. "` in filter `" .. ftext .. "` for package " .. pkg) end
  else
    local b = fenv.bools[wtok.v]
    assert(b ~= nil, "unknown filter variable `" .. wtok.v .. "` in `" .. ftext .. "` for package " .. pkg)
    value = (b == "true")
  end
  if negate then value = not value end
  return value
end

-- Substitute %{var}% interpolations inside a string token.
function CommonsBase_Dk__Dk0Build__2_4_2.interpolate(s, vars, pkg)
  local H = CommonsBase_Dk__Dk0Build__2_4_2
  local out = ""
  local i = 1
  local n = string.len(s)
  while i <= n do
    if string.sub(s, i, i + 1) == "%{" then
      local close = H.indexof(s, "}", i + 2)
      assert(close ~= nil and string.sub(s, close + 1, close + 1) == "%",
        "unbalanced %{ in `" .. s .. "` for package " .. pkg)
      local var = string.sub(s, i + 2, close - 1)
      local rep = vars[var]
      assert(rep ~= nil, "unknown %{" .. var .. "}% in `" .. s .. "` for package " .. pkg)
      out = out .. rep
      i = close + 2
    else
      out = out .. string.sub(s, i, i)
      i = i + 1
    end
  end
  return out
end

-- Interpret an opam build:/install: field into a list of argv arrays.
function CommonsBase_Dk__Dk0Build__2_4_2.field_to_argvs(raw, fenv, vars, pkg)
  local H = CommonsBase_Dk__Dk0Build__2_4_2
  local argvs = {}
  -- An absent build:/install: field arrives as nil, the rule's H.NULL sentinel,
  -- or jsondk's own `json.null` value (a distinct decoded null). opam fields are
  -- always strings, so treat any non-string as an empty field.
  if type(raw) ~= "string" or raw == "" then return argvs end
  local groups = H.tokenize_field(raw)
  local gi = 1
  while groups[gi] ~= nil do
    local g = groups[gi]
    local keep = true
    if g.filter ~= nil then keep = H.eval_filter(g.filter, fenv, pkg) end
    if keep then
      local argv = {}
      local an = 0
      local ti = 1
      while g.toks[ti] ~= nil do
        local tok = g.toks[ti]
        local tkeep = true
        if tok.filter ~= nil then tkeep = H.eval_filter(tok.filter, fenv, pkg) end
        if tkeep then
          if tok.kind ~= "str" and tok.v == "jobs" then
            -- lua-ml's `V.int.is` coerces a bare numeric string, so an argv token
            -- of "4" (opam's `jobs`) is serialized as a JSON number, which the
            -- values parser rejects. Drop a standalone job count and a preceding
            -- `-j`; the build tool defaults its own parallelism. Combined forms
            -- like `-j%{jobs}%` interpolate to a non-numeric "-j4" and survive.
            if an > 0 and argv[an] == "-j" then argv[an] = nil; an = an - 1 end
          elseif tok.kind == "str" then
            an = an + 1; argv[an] = H.numstr(H.interpolate(tok.v, vars, pkg))
          else
            local rep = vars[tok.v]
            assert(rep ~= nil, "unknown opam variable `" .. tok.v .. "` for package " .. pkg)
            an = an + 1; argv[an] = H.numstr(rep)
          end
        end
        ti = ti + 1
      end
      if argv[1] ~= nil then table.insert(argvs, argv) end
    end
    gi = gi + 1
  end
  return argvs
end

-- Single-quote a token for /bin/sh.
function CommonsBase_Dk__Dk0Build__2_4_2.shq(s)
  local out = "'"
  local i = 1
  local n = string.len(s)
  while i <= n do
    local c = string.sub(s, i, i)
    if c == "'" then out = out .. "'" .. "\\" .. "'" .. "'" else out = out .. c end
    i = i + 1
  end
  return out .. "'"
end

-- Build a single opam command as a coreutils `env` invocation that chdirs into
-- the source and stages the dependency prefix via OCAMLPATH/OCAMLFIND_CONF, then
-- runs the argv directly. A `/bin/sh -c "..."` wrapper cannot be used: dk0
-- tokenizes each command-array element (splitting on spaces, honoring quotes and
-- $(...) subshells), so a shell string with `&&` and quoting fails to parse.
-- `env NAME=VALUE ... CMD ARGS` needs no shell. The prefix paths are relative to
-- the chdir target `s/` (so `../p/lib` resolves to the build-root prefix). The
-- Dune object binary is `dune.exe`, so a leading `dune` is rewritten; the
-- compiler and dune bins are already on PATH via the form envmods.
function CommonsBase_Dk__Dk0Build__2_4_2.shcommand(coreutils, wrapperfetch, argv)
  -- Run the opam command through the build wrapper: `/bin/sh <wrapper> <argv>`.
  -- The wrapper chdirs into s/ and derives an ABSOLUTE OCAMLPATH/OCAMLFIND_CONF
  -- from $PWD (dk0 exposes no build-dir variable and dune rejects relative
  -- toolchain paths). A leading `dune` is rewritten to the Dune object's
  -- `dune.exe`.
  -- `coreutils` is a busybox-style multiplexer; /bin/sh is not one of its
  -- applets, so reach it through `coreutils env /bin/sh ...` (env execs sh).
  local cmd = { coreutils, "env", "/bin/sh", wrapperfetch }
  local ai = 1
  while argv[ai] ~= nil do
    local a = argv[ai]
    if ai == 1 and a == "dune" then a = "dune.exe" end
    table.insert(cmd, a)
    ai = ai + 1
  end
  return cmd
end

-- ---------------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------------
-- Parameters:
--   modver=MODULE@VERSION        the output object (ex.
--                                CommonsBase_Dk.Dk0.Pkg.Csexp@2.4.2); sibling
--                                dependency objects derive from its module
--                                path and version
--   pkg=NAME                     the opam package name in the lock
--   lockmodver=MODULE@VERSION    bundle holding the lock asset
--   lockassetpath=PATH           asset path of the dk-opam-lock JSONC
function rules.F_BuildLockedPackage(command, request, continue_)
  local H = CommonsBase_Dk__Dk0Build__2_4_2
  if command == "declareoutput" then
    local modver = assert(request.user.modver, "please provide `modver=MODULE@VERSION`")
    local lockmodver = assert(request.user.lockmodver, "please provide `lockmodver=MODULE@VERSION`")
    local lockassetpath = assert(request.user.lockassetpath, "please provide `lockassetpath=PATH`")
    assert(request.user.pkg, "please provide `pkg=OPAM_PACKAGE_NAME`")
    return {
      declareoutput = {
        return_objects = {
          id = modver,
          slots = H.SLOTS,
          execution_slot = "Release.execution_abi"
        },
        input_assets = {
          { id = lockmodver, path = lockassetpath }
        }
      }
    }
  end
  if command ~= "submit" then return end

  if continue_ ~= "build" then
    local lockmodver = request.user.lockmodver
    local lockassetpath = request.user.lockassetpath
    return {
      submit = {
        expressions = {
          files = {
            lock = "$(get-asset " .. lockmodver .. " -p " .. lockassetpath .. " -f dk-opam-lock.jsonc)"
          }
        },
        andthen = { continue_ = { state = "build" } }
      }
    }
  end

  -- state "build": lock content is available
  local pkg = request.user.pkg
  local modver = request.user.modver
  local lockfile = request.continued.lock
  local lockjson = request.io.read(lockfile, "a")
  request.io.close(lockfile)
  local jd = require("jsondk")
  local lock = jd.decode(lockjson)
  assert(lock and lock.packages, "could not decode the lock (no packages)")

  -- find the package entry (lock keys are name.version)
  local entry = nil
  local k = next(lock.packages)
  while k do
    local dot = H.indexof(k, ".", 1)
    if dot ~= nil and string.sub(k, 1, dot - 1) == pkg then
      entry = lock.packages[k]
    end
    k = next(lock.packages, k)
  end
  assert(entry ~= nil, "package `" .. pkg .. "` is not in the lock")

  -- module naming: modver = <Parent>.<Segment>@<ver>
  local at = H.lastindexof(modver, "@")
  assert(at ~= nil, "modver must contain @")
  local modpath = string.sub(modver, 1, at - 1)
  local modversion = string.sub(modver, at + 1)
  local lastdot = H.lastindexof(modpath, ".")
  assert(lastdot ~= nil, "modver must be a dotted module path")
  local parent = string.sub(modpath, 1, lastdot)

  -- source archive (requires size in the lock)
  assert(entry.source ~= nil and type(entry.source) == "table" and entry.source.url,
    "package `" .. pkg .. "` has no source archive in the lock")
  local url = entry.source.url
  assert(entry.source.size, "lock has no source.size for `" .. pkg
    .. "`; regenerate the lock with the size-probing OpamLock rule")
  -- Collect checksums: sha256 is the dk bundle checksum (dk cannot express
  -- md5/sha512); sha512/md5/sha256(opam) pick the opam CACHE URL. A sha256 the
  -- lock *computed* for an md5/sha512-only package is not in the cache, so the
  -- cache prefers sha512 > md5 > sha256.
  local sha256, sha512, md5c, sha256o = "", "", "", ""
  local ci = 1
  while entry.source.checksums[ci] ~= nil do
    local cs = entry.source.checksums[ci]
    if string.sub(cs, 1, 7) == "sha256=" then sha256 = string.sub(cs, 8); sha256o = string.sub(cs, 8)
    elseif string.sub(cs, 1, 7) == "sha512=" then sha512 = string.sub(cs, 8)
    elseif string.sub(cs, 1, 4) == "md5=" then md5c = string.sub(cs, 5) end
    ci = ci + 1
  end
  assert(sha256 ~= "", "no sha256 checksum for `" .. pkg .. "` in the lock")
  local ckind, chex = "", ""
  if sha512 ~= "" then ckind = "sha512"; chex = sha512
  elseif md5c ~= "" then ckind = "md5"; chex = md5c
  elseif sha256o ~= "" then ckind = "sha256"; chex = sha256o end
  assert(chex ~= "", "no cache-usable checksum for `" .. pkg .. "`")
  -- opam cache: /cache/<kind>/<first2>/<hash>, the archive filename is the hash
  local srcdir = "https://opam.ocaml.org/cache/" .. ckind .. "/" .. string.sub(chex, 1, 2)
  local srcname = chex
  local srcbundle = modpath .. ".Src@" .. modversion

  -- tar flag from the recorded archive type (the cache filename has no extension)
  local arch = entry.source.archive
  if type(arch) ~= "string" then arch = "tgz" end
  local tarflag = ""
  if arch == "tgz" then tarflag = "z"
  elseif arch == "txz" then tarflag = "J"
  elseif arch == "tbz" then tarflag = "j"
  elseif arch == "tar" then tarflag = ""
  else assert(false, "unsupported archive type `" .. tostring(arch) .. "` for " .. pkg) end

  local toybox = "$(get-object CommonsBase_Std.Toybox@0.8.9 -s Release.execution_abi -m ./toybox -f toybox.exe -e '*')"
  local sevenzz = "$(get-object CommonsBase_Std.S7z@25.1.0 -s Release.execution_abi -e '*' -d :)/7zz.exe"
  local coreutils = "$(get-object CommonsBase_Std.Coreutils@0.8.0 -s ${SLOTNAME.Release.execution_abi} -m ./coreutils.exe -f coreutils.exe -e '*')"

  local commands = {}
  table.insert(commands, { coreutils, "mkdir", "-p", "s", "p/bin", "p/lib", "ip" })

  -- Stage the TRANSITIVE dependency closure into p/, not just direct deps: a
  -- staged dune library (e.g. dune-configurator) records its own requires (csexp)
  -- in its dune-package, so building against it needs those present too. Walk the
  -- lock's depends graph breadth-first, skipping PROVIDED (compiler-supplied)
  -- packages. Each get-object subshell is also the dependency edge.
  local byname = {}
  local lnk = next(lock.packages)
  while lnk do
    local ld = H.indexof(lnk, ".", 1)
    if ld ~= nil then byname[string.sub(lnk, 1, ld - 1)] = lock.packages[lnk] end
    lnk = next(lock.packages, lnk)
  end
  local closure = {}
  local seen = {}
  local queue = {}
  local qh, qt = 1, 0
  local di = 1
  while entry.depends ~= nil and entry.depends[di] ~= nil do
    local dep = entry.depends[di]
    if H.PROVIDED[dep] == nil and seen[dep] == nil then
      seen[dep] = 1; qt = qt + 1; queue[qt] = dep
    end
    di = di + 1
  end
  while qh <= qt do
    local dep = queue[qh]; qh = qh + 1
    table.insert(closure, dep)
    local de = byname[dep]
    if de ~= nil and type(de.depends) == "table" then
      local dj = 1
      while de.depends[dj] ~= nil do
        local d2 = de.depends[dj]
        if H.PROVIDED[d2] == nil and seen[d2] == nil then
          seen[d2] = 1; qt = qt + 1; queue[qt] = d2
        end
        dj = dj + 1
      end
    end
  end
  local depn = 0
  local ci2 = 1
  while closure[ci2] ~= nil do
    local dep = closure[ci2]
    depn = depn + 1
    local depmodver = parent .. H.modsegment(dep) .. "@" .. modversion
    table.insert(commands, {
      sevenzz, "x", "-y", "-op",
      "$(get-object " .. depmodver .. " -s ${SLOTNAME.request} -m ./install.zip -f dep-" .. H.numstr(depn) .. ".zip)"
    })
    ci2 = ci2 + 1
  end

  -- fetch + extract the source (v1: toybox tar; Windows arrives with step 5)
  local srcfetch = "$(get-asset " .. srcbundle .. " -p " .. srcname .. " -f " .. srcname .. ")"
  table.insert(commands, { toybox, "tar", "-x" .. tarflag .. "f", srcfetch, "-C", "s", "--strip-components=1" })

  -- interpret the opam fields
  local fenv = { bools = {}, strings = {} }
  fenv.bools["dev"] = "false"
  fenv.bools["with-test"] = "false"
  fenv.bools["with-doc"] = "false"
  fenv.bools["build"] = "true"
  fenv.bools["post"] = "false"
  fenv.bools["ocaml:native"] = "true"
  fenv.bools["ocaml:preinstalled"] = "false"
  fenv.strings["ocaml:version"] = "4.14.3"
  local vars = {}
  vars["name"] = pkg
  vars["jobs"] = "4"
  vars["make"] = "make"
  -- Install into a SEPARATE prefix ip/ from the staged dependency prefix p/, so
  -- each Pkg object's install.zip contains only its own files (p/ holds the
  -- dependencies, on OCAMLPATH via the wrapper; ip/ receives this package).
  vars["prefix"] = "../ip"
  vars["bin"] = "../ip/bin"
  vars["lib"] = "../ip/lib"
  vars["man"] = "../ip/man"
  vars["dev"] = "false"

  local buildargvs = H.field_to_argvs(entry.build, fenv, vars, pkg)
  local installargvs = H.field_to_argvs(entry.install, fenv, vars, pkg)

  -- dune install fallback when the package relies on opam's .install handling
  local uses_dune = false
  local bchk = 1
  while buildargvs[bchk] ~= nil do
    if buildargvs[bchk][1] == "dune" then uses_dune = true end
    bchk = bchk + 1
  end
  if installargvs[1] == nil and uses_dune then
    installargvs = { { "dune", "install", "--prefix", "../ip", pkg } }
  end

  -- The build wrapper stages the dependency prefix p/ with an absolute OCAMLPATH
  -- (derived from $PWD at runtime) so dune finds the staged dependency libraries
  -- by findlib META discovery. It is fetched once and reused by every command.
  local wrapperfetch = "$(get-asset CommonsBase_Dk.Dk0Build.Wrapper@" .. modversion .. " -p wrapper.sh -f build-wrapper.sh)"

  -- each opam command runs through the wrapper (v1 Unix; Dune object = dune.exe)
  local bi = 1
  while buildargvs[bi] ~= nil do
    table.insert(commands, H.shcommand(coreutils, wrapperfetch, buildargvs[bi]))
    bi = bi + 1
  end
  local ii = 1
  while installargvs[ii] ~= nil do
    table.insert(commands, H.shcommand(coreutils, wrapperfetch, installargvs[ii]))
    ii = ii + 1
  end

  table.insert(commands, { sevenzz, "a", "-tzip", "${SLOT.request}/install.zip", "./ip/*" })

  return {
    submit = {
      values = {
        schema_version = { major = 1, minor = 0 },
        bundles = {
          {
            id = srcbundle,
            listing = { origins = { { name = "src", mirrors = { srcdir } } } },
            assets = {
              {
                origin = "src",
                path = srcname,
                checksum = { sha256 = sha256 },
                size = entry.source.size
              }
            }
          }
        },
        forms = {
          {
            id = request.submit.outputid,
            function_ = {
              envmods = {
                "<PATH=$(--path=absnative get-object CommonsLang_OCaml.DkML.Unix@4.14.3 -s ${SLOTNAME.request} -d : -e 'bin/*')${/}bin",
                "<PATH=$(--path=absnative get-object CommonsLang_OCaml.Dune@3.23.1 -s ${SLOTNAME.request} -d : -e 'bin/*')${/}bin"
              },
              commands = commands
            },
            outputs = {
              assets = { { slots = H.SLOTS, paths = { "install.zip" } } }
            }
          }
        }
      }
    }
  }
end

return M
