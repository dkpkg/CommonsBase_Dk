local M = {
  id = "CommonsBase_Dk.Dk0Build@2.4.2"
}

-- ==========================================================================
-- CommonsBase_Dk.Dk0Build.F_BuildLockedPackage - per-opam-package build rule
-- ==========================================================================
--
-- PURPOSE
-- One instance of this rule builds exactly ONE opam package - one node of the
-- solved opam dependency graph - into a per-slot dk object
-- `<Parent>.Pkg.<Segment>@<version>` whose entire payload is a single
-- install.zip. dk0 (DkZero_Exec) is then just the object of the root package
-- `DkZero_Exec`, and its transitive closure is a fan-out of these per-package
-- objects that dk0's content-addressed cache builds incrementally.
--
-- WHERE THE DEPENDENCY GRAPH COMES FROM (the opam solver is NOT run here)
-- The opam solver runs once, at author time, in the reusable UI rule
-- CommonsLang_OCaml.Dk.OpamLock.Solve@1.0.0. That rule spawns `opam` (via
-- request.ui.capture) to solve the pinned dependency closure for every DkML
-- slot against a pinned opam-repository commit, and writes the solution to a
-- checked-in JSONC lock (dk-opam-lock.jsonc). The lock IS the frozen, per-slot
-- opam dependency graph: for each package node it records the version, the
-- source (opam-cache url + checksums + size + archive type), the direct
-- `depends` edges, and the raw opam `build:`/`install:` fields. This rule only
-- READS that lock and never solves, so a build is reproducible and needs no
-- solver, no network metadata and no opam at build time.
--
-- HOW ONE LOCK NODE BECOMES A DYNAMIC BUILD FORM (three phases)
--   1. `declareoutput` - declares the 7-slot return objects
--      `<Parent>.Pkg.<Segment>@<version>` and the lock as an input asset.
--   2. `submit` with continue_ ~= "build" - returns a files-expression
--      `$(get-asset <lock> ...)` that dk0 materialises, then re-invokes with
--      continue_ = "build". The lock is read this way (not via a $(...)
--      subshell) to dodge the 1024-byte subshell cap and to make the lock a
--      real declared input.
--   3. `submit` with continue_ == "build" - decodes the lock, finds this
--      package's entry, and RETURNS a dynamically synthesised `submit.values`:
--      a `.Src` bundle (the package source, fetched from the opam cache) plus a
--      `form` whose commands do the build. dk0 builds that form as the Pkg
--      object. The build is thus data (a value) computed from the lock node,
--      not a static recipe.
--
-- THE BUILD LAYOUT AND ENVIRONMENT
--   s/  - the unpacked package source (build happens here).
--   p/  - the staged TRANSITIVE dependency prefix, presented to the build on
--         OCAMLPATH so libraries are found by findlib META discovery. Always
--         seeded with p/lib/seq/META (see the seq case below).
--   ip/ - the install prefix for THIS package only; install.zip = ip/ alone,
--         so a Pkg object never re-ships its dependencies.
--   Toolchain on PATH (form envmods): the relocatable OCaml 4.14 compiler
--   CommonsLang_OCaml.DkML@4.14.3 (the unified object that covers every slot -
--   the Unix compiler on Unix slots, the MSVC compiler on Windows slots) and
--   CommonsLang_OCaml.Dune@3.23.1; for non-dune packages also GNU make from
--   CommonsBase_GNU.Make@4.4.1.
--   Command tools (get-object subshells): CommonsBase_Std.Coreutils@0.8.0
--   (mkdir/cp/env), CommonsBase_Std.Toybox@0.8.9 (tar), CommonsBase_Std.S7z@25.1.0
--   (7zz zip/unzip).
--   Each opam build/install command runs as
--     coreutils env /bin/sh <Dk0Build.Wrapper wrapper.sh> <argv...>
--   The wrapper chdirs into s/, exports an ABSOLUTE OCAMLPATH=<root>/p/lib and
--   PATH=<root>/p/bin:$PATH (plus OCAMLFIND_CONF when p/lib/findlib.conf was
--   staged), and rewrites the token @IP@ to the absolute ip/ path. On Windows
--   (step 5) /bin/sh is dash from CommonsLang_OCaml.MSYS2@<version> and the MSVC
--   environment is activated before the compile commands run.
--
-- BUILD-CASE WALKTHROUGH (by example package)
--   * Dune leaf - csexp. csexp depends only on PROVIDED packages (dune, ocaml),
--     so nothing is staged into p/. Dk0Build translates its opam build field
--     `["dune" "build" "-p" name ...]` into `dune build -p csexp @install` and
--     supplies the missing install field as the fallback
--     `dune install --prefix ../ip csexp`. A dune package uses the RELATIVE ip/
--     prefix, which dune resolves once from the source root and which keeps the
--     output reproducible (an absolute build path would leak into dune-package).
--   * Dune with a staged dependency - dune-configurator, which depends on csexp.
--     csexp's Pkg object install.zip is unpacked into p/ (the `get-object`
--     subshell is also the dependency edge). dune-configurator's
--     `dune build -p dune-configurator` finds csexp through the wrapper's
--     OCAMLPATH by findlib META, links it, and installs to ip/.
--   * Dune transitive DAG - base, which depends on sexplib0 and
--     dune-configurator (which depends on csexp). The whole closure
--     {sexplib0, dune-configurator, csexp} is staged into p/, because a staged
--     dune library records its own `requires` (dune-configurator requires csexp)
--     in its dune-package and so needs those present transitively.
--   * Non-dune configure/make - ocamlfind. make is on PATH through
--     CommonsBase_GNU.Make@4.4.1; ./configure runs under the POSIX /bin/sh (on
--     Windows, dash from CommonsLang_OCaml.MSYS2@<version>). Dk0Build translates
--     the opam build field `[["./configure" ...] [make "all"] [make "opt"]]` and
--     install field `[make "install"]` into env-wrapped argv commands (make and
--     configure invoked directly, no shell string). A non-dune package installs
--     into the ABSOLUTE @IP@ prefix so its own recursive make resolves the
--     prefix identically from any subdirectory.
--   * Mixed closure - ppxlib, a dune package whose closure mixes dune libraries
--     (sexplib0, ocaml-compiler-libs, stdlib-shims, ppx_derivers, re) with the
--     non-dune ocamlfind. All are staged into p/ in dependency order; the dune
--     and non-dune paths above compose without special-casing.
--   * stdlib shim - seq (a dependency of re). For OCaml 4.07 and above the opam
--     `seq` package is the virtual `seq.base`: Seq is in the stdlib and the
--     package ships only a dummy findlib META. seq has no Pkg object to stage,
--     so the rule writes that stub META into p/lib/seq/META in every build so a
--     package's `(libraries seq)` resolves.
--
-- lua-ml notes: no gsub/gmatch/break/#; module-level locals are nil inside
-- rule functions, so helpers live in a unique global table; boolean values
-- (returns, arguments, table values) are unreliable, so flags are numeric and
-- sets store the key as its own string value.
CommonsBase_Dk__Dk0Build__2_4_2 = {}
CommonsBase_Dk__Dk0Build__2_4_2.NULL = {}

