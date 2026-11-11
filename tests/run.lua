-- Offline tests: `lua5.1 tests/run.lua` from the repo root.
local realPrint = print
-- Unit tests for Diff/Store, then end-to-end runs of both scanners against a
-- simulated auction house.

local failures, passed = 0, 0
local function check(cond, label)
  if cond then passed = passed + 1 else failures = failures + 1; realPrint("FAIL: " .. label) end
end
local function eq(a, b, label) check(a == b, ("%s (got %s, want %s)"):format(label, tostring(a), tostring(b))) end

---------------------------------------------------------------------------
-- Minimal WoW environment

local clock = 0
local after -- defined below; used by the C_Timer mock

-- A stand-in for any WoW widget: tracks scripts, events and shown state, and
-- accepts every other method call. Create* methods return more widgets.
local function widget()
  local w = { scripts = {}, events = {}, shown = true }
  local methods = {
    SetScript = function(self, n, fn) self.scripts[n] = fn end,
    HookScript = function(self, n, fn)
      local old = self.scripts[n]
      self.scripts[n] = function(...) if old then old(...) end fn(...) end
    end,
    RegisterEvent = function(self, e) self.events[e] = true end,
    Show = function(self) self.shown = true end,
    Hide = function(self) self.shown = false end,
    SetShown = function(self, v) self.shown = v and true or false end,
    IsShown = function(self) return self.shown end,
    GetHeight = function() return 400 end,
    GetFrameLevel = function() return 1 end,
    SetText = function(self, t) self.text = t end,
  }
  return setmetatable(w, { __index = function(_, k)
    if methods[k] then return methods[k] end
    if type(k) == "string" and k:match("^Create") then return function() return widget() end end
    return function() end
  end })
end
local chatLog = {}
local function saw(text)
  for _, line in ipairs(chatLog) do if line:find(text, 1, true) then return true end end
  return false
