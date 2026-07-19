-- ---------------------------------------------------------------------------
-- Localize the shared MlFront source into a content-addressed object.
-- ---------------------------------------------------------------------------
-- The dk0 packages (MlFront_*/DkZero_*/UnifiedScript_*) are not published as
-- per-package archives; they all build from one shared MlFront tree. That tree
-- is checked in raw: its .opam and dune-project files are dune-generated and so
-- gitignored, and opam cannot pin (nor dune build) it until they exist. The
-- `localize` step regenerates them -- ci/localize-pristine.sh stamps the version
-- into each <pkg>.opam.template -> <pkg>.opam and copies dune-project.template
-- -> dune-project. This rule runs that script over the raw source asset and
-- emits the localized tree as one output.zip object, which the generic build
-- rule CommonsLang_OCaml.Dk.OpamBuild.F_BuildLockedPackage stages (get-object,
-- via its localsrc= parameter) as the source for every local package. Localize
-- is pure text substitution (sh + awk/sed, no OCaml toolchain), so the object is
-- host-independent and is produced on whichever slot first requests it.
--
-- This lives in its own dk0-specific module (localizing the MlFront tree is not
-- a generic opam concern) so its output object CommonsBase_Dk.Dk0.MlFrontSource
-- is produced by a rule with a stable, minimal signature; the build rule only
-- consumes the object, never this rule.
local M = {
  id = "CommonsBase_Dk.Dk0Localize@2.4.2"
}

CommonsBase_Dk__Dk0Localize__2_4_2 = {}

CommonsBase_Dk__Dk0Localize__2_4_2.SLOTS = {
  "Release.Windows_x86_64", "Release.Windows_x86",
  "Release.Linux_x86_64", "Release.Linux_x86", "Release.Linux_arm64",
  "Release.Darwin_x86_64", "Release.Darwin_arm64"
}

rules = build.newrules(M)

-- Parameters:
--   modver=MODULE@VERSION      the output object
--                              (CommonsBase_Dk.Dk0.MlFrontSource@2.4.2)
--   rawmodver=MODULE@VERSION   bundle holding the raw source asset
--   rawassetpath=PATH          asset path of the raw source tarball (a .tgz)
function rules.F_LocalizeSource(command, request)
  local H = CommonsBase_Dk__Dk0Localize__2_4_2
  if command == "declareoutput" then
    local modver = assert(request.user.modver, "please provide `modver=MODULE@VERSION`")
    local rawmodver = assert(request.user.rawmodver, "please provide `rawmodver=MODULE@VERSION`")
    local rawassetpath = assert(request.user.rawassetpath, "please provide `rawassetpath=PATH`")
    return {
      declareoutput = {
        return_objects = {
          id = modver,
          slots = H.SLOTS,
          execution_slot = "Release.execution_abi"
        },
        input_assets = {
          { id = rawmodver, path = rawassetpath }
        }
      }
    }
  end
  if command ~= "submit" then return end

  local rawmodver = request.user.rawmodver
  local rawassetpath = request.user.rawassetpath
  -- The raw tarball extracts to a single top-level mlfront-<ver>/ directory,
  -- which is preserved into output.zip so the build wrapper (which descends into
  -- the sole extracted directory) finds the source root uniformly.
  local srcdir = "mlfront-2.4.2"

  local sevenzz = "$(get-object CommonsBase_Std.S7z@25.1.0 -s Release.execution_abi -e '*' -d :)/7zz.exe"
  local coreutils = "$(get-object CommonsBase_Std.Coreutils@0.8.0 -s ${SLOTNAME.Release.execution_abi} -m ./coreutils.exe -f coreutils.exe -e '*')"
  local msys2dash = "$(get-object CommonsLang_OCaml.MSYS2@2026.6.11 -s Release.Windows_x86_64 -e '*' -d :)/usr/bin/dash.exe"

  local rawfetch = "$(get-asset " .. rawmodver .. " -p " .. rawassetpath .. " -f mlfront-raw.tgz)"
  -- The localize step runs as a checked-in wrapper script (not an inline shell
  -- string: dk0 parses each argv token for ${...}/$(...) and rejects a bare $ or
  -- shell operators). The wrapper puts /usr/bin on PATH (for awk/sed on every
  -- platform; MSYS2 maps it to the dash tree on Windows) and runs the source's
  -- own ci/localize-pristine.sh from mlfront-2.4.2/.
  local localizefetch = "$(get-asset CommonsBase_Dk.Dk0Localize.Wrapper@2.4.2 -p assets/dk0/localize.sh -f localize.sh)"

  local commands = {}
  -- Decompress the .tgz to a .tar in the build root (7zz names it mlfront-raw.tar
  -- by suffix substitution), then extract its members preserving mlfront-<ver>/.
  table.insert(commands, { sevenzz, "x", "-y", "-o.", rawfetch })
  table.insert(commands, { sevenzz, "x", "-y", "-o.", "mlfront-raw.tar" })

  -- Run the localize wrapper under the per-OS shell (MSYS2 dash on Windows,
  -- /bin/sh on Unix). Each command is gated to one slot with the
  -- `env -u ${SLOT.Release.<slot>}` trick (dk0 drops a command whose referenced
  -- slot is not the one being built), so only the building slot's shell runs.
  local wins = { "Windows_x86_64", "Windows_x86" }
  local wi = 1
  while wins[wi] ~= nil do
    table.insert(commands, {
      coreutils, "env", "-u", "${SLOT.Release." .. wins[wi] .. "}", "--",
      msys2dash, localizefetch })
    wi = wi + 1
  end
  local unixs = { "Linux_x86_64", "Linux_x86", "Linux_arm64", "Darwin_x86_64", "Darwin_arm64" }
  local ui = 1
  while unixs[ui] ~= nil do
    table.insert(commands, {
      coreutils, "env", "-u", "${SLOT.Release." .. unixs[ui] .. "}", "--",
      "/bin/sh", localizefetch })
    ui = ui + 1
  end

  -- Package the localized tree (keeping the top-level directory) as output.zip.
  table.insert(commands, { sevenzz, "a", "-tzip", "${SLOT.request}/output.zip", "./" .. srcdir })

  return {
    submit = {
      values = {
        schema_version = { major = 1, minor = 0 },
        forms = {
          {
            id = request.submit.outputid,
            function_ = { commands = commands },
            outputs = {
              assets = { { slots = H.SLOTS, paths = { "output.zip" } } }
            }
          }
        }
      }
    }
  }
end

return M
