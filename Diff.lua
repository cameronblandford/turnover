-- Diff: compares two snapshots of one item's auction listings and works out
-- how much of the item sold in between.
--
-- The auction house never reports other players' sales, so sales are inferred
-- from listings that disappear. A listing can disappear for three reasons:
--   * it was bought            -> counted as sold
--   * it expired               -> ignored (only possible when little time was left)
--   * the seller cancelled it  -> ignored when the seller relists the same stack
-- When in doubt a listing is left out, so the result is a lower bound.
--
-- A listing is a table:
--   id          auction ID, when the client provides one (retail-style API)
--   owner       seller name, or nil if unknown
--   count       stack size / quantity
--   buyout      total buyout in copper (0 = bid only)
--   minBid      minimum bid in copper
--   timeLeftMin lower bound, in seconds, of the time the listing has left

local _, ns = ...

local Diff = {}
ns.Diff = Diff

local function signature(l)
  return l.count .. "|" .. (l.buyout or 0) .. "|" .. (l.minBid or 0)
end

local function allHaveIds(list)
  for i = 1, #list do
    if list[i].id == nil then return false end
  end
  return true
end

local function unitPrice(l)
  return (l.buyout or 0) / l.count
end

local function sameOwner(a, b)
  if a.owner and b.owner then return a.owner == b.owner end
  return true -- unknown owner: assume it could be the same seller
end

local function byCountThenPrice(a, b)
  if a.count ~= b.count then return a.count < b.count end
  if (a.buyout or 0) ~= (b.buyout or 0) then return (a.buyout or 0) < (b.buyout or 0) end
  return (a.timeLeftMin or 0) < (b.timeLeftMin or 0)
end

-- Retail-style listings carry auction IDs, so matching is exact and partial
-- purchases of a commodity show up as a smaller quantity on the same ID.
local function splitById(prev, cur, result)
  local gone, appeared, curById, seen = {}, {}, {}, {}
  for _, l in ipairs(cur) do curById[l.id] = l end
  for _, l in ipairs(prev) do
    seen[l.id] = true
    local now = curById[l.id]
    if not now then
      gone[#gone + 1] = l
    elseif now.count < l.count then
      local units = l.count - now.count
      result.soldUnits = result.soldUnits + units
      result.soldValue = result.soldValue + units * unitPrice(l)
    end
  end
  for _, l in ipairs(cur) do
    if not seen[l.id] then appeared[#appeared + 1] = l end
  end
  return gone, appeared
end

local function bucket(list)
  local b = {}
  for _, l in ipairs(list) do
    local k = signature(l)
    local group = b[k]
    if not group then group = {}; b[k] = group end
    group[#group + 1] = l
  end
  return b
end

-- Classic-style listings have no ID. Identical stacks (same size and prices)
-- are interchangeable, so compare how many of each there are. Owner is left
-- out of the signature because the client sometimes reports it late.
local function splitBySignature(prev, cur)
  local gone, appeared = {}, {}
  local before, after = bucket(prev), bucket(cur)
  for k, group in pairs(before) do
    local survivors = after[k] and #after[k] or 0
    if #group > survivors then
      -- Assume the stacks closest to expiry are the ones that went away;
      -- those are the ones most likely to have simply expired.
      table.sort(group, function(a, b) return (a.timeLeftMin or 0) < (b.timeLeftMin or 0) end)
      for i = 1, #group - survivors do gone[#gone + 1] = group[i] end
    end
  end
  for k, group in pairs(after) do
    local existed = before[k] and #before[k] or 0
    if #group > existed then
      table.sort(group, function(a, b) return (a.timeLeftMin or 0) > (b.timeLeftMin or 0) end)
      for i = 1, #group - existed do appeared[#appeared + 1] = group[i] end
    end
  end
  return gone, appeared
end

-- prev, cur: listing arrays. elapsed: seconds between the two snapshots.
function Diff.Compare(prev, cur, elapsed)
  local result = { soldUnits = 0, soldValue = 0, reposts = 0, ambiguous = 0, listedUnits = 0 }
  local gone, appeared
  if #prev > 0 and allHaveIds(prev) and allHaveIds(cur) then
    gone, appeared = splitById(prev, cur, result)
  else
    gone, appeared = splitBySignature(prev, cur)
  end
  table.sort(gone, byCountThenPrice)
  table.sort(appeared, byCountThenPrice)

  local used = {}
  local function claim(test)
    for i, a in ipairs(appeared) do
      if not used[i] and test(a) then
        used[i] = true
        return a
      end
    end
  end

  for _, g in ipairs(gone) do
    -- A smaller stack at the same unit price from the same seller: part of a
    -- commodity was bought (only happens without auction IDs).
    local rest = claim(function(a)
      return a.count < g.count and sameOwner(a, g)
        and (g.buyout or 0) > 0 and math.abs(unitPrice(a) - unitPrice(g)) < 1
    end)
    if rest then
      local units = g.count - rest.count
      result.soldUnits = result.soldUnits + units
      result.soldValue = result.soldValue + units * unitPrice(g)
    elseif claim(function(a) return a.count == g.count and sameOwner(a, g) end) then
      result.reposts = result.reposts + 1 -- cancelled and relisted
    elseif (g.buyout or 0) <= 0 or elapsed >= (g.timeLeftMin or 0) then
      result.ambiguous = result.ambiguous + 1 -- bid-only, or could have expired
    else
      result.soldUnits = result.soldUnits + g.count
      result.soldValue = result.soldValue + g.buyout
    end
  end

  for i, a in ipairs(appeared) do
    if not used[i] then result.listedUnits = result.listedUnits + a.count end
  end
  return result
end
