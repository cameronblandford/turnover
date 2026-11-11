-- Prints Turnover's saved activity log and a short data summary.
-- Usage: lua5.1 tools/log.lua "<WoW>/_forever_/WTF/Account/<account>/SavedVariables/Turnover.lua" [lines]
-- The file is only written on /reload or logout.

local path, lines = arg[1], tonumber(arg[2]) or 100
assert(path, "usage: lua5.1 tools/log.lua <path to Turnover.lua> [lines]")
dofile(path)
local db = assert(TurnoverDB, "no TurnoverDB in that file")

local log = db.log or {}
for i = math.max(1, #log - lines + 1), #log do
  print(os.date("%H:%M:%S", log[i][1]) .. "  " .. log[i][2])
end

print()
for realm, items in pairs(db.realms or {}) do
  local n, units, secs = 0, 0, 0
  for _, rec in pairs(items) do
    n = n + 1
    for _, o in ipairs(rec.obs) do units, secs = units + o[3], math.max(secs, o[2] - o[1]) end
  end
  print(("%s: %d items, %d units sold seen, longest stretch watched %dm"):format(realm, n, units, math.floor(secs / 60)))
end
