-- FullScan: periodic snapshot of the whole auction house (retail API,
-- C_AuctionHouse.ReplicateItems), giving rough sell rates for every item.
--
-- Full-scan snapshots are kept apart from the per-minute watchlist scans
-- (under "<realm>#full"): they come every few minutes rather than every
-- minute, and they have no auction IDs, so the two kinds don't mix.
--
-- Results are read a chunk per frame so a big auction house doesn't hitch.
-- If the player or another addon starts a full scan, its results are used too.

local _, ns = ...

local Full = {}
ns.FullScan = Full

local BAND_MIN = { [0] = 0, [1] = 30 * 60, [2] = 2 * 3600, [3] = 12 * 3600 }
local ROWS_PER_TICK = 2000
local WAIT_TIMEOUT = 60

local state = "idle" -- "idle" | "waiting" | "reading"
local ours = false
local source, sentAt, index, total, byItem = nil, 0, 0, 0, nil

local function AH() return C_AuctionHouse end

function Full.Available()
  local ah = AH()
  return ah ~= nil and type(ah.ReplicateItems) == "function"
    and type(ah.GetNumReplicateItems) == "function" and type(ah.GetReplicateItemInfo) == "function"
end

function Full.Install()
  hooksecurefunc(AH(), "ReplicateItems", function()
    if ours then return end
    -- Someone else asked for a full scan; its results replace ours, so read those.
    state, source, sentAt = "waiting", "other", GetTime()
  end)
end

function Full.Busy() return state ~= "idle" end

function Full.Start(t)
  if state ~= "idle" then return false end
  ours = true
  local ok = pcall(AH().ReplicateItems)
  ours = false
  if not ok then return false end
  state, source, sentAt = "waiting", "scan", t
  return true
end

function Full.Stop()
  state, byItem = "idle", nil
end

function Full.OnReplicateUpdate()
  if state ~= "waiting" then return end -- later events while reading are item info arriving
  state, index, total, byItem = "reading", 0, AH().GetNumReplicateItems() or 0, {}
end

local function minUnitPrice(listings)
  local best
  for _, l in ipairs(listings) do
    if (l.buyout or 0) > 0 and l.count > 0 then
      local u = l.buyout / l.count
      if not best or u < best then best = u end
    end
  end
  return best
end

-- The replicate API's buyout may be per unit for commodities rather than per
-- auction. Work out which, once, by comparing against a recent watchlist
-- scan (whose prices are known to be right).
local function calibrate(t)
  local s = ns.Settings()
  if s.fullPricing then return end
  for itemID, listings in pairs(byItem) do
    local rec = ns.IsWatched(itemID) and ns.Store.Get(ns.DB(), ns.RealmKey(), itemID)
    if rec and rec.last and t - rec.last.t <= 15 * 60 then
      local watched, full = minUnitPrice(rec.last.listings), minUnitPrice(listings)
      if watched and full and watched > 0 then
        s.fullPricing = (full / watched < 0.5) and "unit" or "total"
        return
      end
    end
  end
end

local function finish(t)
  local now = time()
  calibrate(now)
  if ns.Settings().fullPricing == "unit" then
    for _, listings in pairs(byItem) do
      for _, l in ipairs(listings) do l.buyout = l.buyout * l.count end
    end
  end

  local items, auctions, soldUnits, soldItems, compared = 0, 0, 0, 0, false
  local function record(itemID, listings)
    local diff = ns.RecordFull(itemID, listings, now)
    if diff then
      compared = true
      if diff.soldUnits > 0 then
        soldUnits = soldUnits + diff.soldUnits
        soldItems = soldItems + 1
      end
    end
  end
  for itemID, listings in pairs(byItem) do
    items = items + 1
    auctions = auctions + #listings
    record(itemID, listings)
  end
  for _, itemID in ipairs(ns.FullItemIDs()) do
    if not byItem[itemID] then record(itemID, {}) end -- sold out or no longer listed
  end

  local took = source == "scan" and (" in %ds"):format(math.floor(t - sentAt + 0.5)) or ""
  local result
  if compared then
    result = ("%d unit%s sold across %d item%s since the last full scan."):format(
      soldUnits, soldUnits == 1 and "" or "s", soldItems, soldItems == 1 and "" or "s")
  else
    result = "First full scan (or the last one was too long ago); rates start next time."
  end
  ns.Log("Full scan%s: %d auctions of %d items%s. %s",
    source == "other" and " (started elsewhere)" or "", auctions, items, took, result)
  state, byItem = "idle", nil
  ns.DataChanged()
end

function Full.Tick(t)
  if state == "waiting" then
    if t - sentAt > WAIT_TIMEOUT then
      state = "idle"
      if source == "scan" then
        ns.Log("Full scan got no reply. The server may limit how often full scans can run; will retry.")
      end
    end
    return
  end
  if state ~= "reading" then return end
  local ah = AH()
  local last = math.min(total, index + ROWS_PER_TICK)
  for i = index, last - 1 do -- replicate indices start at 0
    local _, _, count, _, _, _, _, minBid, _, buyout, _, _, _, owner, ownerFull, _, itemID =
      ah.GetReplicateItemInfo(i)
    if itemID and (count or 0) > 0 then
      local band = ah.GetReplicateItemTimeLeft and ah.GetReplicateItemTimeLeft(i)
      local listings = byItem[itemID]
      if not listings then listings = {}; byItem[itemID] = listings end
      listings[#listings + 1] = {
        owner = ownerFull or owner, count = count, buyout = buyout or 0,
        minBid = minBid or 0, timeLeftMin = BAND_MIN[band] or 0,
      }
    end
  end
  index = last
  if index >= total then finish(t) end
end