end
local frames = {}
local function newEnv()
  clock = 0
  frames = {}
  _G.GetTime = function() return clock end
  _G.time = function() return 1800000000 + math.floor(clock) end
  _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
  _G.unpack = unpack
  chatLog = {}
  _G.print = function(s) chatLog[#chatLog + 1] = s end
  _G.GetRealmName = function() return "Testrealm" end
  _G.UnitFactionGroup = function() return "Horde" end
  _G.SlashCmdList = {}
  _G.TurnoverDB = nil
  _G.TooltipDataProcessor, _G.Enum = nil, nil
  _G.QueryAuctionItems, _G.GetAuctionItemInfo, _G.GetNumAuctionItems = nil, nil, nil
  _G.C_AuctionHouse, _G.AuctionFrame = nil, nil
  local names = { [2770] = { "Copper Ore", 1 }, [2840] = { "Copper Bar", 1 }, [2589] = { "Linen Cloth", 1 } }
  _G.C_Item = {
    GetItemInfo = function(id)
      local n = names[id]
      if n then return n[1], "|Hitem:" .. id .. "|h", n[2] end
    end,
    RequestLoadItemDataByID = function() end,
  }
  _G.CreateFrame = function()
    local f = widget()
    frames[#frames + 1] = f
    return f
  end
  _G.GameTooltip, _G.ItemRefTooltip = widget(), widget()
  _G.AuctionHouseFrame = nil
  _G.C_Timer = { After = function(d, fn) after(d, fn) end }
  _G.ITEM_QUALITY_COLORS = { [1] = { r = 1, g = 1, b = 1 } }
  _G.PanelTemplates_SelectTab = function(t) t.selected = true end
  _G.PanelTemplates_DeselectTab = function(t) t.selected = false end
  _G.PanelTemplates_TabResize = function() end
  _G.hooksecurefunc = function(a, b, c)
    local tbl, name, hook = _G, a, b
    if type(a) == "table" then tbl, name, hook = a, b, c end
    local orig = tbl[name]
    tbl[name] = function(...) local r = { orig(...) }; hook(...); return unpack(r) end
  end
end

local function fire(event, ...)
  for _, f in ipairs(frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end

-- Advances the clock in 0.1s steps, running OnUpdate scripts and timers.
local timers = {}
local function advance(seconds)
  local target = clock + seconds
  while clock < target - 1e-9 do
    clock = clock + 0.1
    for i = #timers, 1, -1 do
      if timers[i].at <= clock then local fn = timers[i].fn; table.remove(timers, i); fn() end
    end
    for _, f in ipairs(frames) do
      if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.1) end
    end
  end
end
after = function(delay, fn) timers[#timers + 1] = { at = clock + delay, fn = fn } end

local function loadAddon()
  local ns = {}
  for _, file in ipairs({ "Diff.lua", "Store.lua", "Scanner_Legacy.lua", "Scanner_Modern.lua", "FullScan.lua",
                          "Core.lua", "Tooltip.lua", "UI.lua" }) do
    local chunk = assert(loadfile(file))
    chunk("Turnover", ns)
  end
  fire("ADDON_LOADED", "Turnover")
  fire("PLAYER_LOGIN")
  return ns
end

local function listing(count, buyout, owner, timeLeftMin, id)
  return { count = count, buyout = buyout, minBid = buyout - 1, owner = owner, timeLeftMin = timeLeftMin or 7200, id = id }
end

---------------------------------------------------------------------------
-- Diff

newEnv()
local ns = {}
assert(loadfile("Diff.lua"))("Turnover", ns)
assert(loadfile("Store.lua"))("Turnover", ns)
local Diff = ns.Diff

do
  local prev = { listing(20, 1000, "A"), listing(20, 1000, "B"), listing(10, 600, "C") }
  local cur = { listing(20, 1000, "B") }
  local r = Diff.Compare(prev, cur, 60)
  eq(r.soldUnits, 30, "bought stacks are counted")
  eq(r.soldValue, 1600, "sale value is the buyout")
end

do
  local prev = { listing(20, 1000, "A") }
  local cur = { listing(20, 900, "A") }
  local r = Diff.Compare(prev, cur, 60)
  eq(r.soldUnits, 0, "cancel + cheaper relist by same seller is not a sale")
  eq(r.reposts, 1, "repost detected")
end

do
  local prev = { listing(20, 1000, "A") }
  local cur = { listing(20, 900, "B") }
  local r = Diff.Compare(prev, cur, 60)
  eq(r.soldUnits, 20, "another seller listing the same size doesn't hide a sale")
  eq(r.listedUnits, 20, "new supply counted")
end

do
  local prev = { listing(20, 1000, "A", 0) }
  local r = Diff.Compare(prev, {}, 60)
  eq(r.soldUnits, 0, "listing in the Short band may have expired")
  eq(r.ambiguous, 1, "counted as ambiguous")
end

do
  local prev = { listing(20, 1000, "A", 1800) }
  local r = Diff.Compare(prev, {}, 2000)
  eq(r.soldUnits, 0, "gap longer than the time left: may have expired")
end

do
  local prev = { listing(20, 0, "A") }
  prev[1].minBid = 500
  local r = Diff.Compare(prev, {}, 60)
  eq(r.soldUnits, 0, "bid-only listings aren't counted")
end

do -- identical stacks: one of three gone
  local prev = { listing(5, 100, "A", 0), listing(5, 100, "A", 7200), listing(5, 100, "A", 28800) }
  local cur = { listing(5, 100, "A", 7200), listing(5, 100, "A", 28800) }
  local r = Diff.Compare(prev, cur, 60)
  eq(r.soldUnits, 0, "of identical stacks, the one nearest expiry is assumed gone")
end

do -- auction IDs: partial commodity purchase and full purchase
  local prev = { listing(200, 200 * 10, nil, 40000, 1), listing(50, 50 * 12, nil, 40000, 2) }
  local cur = { listing(120, 120 * 10, nil, 39940, 1) }
  local r = Diff.Compare(prev, cur, 60)
  eq(r.soldUnits, 130, "partial (80) + full (50) by auction ID")
  eq(r.soldValue, 80 * 10 + 50 * 12, "partial sale valued at unit price")
end

do -- no IDs: partial purchase of a commodity row
  local prev = { listing(200, 2000, nil, 40000) }
  local cur = { listing(150, 1500, nil, 40000) }
  local r = Diff.Compare(prev, cur, 60)
  eq(r.soldUnits, 50, "partial purchase without IDs")
end

---------------------------------------------------------------------------
-- Store

do
  local db = {}
  ns.Store.Init(db)
  local base = 1800000000 - (1800000000 % 3600)
  ns.Store.Record(db, "R", 1, { listing(20, 1000, "A"), listing(10, 500, "B") }, base, 900)
  ns.Store.Record(db, "R", 1, { listing(10, 500, "B") }, base + 600, 900)
  ns.Store.Record(db, "R", 1, {}, base + 1200, 900)
  local rec = ns.Store.Get(db, "R", 1)
  eq(#rec.obs, 1, "contiguous observations in one hour merge")
  local rate, secs, avg, units = ns.Store.Rate(rec, base + 1200, 86400)
  eq(units, 30, "units summed")
  eq(secs, 1200, "seconds observed")
  eq(rate, 90, "units per hour")
  eq(avg, 50, "average unit price")

  ns.Store.Record(db, "R", 1, { listing(5, 50, "C") }, base + 1200 + 3600, 900)
  eq(#rec.obs, 1, "gap over maxGap adds no observation")
  eq(rec.supply, 5, "supply tracks the latest snapshot")
end

---------------------------------------------------------------------------
-- Classic scanner against a simulated auction house

local function setupLegacyAH(listings)
  local ah = { listings = listings, current = {}, total = 0, lastQueryAt = -10, queries = {} }
  local names = { [2770] = "Copper Ore", [2840] = "Copper Bar" }
  _G.NUM_AUCTION_ITEMS_PER_PAGE = 50
  _G.CanSendAuctionQuery = function() return clock - ah.lastQueryAt >= 0.5 end
  _G.QueryAuctionItems = function(text, _, _, page, _, _, _, exact)
    ah.lastQueryAt = clock
    ah.queries[#ah.queries + 1] = { text = text, page = page, exact = exact }
    local matched = {}
    for _, l in ipairs(ah.listings) do
      local n = names[l.itemID]:lower()
      local t = (text or ""):lower()
      if (exact and n == t) or (not exact and n:find(t, 1, true)) then matched[#matched + 1] = l end
    end
    ah.total = #matched
    ah.current = {}
    for i = page * 50 + 1, math.min(#matched, page * 50 + 50) do ah.current[#ah.current + 1] = matched[i] end
    after(0.2, function() fire("AUCTION_ITEM_LIST_UPDATE") end)
  end
  _G.GetNumAuctionItems = function() return #ah.current, ah.total end
  _G.GetAuctionItemInfo = function(_, i)
    local l = ah.current[i]
    return names[l.itemID], nil, l.count, 1, true, 0, nil, l.buyout - 1, 1, l.buyout, 0, nil, nil,
      l.owner, l.owner, 0, l.itemID, true
  end
  _G.GetAuctionItemTimeLeft = function(_, i) return ah.current[i].band end
  _G.AuctionFrame = { IsShown = function() return true end }
  return ah
end

do
  newEnv()
  timers = {}
  local listings = {}
  for i = 1, 60 do
    listings[#listings + 1] = { itemID = 2770, count = 20, buyout = 2000 + i, owner = "Seller" .. (i % 7), band = 3 }
  end
  for i = 1, 5 do
    listings[#listings + 1] = { itemID = 2840, count = 10, buyout = 4000 + i, owner = "Smith", band = 4 }
  end
  local ah = setupLegacyAH(listings)
  local addon = loadAddon()
  eq(addon.Scanners.legacy.Available(), true, "classic API detected")

  fire("AUCTION_HOUSE_SHOW")
  advance(10)
  local rec = addon.Store.Get(TurnoverDB, "Testrealm-Horde", 2770)
  check(rec and rec.last, "first scan stored a Copper Ore snapshot")
  eq(rec and #rec.last.listings, 60, "both result pages were read")
  local bars = addon.Store.Get(TurnoverDB, "Testrealm-Horde", 2840)
  eq(bars and #bars.last.listings, 5, "Copper Bar scanned too")
  check(saw("Auction house open. Scanning while you're idle: watchlist every 60s."), "chat: AH open")
  check(saw("Scanning 2 items."), "chat: scan start")
  check(saw("Copper Ore: 1200 listed in 60 auctions, first look"), "chat: first look")

  -- Between scans: 5 ore stacks bought, 1 cancelled and relisted cheaper.
  for _ = 1, 5 do table.remove(ah.listings, 1) end
  local moved = table.remove(ah.listings, 1)
  ah.listings[#ah.listings + 1] = { itemID = 2770, count = 20, buyout = moved.buyout - 50, owner = moved.owner, band = 4 }
  advance(60)
  local rate, secs, _, units = addon.Store.Rate(rec, time(), 86400)
  eq(units, 100, "5 bought stacks of 20 counted, the repost ignored")
  check(secs >= 55 and secs <= 65, "observed about one interval")
  check(rate > 0, "rate is positive")
  check(saw("Copper Ore: 1100 listed in 55 auctions, 100 sold, 1 relisted"), "chat: sales and relist")
  check(saw("Copper Bar: 50 listed in 5 auctions, none sold"), "chat: nothing sold")

  -- Player searches while a scan is underway: the scan backs off.
  advance(55)
  while not addon.Scanners.legacy.Busy() do advance(0.1) end
  QueryAuctionItems("copper", nil, nil, 0, false, nil, false, false)
  eq(addon.Scanners.legacy.Busy(), false, "scan aborted when the player searches")
  check(saw("Paused: you're searching."), "chat: pause")
  advance(0.5)
  -- 'copper' returns 59 ore + 5 bars = 64 > one page: not complete, no passive snapshot.
  local before = rec.last.t
  advance(1)
  eq(rec.last.t, before, "incomplete player search is not recorded")

  -- A complete player search is recorded passively.
  QueryAuctionItems("copper bar", nil, nil, 0, false, nil, false, false)
  advance(1)
  eq(bars.last.t, time(), "complete player search recorded passively")
  check(saw("Copper Bar: 50 listed in 5 auctions, none sold (from your search)"), "chat: passive")

  -- The next automatic scan waits for the player to be idle, then restores their search.
  local n = #ah.queries
  advance(5)
  eq(#ah.queries, n, "no scan while the player was recently active")
  advance(70)
  local last = ah.queries[#ah.queries]
  eq(last.text, "copper bar", "player's last search re-run after scanning")
  check(saw("Put your last search back."), "chat: restore")

  -- Enough data for the tooltip after ~10 minutes of watching.
  advance(600)
  check(addon.TooltipText(2770) ~= nil, "tooltip line shows after 10 minutes")
  check(addon.TooltipText(2840) ~= nil, "tooltip line for bars too")

  fire("AUCTION_HOUSE_CLOSED")
  eq(addon.Scanners.legacy.Busy(), false, "closing the AH stops scanning")

  -- Slash commands run without error.
  for _, cmd in ipairs({ "", "help", "watch 2589", "unwatch 2589", "auto off", "auto on", "interval 5",
                         "reset 2840", "reset all", "watch nonsense", "scan", "chat on" }) do
    local ok, err = pcall(SlashCmdList.TURNOVER, cmd)
    check(ok, "slash '" .. cmd .. "': " .. tostring(err))
  end
  eq(TurnoverDB.settings.interval, 20, "interval has a floor")
  SlashCmdList.TURNOVER("chat off")
  chatLog = {}
  addon.Log("should not appear")
  eq(#chatLog, 0, "chat off silences the activity log")
  eq(TurnoverDB.log[#TurnoverDB.log][2], "should not appear", "log is saved even with chat off")
  check(#TurnoverDB.log > 10, "scan activity saved to the log")
  for i = 1, 600 do addon.Log("line %d", i) end
  eq(#TurnoverDB.log, 500, "saved log keeps the last 500 lines")
  eq(TurnoverDB.log[500][2], "line 600", "newest line last")
end

---------------------------------------------------------------------------
-- Retail scanner against a simulated commodity auction house

do
  newEnv()
  timers = {}
  local rows = {
    { auctionID = 1, quantity = 200, unitPrice = 10, timeLeftSeconds = 40000 },
    { auctionID = 2, quantity = 100, unitPrice = 11, timeLeftSeconds = 40000 },
  }
  local userSearches = 0
  _G.Enum = { AuctionHouseSortOrder = { Price = 0 } }
  _G.C_AuctionHouse = {
    MakeItemKey = function(id) return { itemID = id } end,
    IsThrottledMessageSystemReady = function() return true end,
    SendSearchQuery = function(itemKey)
      userSearches = userSearches + 1
      if itemKey.itemID == 2770 then
        after(0.2, function() fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2770) end)
      else
        after(0.2, function() fire("ITEM_SEARCH_RESULTS_UPDATED", itemKey) end)
      end
    end,
    HasFullCommoditySearchResults = function() return true end,
    GetNumCommoditySearchResults = function() return #rows end,
    GetCommoditySearchResultInfo = function(_, i) return rows[i] end,
    HasFullItemSearchResults = function() return true end,
    GetNumItemSearchResults = function() return 0 end,
    GetItemSearchResultInfo = function() end,
  }
  local addon = loadAddon()
  eq(addon.Scanners.legacy.Available(), false, "no classic API")
  eq(addon.Scanners.modern.Available(), true, "retail API detected")
  fire("AUCTION_HOUSE_SHOW")
  advance(5)
  local rec = addon.Store.Get(TurnoverDB, "Testrealm-Horde", 2770)
  eq(rec and #rec.last.listings, 2, "commodity snapshot stored")

  rows[1].quantity = 150 -- 50 bought
  table.remove(rows, 2)  -- 100 bought
  advance(60)
  local _, _, avg, units = addon.Store.Rate(rec, time(), 86400)
  eq(units, 150, "partial and full commodity purchases counted")
  check(avg and math.abs(avg - (50 * 10 + 100 * 11) / 150) < 1e-6, "average unit price")
  check(userSearches >= 4, "both watched items searched each round")
end

---------------------------------------------------------------------------
-- Retail full scans (ReplicateItems)

do
  newEnv()
  timers = {}
  local search = { -- what the per-item commodity search returns for Copper Ore
    { auctionID = 1, quantity = 200, unitPrice = 10, timeLeftSeconds = 40000 },
    { auctionID = 2, quantity = 100, unitPrice = 11, timeLeftSeconds = 40000 },
  }
  -- The replicate list reports commodity buyouts per unit; Turnover must notice.
  local rep = {
    { itemID = 2770, count = 200, buyout = 10 },
    { itemID = 2770, count = 100, buyout = 11 },
  }
  for i = 1, 5 do rep[#rep + 1] = { itemID = 2589, count = 5, buyout = 20 + i } end
  local replicateCalls, noReply = 0, false
  _G.Enum = { AuctionHouseSortOrder = { Price = 0 } }
  _G.C_AuctionHouse = {
    MakeItemKey = function(id) return { itemID = id } end,
    IsThrottledMessageSystemReady = function() return true end,
    SendSearchQuery = function(itemKey)
      if itemKey.itemID == 2770 then
        after(0.2, function() fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2770) end)
      else
        after(0.2, function() fire("ITEM_SEARCH_RESULTS_UPDATED", itemKey) end)
      end
    end,
    HasFullCommoditySearchResults = function() return true end,
    GetNumCommoditySearchResults = function() return #search end,
    GetCommoditySearchResultInfo = function(_, i) return search[i] end,
    HasFullItemSearchResults = function() return true end,
    GetNumItemSearchResults = function() return 0 end,
    GetItemSearchResultInfo = function() end,
    ReplicateItems = function()
      replicateCalls = replicateCalls + 1
      if not noReply then after(2, function() fire("REPLICATE_ITEM_LIST_UPDATE") end) end
    end,
    GetNumReplicateItems = function() return #rep end,
    GetReplicateItemInfo = function(i)
      local r = rep[i + 1]
      if not r then return end
      return "x", nil, r.count, 1, true, 0, nil, r.buyout, 1, r.buyout, 0, nil, nil, nil, nil, 0, r.itemID, true
    end,
    GetReplicateItemTimeLeft = function() return 3 end,
  }
  _G.AuctionHouseFrame = widget()
  AuctionHouseFrame.Tabs = { widget(), widget(), widget() }
  local addon = loadAddon()
  eq(addon.FullScan.Available(), true, "full-scan API detected")
  eq(TurnoverDB.settings.fullInterval, 60, "full scans default to every minute")
  SlashCmdList.TURNOVER("full 300")
  fire("AUCTION_HOUSE_SHOW")
  check(saw("full scan every 5m, watchlist every 60s"), "chat: AH open mentions full scan")
  advance(20)
  eq(replicateCalls, 1, "one full scan after opening")
  check(saw("Full scan started."), "chat: full scan started")
  check(saw("Full scan: 7 auctions of 2 items in 2s. First full scan"), "chat: first full scan summary")
  eq(TurnoverDB.settings.fullPricing, "unit", "per-unit replicate buyouts detected against the watchlist scan")
  local linen = addon.Store.Get(TurnoverDB, "Testrealm-Horde#full", 2589)
  eq(linen and #linen.last.listings, 5, "unwatched item stored from the full scan")
  eq(linen and linen.last.listings[1].buyout % 5, 0, "buyout converted to per auction")

  -- Two Linen auctions bought before the next full scan.
  table.remove(rep, 3); table.remove(rep, 3)
  advance(300)
  eq(replicateCalls, 2, "second full scan five minutes later")
  check(saw("10 units sold across 1 item since the last full scan."), "chat: full scan sales")
  local s = addon.Summary(2589)
  check(s and s.fromFull and s.units == 10, "unwatched item's rate comes from full scans")
  local w = addon.Summary(2770)
  check(w and not w.fromFull, "watched item's rate comes from the watchlist scans")

  -- The server ignores a full scan request.
  noReply = true
  advance(300 + 61)
  check(saw("Full scan got no reply;"), "chat: no reply")
  noReply = false

  -- Another addon (or the player) starts a full scan: its results are used.
  C_AuctionHouse.ReplicateItems()
  advance(3)
  check(saw("Full scan (started elsewhere): 5 auctions of 2 items."), "chat: someone else's full scan")

  -- Turning full scans off stops them.
  SlashCmdList.TURNOVER("full off")
  local n = replicateCalls
  advance(700)
  eq(replicateCalls, n, "full off stops full scans")
  SlashCmdList.TURNOVER("full 10")
  eq(TurnoverDB.settings.fullInterval, 60, "full interval has a floor")

  -- Top movers: ranking query.
  local movers = addon.TopMovers(3600)
  eq(#movers, 1, "only items with sales and 10+ minutes of data are ranked")
  eq(movers[1] and movers[1].id, 2589, "Linen Cloth ranked")
  check(movers[1] and movers[1].gold > 0 and movers[1].fromFull, "value/hr from full-scan data")
  eq(#addon.TopMovers(1), 0, "nothing in a 1-second window")

  -- Top movers: the tab and panel.
  local UI = addon.UI
  check(UI.tab ~= nil and UI.panel ~= nil, "tab and panel built when the AH opened")
  eq(UI.panel:IsShown(), false, "panel starts hidden")
  UI.tab.scripts.OnClick(UI.tab)
  eq(UI.panel:IsShown(), true, "clicking the tab shows the panel")
  eq(UI.tab.selected, true, "our tab drawn as selected")
  eq(AuctionHouseFrame.Tabs[1].selected, false, "Blizzard tabs drawn as deselected")
  eq(#UI.Data(), 1, "panel lists the ranked item")
  eq(UI.rows[1] and UI.rows[1].itemID, 2589, "first row is Linen Cloth")
  eq(UI.rows[2] and UI.rows[2]:IsShown(), false, "other rows hidden")
  UI.rows[1].scripts.OnEnter(UI.rows[1])
  UI.rows[1].scripts.OnLeave(UI.rows[1])
  UI.panel.scripts.OnMouseWheel(UI.panel, -1)
  addon.OnDataChanged()
  advance(1)
  eq(UI.rows[1].itemID, 2589, "refresh after new data keeps the row")
  TurnoverDB.settings.topWindow = 4
  UI.Refresh()
  eq(#UI.Data(), 1, "7-day window")
  AuctionHouseFrame.Tabs[1].scripts.OnClick(AuctionHouseFrame.Tabs[1])
  eq(UI.panel:IsShown(), false, "a Blizzard tab hides the panel")
  UI.tab.scripts.OnClick(UI.tab)
  fire("AUCTION_HOUSE_CLOSED")
  eq(UI.panel:IsShown(), false, "closing the auction house hides the panel")
end

---------------------------------------------------------------------------
-- Saved settings from 0.2 (full scan every 300s) move to every minute

do
  newEnv()
  timers = {}
  _G.TurnoverDB = { settings = { fullInterval = 300 }, watch = { [2770] = true }, realms = {} }
  loadAddon()
  eq(TurnoverDB.settings.fullInterval, 60, "old 5-minute default migrated to 60s")
  eq(TurnoverDB.settingsVersion, 2, "settings version recorded")
  TurnoverDB.settings.fullInterval = 300 -- a deliberate choice made after migrating
  fire("ADDON_LOADED", "Turnover")
  eq(TurnoverDB.settings.fullInterval, 300, "a 300s interval chosen later is kept")

  newEnv()
  timers = {}
  _G.TurnoverDB = { settings = { fullInterval = 120 }, watch = {}, realms = {} }
  loadAddon()
  eq(TurnoverDB.settings.fullInterval, 120, "custom intervals are left alone")
end

---------------------------------------------------------------------------
-- The auction window loads after AUCTION_HOUSE_SHOW: the tab still appears

do
  newEnv()
  timers = {}
  _G.C_AuctionHouse = { MakeItemKey = function(id) return { itemID = id } end, SendSearchQuery = function() end }
  local addon = loadAddon()
  SlashCmdList.TURNOVER("top")
  check(saw("Can't show Top movers: the auction house window hasn't loaded"), "/turnover top explains a missing window")
  fire("AUCTION_HOUSE_SHOW") -- window not loaded yet
  eq(addon.UI.panel, nil, "no tab without the window")
  _G.AuctionHouseFrame = widget()
  AuctionHouseFrame.Tabs = { widget(), widget(), widget() }
  advance(0.2) -- next-frame retry
  check(addon.UI.panel ~= nil, "tab built once the window exists")
  check(saw("Added the Top movers tab to the auction house."), "chat: tab added")
  SlashCmdList.TURNOVER("top")
  eq(addon.UI.panel:IsShown(), true, "/turnover top opens the panel")

  newEnv()
  timers = {}
  _G.C_AuctionHouse = { MakeItemKey = function(id) return { itemID = id } end, SendSearchQuery = function() end }
  local addon2 = loadAddon()
  _G.AuctionHouseFrame = widget()
  fire("ADDON_LOADED", "Blizzard_AuctionHouseUI")
  check(addon2.UI.panel ~= nil, "tab built when Blizzard_AuctionHouseUI loads (no Tabs array)")

  -- A failure while building is reported, not silent.
  newEnv()
  timers = {}
  local addon3 = loadAddon()
  _G.AuctionHouseFrame = widget()
  AuctionHouseFrame.GetFrameLevel = function() error("boom") end
  fire("ADDON_LOADED", "Blizzard_AuctionHouseUI")
  check(saw("Couldn't add the Top movers tab:"), "build failure reported in chat")
  SlashCmdList.TURNOVER("top")
  check(saw("Can't show Top movers: the tab failed to build:"), "/turnover top repeats the build error")
end

---------------------------------------------------------------------------
-- Server allows one full scan per 15 minutes: back off, keep the watchlist
-- going, and still count sales across the long gap

do
  newEnv()
  timers = {}
  local rep = {}
  for i = 1, 6 do rep[#rep + 1] = { itemID = 2589, count = 5, buyout = 100 + i } end
  local calls, answered, lastOk, searches = 0, 0, -math.huge, 0
  _G.Enum = { AuctionHouseSortOrder = { Price = 0 } }
  _G.C_AuctionHouse = {
    MakeItemKey = function(id) return { itemID = id } end,
    IsThrottledMessageSystemReady = function() return true end,
    SendSearchQuery = function()
      searches = searches + 1
      after(0.2, function() fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2770) end)
    end,
    HasFullCommoditySearchResults = function() return true end,
    GetNumCommoditySearchResults = function() return 1 end,
    GetCommoditySearchResultInfo = function() return { auctionID = 9, quantity = 50, unitPrice = 7, timeLeftSeconds = 80000 } end,
    ReplicateItems = function()
      calls = calls + 1
      if clock - lastOk >= 900 then
        lastOk = clock
        answered = answered + 1
        after(2, function() fire("REPLICATE_ITEM_LIST_UPDATE") end)
      end
    end,
    GetNumReplicateItems = function() return #rep end,
    GetReplicateItemInfo = function(i)
      local r = rep[i + 1]
      return "x", nil, r.count, 1, true, 0, nil, r.buyout, 1, r.buyout, 0, nil, nil, nil, nil, 0, r.itemID, true
    end,
    GetReplicateItemTimeLeft = function() return 3 end,
  }
  local addon = loadAddon()
  fire("AUCTION_HOUSE_SHOW")
  advance(30)
  eq(answered, 1, "first full scan answered")
  local searchesBefore = searches
  table.remove(rep, 1); table.remove(rep, 1) -- 10 Linen Cloth bought
  advance(20 * 60)
  check(saw("Full scan got no reply; the server probably limits how often full scans can run."), "chat: first refusal explained")
  check(saw("Full scan still refused. Next try in"), "chat: later refusals are short")
  check(calls <= 7, ("backed off instead of asking every minute (%d requests in 20m)"):format(calls))
  check(answered >= 2, "a later full scan got through")
  check(saw("Full scans are working again: this one came"), "chat: recovery noted")
  check(saw("Spacing them at least"), "chat: learned spacing announced")
  check((TurnoverDB.settings.fullRefusedGap or 0) >= 500, "refused gap remembered")
  local callsAfter = calls
  advance(5 * 60)
  eq(calls, callsAfter, "no requests sooner than the refused gap after recovering")
  check(searches - searchesBefore >= 15, "watchlist kept scanning while full scans were refused")
  local s = addon.Summary(2589)
  eq(s and s.units, 10, "sales across a 15+ minute gap between full scans are counted")
end

realPrint(("%d passed, %d failed"):format(passed, failures))
os.exit(failures == 0 and 0 or 1)
