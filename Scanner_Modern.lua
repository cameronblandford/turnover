-- Scanner for clients with the retail auction API (C_AuctionHouse).
--
-- Active: while the player is idle at the auction house, search each watched
-- item and read the full result set. Passive: whenever full results for a
-- watched item arrive (including the player's own searches), record them.

local _, ns = ...

local Modern = { label = "retail auction API" }
ns.Scanners = ns.Scanners or {}
ns.Scanners.modern = Modern

-- Lower bound, in seconds, of Enum.AuctionHouseTimeLeftBand (Short .. VeryLong).
local BAND_MIN = { [0] = 0, [1] = 30 * 60, [2] = 2 * 3600, [3] = 12 * 3600 }
local TIMEOUT = 10
local PASSIVE_MIN_GAP = 5 -- seconds between passive snapshots of one item

local queue, job, ours = {}, nil, false
local lastUserAt = -math.huge
local lastRecorded = {}

local function AH() return C_AuctionHouse end

function Modern.Available()
  local ah = AH()
  return ah ~= nil and type(ah.SendSearchQuery) == "function" and type(ah.MakeItemKey) == "function"
end

local function ready()
  local ah = AH()
  return not ah.IsThrottledMessageSystemReady or ah.IsThrottledMessageSystemReady()
end

local function nextJob()
  job = nil
  local itemID = table.remove(queue, 1)
  if itemID then
    job = { itemID = itemID, itemKey = AH().MakeItemKey(itemID), needSend = true }
  end
end

local function record(itemID, listings, mine)
  local now = GetTime()
  if not mine and now - (lastRecorded[itemID] or -math.huge) < PASSIVE_MIN_GAP then return end
  lastRecorded[itemID] = now
  ns.OnSnapshot(itemID, listings, time(), mine and "scan" or "search")
end

local function itemName(itemID)
  return ns.ItemInfo(itemID) or ("item " .. itemID)
end

function Modern.Install()
  local ah = AH()
  hooksecurefunc(ah, "SendSearchQuery", function()
    if ours then return end
    lastUserAt = GetTime()
    if job or #queue > 0 then
      job = nil
      wipe(queue)
      ns.Log("Paused: you're searching. Will scan again once you've been idle a few seconds.")
    end
  end)
  if ah.SendBrowseQuery then
    hooksecurefunc(ah, "SendBrowseQuery", function() lastUserAt = GetTime() end)
  end
end

function Modern.OnCommodityResults(itemID)
  if not itemID or not ns.IsWatched(itemID) then return end
  local ah = AH()
  local mine = job ~= nil and job.itemID == itemID
  if not ah.HasFullCommoditySearchResults(itemID) then
    if mine then
      ah.RequestMoreCommoditySearchResults(itemID)
      job.sentAt = GetTime()
    end
    return
  end
  local out = {}
  for i = 1, ah.GetNumCommoditySearchResults(itemID) do
    local r = ah.GetCommoditySearchResultInfo(itemID, i)
    if r and (r.quantity or 0) > 0 then
      out[#out + 1] = {
        id = r.auctionID,
        owner = r.owners and r.owners[1],
        count = r.quantity,
        buyout = (r.unitPrice or 0) * r.quantity,
        timeLeftMin = r.timeLeftSeconds or 0,
      }
    end
  end
  record(itemID, out, mine)
  if mine then nextJob() end
end

function Modern.OnItemResults(itemKey)
  local itemID = itemKey and itemKey.itemID
  if not itemID or not ns.IsWatched(itemID) then return end
  local ah = AH()
  local mine = job ~= nil and job.itemID == itemID
  if not ah.HasFullItemSearchResults(itemKey) then
    if mine then
      ah.RequestMoreItemSearchResults(itemKey)
      job.sentAt = GetTime()
    end
    return
  end
  local out = {}
  for i = 1, ah.GetNumItemSearchResults(itemKey) do
    local r = ah.GetItemSearchResultInfo(itemKey, i)
    if r and (r.quantity or 0) > 0 then
      out[#out + 1] = {
        id = r.auctionID,
        owner = r.owners and r.owners[1],
        count = r.quantity,
        buyout = r.buyoutAmount or 0,
        minBid = r.minBid or 0,
        timeLeftMin = BAND_MIN[r.timeLeft] or 0,
      }
    end
  end
  record(itemID, out, mine)
  if mine then nextJob() end
end

function Modern.Tick(t)
  if not job then return end
  if job.needSend then
    if ready() then
      local sorts = {}
      if Enum and Enum.AuctionHouseSortOrder then
        sorts[1] = { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false }
      end
      job.needSend, job.sentAt = false, t
      ours = true
      local ok = pcall(AH().SendSearchQuery, job.itemKey, sorts, true)
      ours = false
      if not ok then
        ns.Log("%s: search failed, skipped.", itemName(job.itemID))
        nextJob()
      end
    end
  elseif t - job.sentAt > TIMEOUT then
    ns.Log("%s: no response from the auction house, skipped.", itemName(job.itemID))
    nextJob()
  end
end

function Modern.Start(itemIDs)
  if job or #queue > 0 then return false end
  for i, id in ipairs(itemIDs) do queue[i] = id end
  nextJob()
  return true
end

function Modern.Stop()
  job = nil
  wipe(queue)
end

function Modern.Busy()
  return job ~= nil or #queue > 0
end

function Modern.LastUserActivity()
  return lastUserAt
end
