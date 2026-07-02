-- R1/R2 prototype: can one post-object instance depend on another and pull its
-- output via merge-object? Minimal, runs on the execution slot (no opam needed).
local M = {
  id = "CommonsBase_Dk.Proto@0.0.1"
}

CommonsBase_Dk__Proto__0_0_1 = {}

rules = build.newrules(M)

CommonsBase_Dk__Proto__0_0_1.slots = {
  "Release.Windows_x86", "Release.Windows_x86_64", "Release.Windows_arm64",
  "Release.Darwin_x86_64", "Release.Darwin_arm64",
  "Release.Linux_x86_64", "Release.Linux_arm64", "Release.Linux_x86"
}

-- F_Proto: produce an object named `modver` containing `<name>.txt`. If `dep` is
-- given (another F_Proto instance's module id), merge that dep into p/ and copy
-- its leaf.txt out as merged-leaf.txt -- proving post-object -> post-object.
function rules.F_Proto(command, request)
  local modver = assert(request.user.modver, "provide modver=MODULE@VERSION")
  local name = assert(request.user.name, "provide name=NAME")
  local dep = request.user.dep
  if command == "declareoutput" then
    local d = {
      return_objects = {
        id = modver,
        slots = CommonsBase_Dk__Proto__0_0_1.slots,
        execution_slot = "Release.execution_abi"
      }
    }
    if dep then
      d.input_objects = {
        {
          id = dep,
          slots = CommonsBase_Dk__Proto__0_0_1.slots,
          execution_slot = "Release.execution_abi"
        }
      }
    end
    return { declareoutput = d }
  elseif command == "submit" then
    local coreutils = "$(get-object CommonsBase_Std.Coreutils@0.6.0 -s ${SLOTNAME.Release.execution_abi} -m ./coreutils.exe -f coreutils.exe -e '*')"
    local commands = {}
    local paths = { name .. ".txt" }
    -- our own marker file
    table.insert(commands, { coreutils, "touch", "${SLOT.request}/" .. name .. ".txt" })
    local form = {
      id = request.submit.outputid,
      function_ = { commands = commands },
      outputs = {
        assets = {
          { slots = CommonsBase_Dk__Proto__0_0_1.slots, paths = paths }
        }
      }
    }
    if dep then
      -- merge-object is a precommand (like install-object), not a function command
      form.precommands = {
        private = {
          "merge-object " .. dep .. " -s ${SLOTNAME.request} -d p"
        }
      }
      table.insert(commands, { coreutils, "cp", "p/leaf.txt", "${SLOT.request}/merged-leaf.txt" })
      table.insert(paths, "merged-leaf.txt")
    end
    return {
      submit = {
        values = {
          schema_version = { major = 1, minor = 0 },
          forms = { form }
        }
      }
    }
  end
end

return M