rules, _uirules = build.newrules(M)

CommonsBase_Dk__Dk0Build__2_4_2.SLOTS = {
  "Release.Windows_x86_64", "Release.Windows_x86",
  "Release.Linux_x86_64", "Release.Linux_x86", "Release.Linux_arm64",
  "Release.Darwin_x86_64", "Release.Darwin_arm64"
}

-- Per-abi metadata for the per-slot build commands. `msvc` is the vcvarsall
-- architecture on Windows slots, "-" on Unix slots (no MSVC). Each opam build
-- command is emitted once per abi and gated to that abi's ${SLOTABS.<abi>}, so
-- dk0 skips the non-matching commands when building a given slot (see
-- ThunkAst.can_optimize_out_resolved_term). Populate by bracket-index because
-- slot names contain dots.
CommonsBase_Dk__Dk0Build__2_4_2.ABIS = {
  { slot = "Release.Windows_x86_64", msvc = "x64" },
  { slot = "Release.Windows_x86",    msvc = "x86" },
  { slot = "Release.Linux_x86_64",   msvc = "-" },
  { slot = "Release.Linux_x86",      msvc = "-" },
  { slot = "Release.Linux_arm64",    msvc = "-" },
  { slot = "Release.Darwin_x86_64",  msvc = "-" },
  { slot = "Release.Darwin_arm64",   msvc = "-" }
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
-- True when the string is one or more ASCII digits (a value lua-ml would
-- serialize as a JSON number rather than a string).
function CommonsBase_Dk__Dk0Build__2_4_2.is_pure_int(s)
  if type(s) ~= "string" or s == "" then return nil end
  local i = 1
  local n = string.len(s)
  while i <= n do
    local c = string.sub(s, i, i)
    if c < "0" or c > "9" then return nil end
    i = i + 1
  end
  return 1
end

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
  -- Detect a comparison operator after the identifier. `!=` may arrive as one
  -- `!=` op or as `!` `=` (two ops), depending on how the field was tokenized.
  local op = ""
  local nexttok = words[st.idx]
  if nexttok ~= nil and nexttok.k == "op" then
    local nt2 = words[st.idx + 1]
    if nexttok.v == "!" and nt2 ~= nil and nt2.k == "op" and nt2.v == "=" then
      op = "!="; st.idx = st.idx + 2
    elseif nexttok.v == "!=" then
      op = "!="; st.idx = st.idx + 1
    elseif nexttok.v ~= "&" and nexttok.v ~= "|" and nexttok.v ~= "!" then
      op = nexttok.v; st.idx = st.idx + 1
    end
  end
  if op ~= "" then
    local rhs = words[st.idx]
    assert(rhs ~= nil and rhs.k == "str",
      "unsupported comparison in filter `" .. ftext .. "` for package " .. pkg)
    st.idx = st.idx + 1
    local lhs = fenv.strings[wtok.v]
    assert(lhs ~= nil, "unknown filter variable `" .. wtok.v .. "` in `" .. ftext .. "` for package " .. pkg)
    if op == ">=" then value = H.version_ge(lhs, rhs.v)
    elseif op == "<=" then value = H.version_ge(rhs.v, lhs)
    elseif op == "=" then value = (lhs == rhs.v)
    elseif op == "!=" then value = (lhs ~= rhs.v)
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
      -- opam <pkg>:installed is true for provided/closure packages (seeded into
      -- vars) and false for anything else not queried at build time.
      if rep == nil and string.len(var) >= 10
         and string.sub(var, string.len(var) - 9) == ":installed" then
        rep = "false"
      end
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
            local sval = H.interpolate(tok.v, vars, pkg)
            -- A standalone pure-integer string (e.g. the mode in `install -m
            -- 0644`) serializes as a JSON number that the values parser rejects.
            -- When it follows a short flag, attach it (`-m0644`); getopt-style
            -- tools accept the attached form and the token stays a string.
            if an > 0 and H.is_pure_int(sval) and string.sub(argv[an], 1, 1) == "-"
               and string.len(argv[an]) <= 2 then
              argv[an] = argv[an] .. sval
            else
              an = an + 1; argv[an] = H.numstr(sval)
            end
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
-- the source and stages the dependency prefix via the wrapper. Returns a LIST of
-- commands, one per abi (the opam build is the same everywhere but the shell and
-- MSVC activation differ per OS): the invocation is
--   coreutils env <shell> <wrapper> <gate> <arch> <argv...>
-- where <shell> is /bin/sh on Unix and MSYS2's dash on Windows; <gate> is
-- ${SLOTABS.<abi>}, a throwaway argument whose only purpose is to scope the
-- command to that abi (dk0 skips a command whose referenced output slot is not
-- the one being built); and <arch> is the vcvarsall arch on Windows or "-" on
-- Unix. The wrapper drops <gate>, activates MSVC when <arch> is not "-", chdirs
-- into s/, stages the dependency prefix, and runs the argv. A leading `dune` is
-- rewritten to the Dune object's `dune.exe`.
-- The opam `os` filter variable for an abi: `win32` on Windows, otherwise the
-- kernel name opam uses (`macos` for Darwin, `linux` elsewhere). Lets the field
-- interpreter select os-conditional build/install commands ({os = "win32"}).
function CommonsBase_Dk__Dk0Build__2_4_2.abi_os(abi)
  if abi.msvc ~= "-" then return "win32" end
  if string.find(abi.slot, "Darwin") ~= nil then return "macos" end
  return "linux"
end

-- Emit ONE gated command for a single abi, wrapping the opam argv per the
-- invocation `coreutils env <shell> <wrapper> <gate> <arch> <argv...>`. Because
-- os-conditional fields make the argv differ per abi, the caller interprets the
-- field once per abi and calls this for each; the ${SLOTABS.<abi>} gate scopes
-- the command to that abi. A leading `dune` becomes the Dune object's dune.exe.
function CommonsBase_Dk__Dk0Build__2_4_2.percommand_abi(coreutils, wrapperfetch, msys2dash, argv, abi)
  local shell = "/bin/sh"
  if abi.msvc ~= "-" then shell = msys2dash end
  local cmd = { coreutils, "env", shell, wrapperfetch,
    "${SLOTABS." .. abi.slot .. "}", abi.msvc }
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
  -- A source in the opam cache is fetched from /cache/<kind>/<first2>/<hash>,
  -- where the archive filename is the bare hash. A source not in the cache (a
  -- custom fork or pin, which the lock marks source.incache=0) is fetched from
  -- its direct URL instead, split into a mirror directory and the archive
  -- filename. Either way the fetched file is renamed to the hash below, so the
  -- extraction is identical. srcname is the asset path in the synthesized bundle.
  local srcdir = "https://opam.ocaml.org/cache/" .. ckind .. "/" .. string.sub(chex, 1, 2)
  local srcname = chex
  if entry.source.incache == 0 then
    local slash = H.lastindexof(url, "/")
    srcdir = string.sub(url, 1, slash - 1)
    srcname = string.sub(url, slash + 1)
  end
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
  table.insert(commands, { coreutils, "mkdir", "-p", "s", "p/bin", "p/lib/seq", "ip" })

  -- Provide the findlib `seq` stub so `(libraries seq)` resolves. For OCaml >=
  -- 4.07 the opam `seq` package is the virtual `seq.base`: Seq is in the stdlib
  -- and the package ships only a dummy META (empty requires). It has no Pkg
  -- object to stage, so the rule places the stub directly into every prefix.
  table.insert(commands, {
    coreutils, "cp",
    "$(get-asset CommonsBase_Dk.Dk0Build.SeqMeta@" .. modversion .. " -p seq-META -f seq-meta-src)",
    "p/lib/seq/META"
  })

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
  -- A dep is staged only when it has a buildable source in the lock. Skip
  -- PROVIDED (compiler/dune) and source-less virtuals (e.g. seq is the compiler
  -- stdlib's Seq, base-domains, conf-*), which have no Pkg object to stage.
  while entry.depends ~= nil and entry.depends[di] ~= nil do
    local dep = entry.depends[di]
    if H.PROVIDED[dep] == nil and seen[dep] == nil and byname[dep] ~= nil
      and type(byname[dep].source) == "table" then
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
        if H.PROVIDED[d2] == nil and seen[d2] == nil and byname[d2] ~= nil
          and type(byname[d2].source) == "table" then
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

  -- Fetch + extract the source with 7zz, which (unlike toybox) has a slice for
  -- every slot including Windows. 7zz cannot --strip-components, so a compressed
  -- archive is first decompressed to a .tar in the build root and its members
  -- are then extracted into s/ preserving the single top-level <pkg>-<version>/
  -- directory; the build wrapper descends into that sole directory (a uniform
  -- shape across all platforms). The fetched file is named with its archive
  -- extension so 7zz detects the format.
  local srcout = chex .. "." .. arch
  local srctar = chex .. ".tar"
  local srcfetch = "$(get-asset " .. srcbundle .. " -p " .. srcname .. " -f " .. srcout .. ")"
  -- Exclude any examples/ directory: it is never compiled or installed, and
  -- some source tarballs ship symlinks there that 7zz refuses to extract (a
  -- "dangerous link path" that otherwise fails the whole extraction).
  if tarflag ~= "" then
    table.insert(commands, { sevenzz, "x", "-y", "-o.", srcfetch })
    table.insert(commands, { sevenzz, "x", "-y", "-os", srctar, "-xr!examples" })
  else
    table.insert(commands, { sevenzz, "x", "-y", "-os", srcfetch, "-xr!examples" })
  end

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
  -- A dune package (its build field invokes dune) installs to a RELATIVE ip/
  -- prefix, which dune resolves from the source root and which keeps the output
  -- reproducible (an absolute build path would leak into dune-package). The
  -- wrapper runs from s/<pkg-version>/ (the sole directory 7zz extracts, since
  -- 7zz cannot strip it), which is two levels below the build root that holds
  -- ip/, so the relative prefix is ../../ip. A non-dune package (configure/make)
  -- needs the ABSOLUTE token @IP@ that the wrapper rewrites, because its
  -- recursive make resolves the prefix from subdirectories. Numeric flag, not
  -- boolean (lua-ml booleans are unreliable).
  local uses_dune = 0
  if type(entry.build) == "string" and string.find(entry.build, "dune") ~= nil then
    uses_dune = 1
  end
  local ip = "@IP@"
  if uses_dune == 1 then ip = "../../ip" end

  local vars = {}
  vars["name"] = pkg
  vars["jobs"] = "4"
  vars["make"] = "make"
  vars["prefix"] = ip
  vars["bin"] = ip .. "/bin"
  vars["lib"] = ip .. "/lib"
  vars["man"] = ip .. "/man"
  vars["dev"] = "false"
  -- opam variables that appear in %{...}% interpolations (not just filters); the
  -- DkML compiler is native. Mirrors the fenv bools used by eval_filter.
  vars["ocaml:native"] = "true"
  vars["ocaml:native-dynlink"] = "true"
  vars["ocaml:version"] = "4.14.3"
  -- opam <pkg>:installed variables: true for provided packages, this package,
  -- and everything in its dependency closure; interpolate defaults the rest to
  -- false (see interpolate).
  vars[pkg .. ":installed"] = "true"
  local pk = next(H.PROVIDED)
  while pk ~= nil do vars[pk .. ":installed"] = "true"; pk = next(H.PROVIDED, pk) end
  local ci3 = 1
  while closure[ci3] ~= nil do vars[closure[ci3] .. ":installed"] = "true"; ci3 = ci3 + 1 end

  -- The build wrapper stages the dependency prefix p/ with an absolute OCAMLPATH
  -- (derived from $PWD at runtime) so dune finds the staged dependency libraries
  -- by findlib META discovery. It is fetched once and reused by every command.
  local wrapperfetch = "$(get-asset CommonsBase_Dk.Dk0Build.Wrapper@" .. modversion .. " -p wrapper.sh -f build-wrapper.sh)"
  -- The Windows POSIX shell is MSYS2's dash (its runtime translates the unix-form
  -- PATH into Windows form for the native dune.exe/cl.exe children, and provides
  -- cygpath). MSYS2 ships only the Windows_x86_64 tree; a Windows_x86 host runs
  -- the same x86_64 tooling. Referenced only in Windows-gated commands, so it is
  -- never resolved on Unix slots.
  -- Reference dash.exe in place inside the extracted MSYS2 tree (not copied out
  -- on its own) so its adjacent msys-2.0.dll and friends load; extracting only
  -- dash.exe fails at startup with 0xC0000135 (DLL not found).
  local msys2dash = "$(get-object CommonsLang_OCaml.MSYS2@2026.6.11 -s Release.Windows_x86_64 -e '*' -d :)/usr/bin/dash.exe"

  -- The opam build/install fields are interpreted once PER ABI, because an
  -- os-conditional field ({os = "win32"}) yields different commands per OS. Each
  -- resulting argv is emitted as one command gated to that abi (Unix via
  -- /bin/sh, Windows via MSYS2 dash + MSVC); dk0 runs only the matching abi's
  -- commands. Build commands precede install commands within each abi.
  local ai = 1
  while H.ABIS[ai] ~= nil do
    local abi = H.ABIS[ai]
    fenv.strings["os"] = H.abi_os(abi)
    local babi = H.field_to_argvs(entry.build, fenv, vars, pkg)
    local iabi = H.field_to_argvs(entry.install, fenv, vars, pkg)
    -- No explicit install field: the package relies on opam processing the
    -- <pkg>.install file its build generates. A dune package uses `dune install`;
    -- a non-dune one (topkg-based) is handled by the wrapper's @INSTALL@ step,
    -- which copies the .install entries into ip/.
    if iabi[1] == nil and uses_dune == 1 then
      iabi = { { "dune", "install", "--prefix", ip, pkg } }
    elseif iabi[1] == nil then
      iabi = { { "@INSTALL@", pkg } }
    end
    local bi = 1
    while babi[bi] ~= nil do
      table.insert(commands, H.percommand_abi(coreutils, wrapperfetch, msys2dash, babi[bi], abi))
      bi = bi + 1
    end
    local ii = 1
    while iabi[ii] ~= nil do
      table.insert(commands, H.percommand_abi(coreutils, wrapperfetch, msys2dash, iabi[ii], abi))
      ii = ii + 1
    end
    ai = ai + 1
  end

  table.insert(commands, { sevenzz, "a", "-tzip", "${SLOT.request}/install.zip", "./ip/*" })

  -- Toolchain on PATH: the DkML compiler and Dune for every package; GNU make
  -- for the non-dune packages (configure/make/make install), whose opam fields
  -- invoke `make` directly.
  local envmods = {
    "<PATH=$(--path=absnative get-object CommonsLang_OCaml.DkML@4.14.3 -s ${SLOTNAME.request} -d : -e 'bin/*')${/}bin",
    "<PATH=$(--path=absnative get-object CommonsLang_OCaml.Dune@3.23.1 -s ${SLOTNAME.request} -d : -e 'bin/*')${/}bin"
  }
  if uses_dune == 0 then
    table.insert(envmods, "<PATH=$(--path=absnative get-object CommonsBase_GNU.Make@4.4.1 -s Release.execution_abi -d : -e 'bin/*')${/}bin")
  end

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
              envmods = envmods,
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
