-- Scanner for clients with the classic auction API (QueryAuctionItems).
--
-- Two ways of getting snapshots:
--   * Active: while the auction house is open and the player is idle, run an
--     exact-name search for each watched item, page through it, and then
--     re-run the player's own last search so the Browse tab looks untouched.
--   * Passive: when the player's own search returns every result on one page
--     and covers a watched item, record it at no cost.

local _, ns = ...

local Legacy = { label = "classic auction API" }
ns.Scanners = ns.Scanners or {}
ns.Scanners.legacy = Legacy

local PAGE_SIZE = NUM_AUCTION_ITEMS_PER_PAGE or 50
-- Lower bound, in seconds, of each time-left band (1 Short, 2 Medium, 3 Long, 4 Very Long).
local BAND_MIN = { 0, 30 * 60, 2 * 3600, 8 * 3600 }
local READ_DELAY = 0.3 -- results keep arriving for a moment after the event
local MAX_READ_RETRIES = 5
local TIMEOUT = 10

local queue, job = {}, nil
local ours, restoring = false, false
local token, ourToken, userToken = 0, -1, -1
local userQuery = nil
local lastUserAt = -math.huge
local pendingRead = nil
local restorePending, ranThisBatch = false, false

function Legacy.Available()
  return type(QueryAuctionItems) == "function"
    and type(GetAuctionItemInfo) == "function"
    and type(GetNumAuctionItems) == "function"
end

local function canQuery()
  if not CanSendAuctionQuery then return true end
  return (CanSendAuctionQuery()) and true or false
end

local function readList()
  local n, total = GetNumAuctionItems("list")
  n = n or 0
  local rows, complete = {}, true
  for i = 1, n do
    local _, _, count, _, _, _, _, minBid, _, buyout, _, _, _, owner, ownerFull, _, itemID, hasAllInfo =
      GetAuctionItemInfo("list", i)
    if hasAllInfo == false then complete = false end
    local band = GetAuctionItemTimeLeft and GetAuctionItemTimeLeft("list", i)
    rows[i] = {
      itemID = itemID,
      owner = ownerFull or owner,
      count = count or 1,
      buyout = buyout or 0,
      minBid = minBid or 0,
      timeLeftMin = BAND_MIN[band] or 0,
    }
  end
  return rows, n, total or n, complete
end

local function listingsFor(itemID, rows, into)
  into = into or {}
  for _, r in ipairs(rows) do
    if r.itemID == itemID then
      into[#into + 1] = {
        owner = r.owner, count = r.count, buyout = r.buyout,
        minBid = r.minBid, timeLeftMin = r.timeLeftMin,
      }
    end
  end
  return into
end

local function nextJob()
  job = nil
  while #queue > 0 do
    local itemID = table.remove(queue, 1)
    local name = ns.ItemInfo(itemID)
    if name then
      job = { itemID = itemID, name = name, page = 0, listings = {}, needSend = true }
      ranThisBatch = true
      return
    end
    -- Item not in the client cache yet; ItemInfo asked for it, try next round.
  end
  if ranThisBatch and userQuery and (not AuctionFrame or AuctionFrame:IsShown()) then
    restorePending = true
  end
  ranThisBatch = false
end

local function handleOurPage(rows, total)
  listingsFor(job.itemID, rows, job.listings)
  if (job.page + 1) * PAGE_SIZE < total then
    job.page = job.page + 1
    job.needSend = true
    job.sentAt = nil
  else
    ns.OnSnapshot(job.itemID, job.listings, time())
    nextJob()
  end
end

-- The player's own search: usable only if it is complete (one page holds
-- every result) and nothing but the name could have filtered a watched item.
local function capturePassive(rows, n, total)
  local q = userQuery
  if not q or n < total then return end
  local text, minLevel, maxLevel, page, usable, rarity, getAll, exact, filterData = unpack(q, 1, q.n)
  if (tonumber(page) or 0) ~= 0 or getAll or usable or filterData ~= nil then return end
  if (tonumber(minLevel) or 0) > 0 or (tonumber(maxLevel) or 0) > 0 then return end
  text = type(text) == "string" and text:lower() or ""
  for itemID in pairs(ns.WatchList()) do
    local name, quality = ns.ItemInfo(itemID)
    if name then
      local lname = name:lower()
      local matches
      if exact then matches = lname == text else matches = lname:find(text, 1, true) ~= nil end
      if matches and (tonumber(rarity) or -1) <= (quality or 0) then
        ns.OnSnapshot(itemID, listingsFor(itemID, rows), time())
      end
    end
  end
end

local function processRead(t)
  local pr = pendingRead
  if pr.token ~= token then pendingRead = nil return end -- superseded by a newer search
  local rows, n, total, complete = readList()
  if not complete and pr.tries < MAX_READ_RETRIES then
    pr.tries = pr.tries + 1
    pr.at = t + READ_DELAY
    return
  end
  pendingRead = nil
  if pr.token == ourToken and job then
    handleOurPage(rows, total)
  elseif pr.token == userToken then
    capturePassive(rows, n, total)
  end
end

local function abort()
  job = nil
  wipe(queue)
  restorePending, ranThisBatch = false, false
end

function Legacy.Install()
  hooksecurefunc("QueryAuctionItems", function(...)
    token = token + 1
    if ours then ourToken = token return end
    userToken = token
    userQuery = { n = select("#", ...), ... }
    if restoring then return end
    lastUserAt = GetTime()
    if job or #queue > 0 then abort() end -- the player is searching; get out of the way
  end)
end

function Legacy.OnListUpdate()
  if not (pendingRead and pendingRead.token == token) then
    pendingRead = { token = token, at = GetTime() + READ_DELAY, tries = 0 }
  end
end

function Legacy.Tick(t)
  if pendingRead and t >= pendingRead.at then processRead(t) end
  if job then
    if job.needSend then
      if canQuery() then
        job.needSend, job.sentAt = false, t
        ours = true
        local ok = pcall(QueryAuctionItems, job.name, nil, nil, job.page, false, nil, false, true)
        ours = false
        if not ok then nextJob() end
      end
    elseif job.sentAt and t - job.sentAt > TIMEOUT then
      nextJob()
    end
  elseif restorePending and canQuery() then
    restorePending = false
    restoring = true
    pcall(QueryAuctionItems, unpack(userQuery, 1, userQuery.n))
    restoring = false
  end
end

function Legacy.Start(itemIDs)
  if job or #queue > 0 or restorePending then return false end
  for i, id in ipairs(itemIDs) do queue[i] = id end
  nextJob()
  return true
end

function Legacy.Stop()
  abort()
  pendingRead = nil
end

function Legacy.Busy()
  return job ~= nil or #queue > 0 or restorePending
end

function Legacy.LastUserActivity()
  return lastUserAt
end
