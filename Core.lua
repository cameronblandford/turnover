-- Core: saved data, scan scheduling, slash commands.

local addonName, ns = ...

local DEFAULT_SETTINGS = {
  auto = true,         -- scan the watchlist while the auction house is open
  interval = 60,       -- seconds between scans
  idle = 8,            -- seconds the player must be idle before a scan starts
  maxGap = 15 * 60,    -- longest gap between snapshots that still counts
  window = 7 * 86400,  -- how far back the rate looks
  chat = true,         -- print what the addon is doing to the chat log
  full = true,         -- periodically scan the whole auction house
  fullInterval = 60,   -- seconds between full scans
  fullMaxGap = 3600,   -- full scans can be further apart and still count
}
local MIN_FULL_INTERVAL = 60
local DEFAULT_WATCH = { 2770, 2840 } -- Copper Ore, Copper Bar
local MIN_INTERVAL = 20
local FIRST_SCAN_DELAY = 3
local TICK = 0.1

local db, scanner, full
local nextScanAt, nextFullAt, acc = 0, 0, 0
local frame = CreateFrame("Frame")

local function say(fmt, ...)
  print("|cff8ab4f8Turnover|r " .. fmt:format(...))
end

-- Activity log: printed in grey when chat logging is on, and always kept in
-- TurnoverDB.log (the last LOG_KEEP lines) so it can be read after a /reload.
local LOG_KEEP = 500
function ns.Log(fmt, ...)
  if not db then return end
  local text = fmt:format(...)
  local log = db.log
  log[#log + 1] = { time(), text }
  while #log > LOG_KEEP do table.remove(log, 1) end
  if db.settings.chat then
    print("|cff8ab4f8Turnover|r |cffa0a0a0" .. text .. "|r")
  end
end

---------------------------------------------------------------------------
-- Shared helpers

function ns.ItemInfo(itemID)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not get then return nil end
  local name, _, quality = get(itemID)
  if not name and C_Item and C_Item.RequestLoadItemDataByID and type(itemID) == "number" then
    C_Item.RequestLoadItemDataByID(itemID)
  end
  return name, quality
end

function ns.RealmKey()
  local realm = GetRealmName and GetRealmName() or "?"
  local faction = UnitFactionGroup and UnitFactionGroup("player") or "?"
  return realm .. "-" .. faction
end

function ns.FullRealmKey() return ns.RealmKey() .. "#full" end
function ns.DB() return db end
function ns.Settings() return db.settings end
function ns.WatchList() return db and db.watch or {} end
function ns.IsWatched(itemID) return db ~= nil and db.watch[itemID] == true end

local function describe(itemID, listings, diff, reason, source)
  local units = 0
  for _, l in ipairs(listings) do units = units + l.count end
  local parts = { ("%s: %d listed in %d auction%s"):format(ns.ItemInfo(itemID) or ("item " .. itemID),
    units, #listings, #listings == 1 and "" or "s") }
  if diff then
    parts[#parts + 1] = diff.soldUnits > 0 and ("%d sold"):format(diff.soldUnits) or "none sold"
    if diff.listedUnits > 0 then parts[#parts + 1] = ("%d newly listed"):format(diff.listedUnits) end
    if diff.reposts > 0 then parts[#parts + 1] = ("%d relisted"):format(diff.reposts) end
    if diff.ambiguous > 0 then parts[#parts + 1] = ("%d gone, maybe expired"):format(diff.ambiguous) end
  elseif reason == "gap" then
    parts[#parts + 1] = "too long since the last look, starting fresh"
  else
    parts[#parts + 1] = "first look"
  end
  local text = table.concat(parts, ", ")
  if source == "search" then text = text .. " (from your search)" end
  return text
end

function ns.OnSnapshot(itemID, listings, t, source)
  if not db then return end
  local diff, reason = ns.Store.Record(db, ns.RealmKey(), itemID, listings, t, db.settings.maxGap)
  ns.Log("%s", describe(itemID, listings, diff, reason, source))
  ns.DataChanged()
end

-- Full scans: recorded quietly (one summary line per scan instead).
function ns.RecordFull(itemID, listings, t)
  return (ns.Store.Record(db, ns.FullRealmKey(), itemID, listings, t, db.settings.fullMaxGap))
end

function ns.FullItemIDs()
  local ids = {}
  for id in pairs(db.realms[ns.FullRealmKey()] or {}) do ids[#ids + 1] = id end
  return ids
end

local function summarize(rec, t, fromFull, window)
  if not rec then return nil end
  local rate, seen, avg, units = ns.Store.Rate(rec, t, window)
  return { rate = rate, seen = seen, avg = avg, units = units, fromFull = fromFull,
           supply = rec.supply, lastAt = rec.last and rec.last.t }
end

-- Prefers the per-minute watchlist data; falls back to full scans.
function ns.Summary(itemID, t, window)
  if not db then return nil end
  t, window = t or time(), window or db.settings.window
  local watched = summarize(ns.Store.Get(db, ns.RealmKey(), itemID), t, false, window)
  if watched and watched.seen > 0 then return watched end
  return summarize(ns.Store.Get(db, ns.FullRealmKey(), itemID), t, true, window) or watched
end

-- Vendor sell price per unit in copper (0 if it can't be sold to a vendor).
function ns.VendorPrice(itemID)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not get then return nil end
  return (select(11, get(itemID)))
end

-- Cheapest current buyout per unit, from whichever snapshot (watchlist or
-- full scan) is newest. Returns price (or nil if nothing has a buyout),
-- snapshot time, units listed; or nil if the item has never been seen.
function ns.MarketPrice(itemID)
  if not db then return nil end
  local newest
  for _, key in ipairs({ ns.RealmKey(), ns.FullRealmKey() }) do
    local rec = ns.Store.Get(db, key, itemID)
    if rec and rec.last and (not newest or rec.last.t > newest.last.t) then newest = rec end
  end
  if not newest then return nil end
  local min
  for _, l in ipairs(newest.last.listings) do
    if (l.buyout or 0) > 0 and l.count > 0 then
      local unit = l.buyout / l.count
      if not min or unit < min then min = unit end
    end
  end
  return min, newest.last.t, newest.supply or 0
end

ns.MIN_SEEN = 10 * 60 -- don't rank or show a rate based on less than 10 minutes of watching

-- Every item with sales in the last `window` seconds, unsorted:
-- { id, rate (units/hr), avg (copper/unit), gold (copper/hr), supply, seen, fromFull }
function ns.TopMovers(window, t)
  if not db then return {} end
  t = t or time()
  local ids = {}
  for id in pairs(db.realms[ns.RealmKey()] or {}) do ids[id] = true end
  for id in pairs(db.realms[ns.FullRealmKey()] or {}) do ids[id] = true end
  local out = {}
  for id in pairs(ids) do
    local s = ns.Summary(id, t, window)
    if s and s.seen >= ns.MIN_SEEN and s.units > 0 then
      local avg = s.avg or 0
      out[#out + 1] = { id = id, rate = s.rate, avg = avg, gold = s.rate * avg,
                        supply = s.supply or 0, seen = s.seen, fromFull = s.fromFull }
    end
  end
  return out
end

local function dataChanged()
  if ns.OnDataChanged then ns.OnDataChanged() end
end
ns.DataChanged = dataChanged

function ns.FormatRate(r)
  if r >= 10 then return ("%d"):format(math.floor(r + 0.5)) end
  return ("%.1f"):format(r)
end

function ns.FormatDuration(s)
  if s < 3600 then return ("%dm"):format(math.floor(s / 60)) end
  if s < 86400 then return ("%.1fh"):format(s / 3600) end
  return ("%.1fd"):format(s / 86400)
end

-- Money with the game's coin icons, e.g. 2[silver] 82[copper]. Built from the
-- icon textures directly: the coin-string API moved between client versions.
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

function ns.FormatMoney(copper)
  copper = math.floor(copper + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then
    parts[#parts + 1] = (BreakUpLargeNumbers and BreakUpLargeNumbers(g) or tostring(g)) .. GOLD_ICON
  end
  if s > 0 then parts[#parts + 1] = s .. SILVER_ICON end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. COPPER_ICON end
  return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Scheduling

local function watchedIDs()
  local ids = {}
  for id in pairs(db.watch) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

local function onUpdate(_, elapsed)
  acc = acc + elapsed
  if acc < TICK then return end
  acc = 0
  local t = GetTime()
  scanner.Tick(t)
  if full then full.Tick(t) end
  local s = db.settings
  local idle = t - scanner.LastUserActivity() >= s.idle
  if full and s.full and t >= nextFullAt and t >= full.ReadyAt() and idle
      and not scanner.Busy() and not full.Pending() then
    nextFullAt = t + s.fullInterval
    if full.Start(t) then ns.Log("Full scan started.") end
  elseif s.auto and t >= nextScanAt and idle and not scanner.Busy()
      and not (full and full.Busy()) then
    nextScanAt = t + s.interval
    local ids = watchedIDs()
    if #ids > 0 and scanner.Start(ids) then
      ns.Log("Scanning %d item%s.", #ids, #ids == 1 and "" or "s")
    end
  end
end

local function initDB()
  TurnoverDB = TurnoverDB or {}
  db = TurnoverDB
  db.settings = db.settings or {}
  for k, v in pairs(DEFAULT_SETTINGS) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
  -- Settings version 2: full scans proved to take seconds, so the default went
  -- from every 5 minutes to every minute. Move anyone still on the old default.
  if (db.settingsVersion or 1) < 2 then
    if db.settings.fullInterval == 300 then db.settings.fullInterval = 60 end
    db.settingsVersion = 2
  end
  db.log = db.log or {}
  if not db.watch then
    db.watch = {}
    for _, id in ipairs(DEFAULT_WATCH) do db.watch[id] = true end
  end
  ns.Store.Init(db)
end

local function pickScanner()
  local s = ns.Scanners
  if s.legacy.Available() then return s.legacy end
  if s.modern.Available() then return s.modern end
end

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... == addonName then initDB() end
  elseif event == "PLAYER_LOGIN" then
    scanner = pickScanner()
    if scanner then scanner.Install() end
    if scanner and ns.FullScan.Available() then
      full = ns.FullScan
      full.Install()
    end
  elseif not scanner then
    return
  elseif event == "AUCTION_HOUSE_SHOW" then
    -- Watchlist first: it's quick, and the first full scan uses it to check prices.
    nextScanAt = GetTime() + FIRST_SCAN_DELAY
    nextFullAt = nextScanAt + 10
    frame:SetScript("OnUpdate", onUpdate)
    local s, parts = db.settings, {}
    if full and s.full then parts[#parts + 1] = ("full scan every %s"):format(ns.FormatDuration(s.fullInterval)) end
    if s.auto then parts[#parts + 1] = ("watchlist every %ds"):format(s.interval) end
    if #parts > 0 then
      ns.Log("Auction house open. Scanning while you're idle: %s.", table.concat(parts, ", "))
    end
  elseif event == "AUCTION_HOUSE_CLOSED" then
    frame:SetScript("OnUpdate", nil)
    scanner.Stop()
    if full then full.Stop() end
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    if full then full.OnReplicateUpdate() end
  elseif event == "AUCTION_ITEM_LIST_UPDATE" then
    if scanner.OnListUpdate then scanner.OnListUpdate() end
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    if scanner.OnCommodityResults then scanner.OnCommodityResults(...) end
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    if scanner.OnItemResults then scanner.OnItemResults(...) end
  end
end)

for _, event in ipairs({
  "ADDON_LOADED", "PLAYER_LOGIN", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "AUCTION_ITEM_LIST_UPDATE", "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED",
  "REPLICATE_ITEM_LIST_UPDATE",
}) do
  pcall(frame.RegisterEvent, frame, event) -- not every client has every event
end

---------------------------------------------------------------------------
-- Slash commands

local function parseItem(arg)
  arg = arg and arg:match("^%s*(.-)%s*$") or ""
  if arg == "" then return nil end
  local id = tonumber(arg) or tonumber(arg:match("item:(%d+)"))
  if not id then
    local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local _, link = get and get(arg)
    id = link and tonumber(link:match("item:(%d+)"))
  end
  return id
end

local function itemLabel(id)
  return ns.ItemInfo(id) or ("item " .. id)
end

local function status()
  say("%s, watchlist scan %s every %ds.", scanner and scanner.label or "no auction API found",
    db.settings.auto and "on" or "off", db.settings.interval)
  if full then
    say("Full scan %s every %s, %d items tracked.", db.settings.full and "on" or "off",
      ns.FormatDuration(db.settings.fullInterval), #ns.FullItemIDs())
  end
  local ids = watchedIDs()
  if #ids == 0 then say("Watchlist is empty. /turnover watch <item link>") return end
  local now = time()
  for _, id in ipairs(ids) do
    local s = ns.Summary(id, now)
    if not s or s.seen == 0 then
      say("%s: no data yet", itemLabel(id))
    else
      say("%s: ~%s/hr sold%s, %d listed, %s watched, last scan %s ago",
        itemLabel(id), ns.FormatRate(s.rate),
        s.avg and (" at " .. ns.FormatMoney(s.avg)) or "",
        s.supply or 0, ns.FormatDuration(s.seen),
        s.lastAt and ns.FormatDuration(now - s.lastAt) or "?")
    end
  end
end

local HELP = {
  "/turnover - show sell rates for watched items",
  "/turnover watch <item> - track an item (shift-click a link, or an item ID)",
  "/turnover unwatch <item> - stop tracking (history is kept)",
  "/turnover scan - scan now (auction house must be open)",
  "/turnover top - open the Top movers panel (auction house must be open)",
  "/turnover auto on|off - scan automatically while the auction house is open",
  "/turnover interval <seconds> - time between automatic scans",
  "/turnover full on|off|<seconds> - scan the whole auction house periodically",
  "/turnover chat on|off - show what it's doing in the chat log",
  "/turnover reset <item>|all - forget history on this realm",
}

SLASH_TURNOVER1 = "/turnover"
SLASH_TURNOVER2 = "/tov"
SlashCmdList.TURNOVER = function(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)$")
  cmd = cmd:lower()
  if cmd == "" or cmd == "status" then
    status()
  elseif cmd == "watch" or cmd == "unwatch" then
    local id = parseItem(rest)
    if not id then say("Couldn't find that item. Shift-click its link or use the item ID.") return end
    db.watch[id] = (cmd == "watch") or nil
    say("%s %s.", cmd == "watch" and "Watching" or "Stopped watching", itemLabel(id))
  elseif cmd == "scan" then
    if not scanner then say("No auction API found on this client.") return end
    if not (AuctionFrame and AuctionFrame:IsShown()) and not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
      say("Open the auction house first.") return
    end
    if scanner.Start(watchedIDs()) then say("Scanning.") else say("Already scanning.") end
  elseif cmd == "auto" then
    local v = rest:lower()
    if v == "on" or v == "off" then db.settings.auto = (v == "on") end
    say("Auto-scan %s.", db.settings.auto and "on" or "off")
  elseif cmd == "top" then
    if not ns.UI then
      say("Top movers isn't loaded. Restart WoW fully: new addon files only load on a restart, not /reload.")
      return
    end
    local problem = ns.UI.Problem()
    if problem then say("Can't show Top movers: %s.", problem) return end
    ns.UI.ShowPanel()
  elseif cmd == "full" then
    local v, n = rest:lower(), tonumber(rest)
    if v == "on" or v == "off" then db.settings.full = (v == "on") end
    if n then
      db.settings.fullInterval = math.max(MIN_FULL_INTERVAL, math.floor(n))
      db.settings.fullRefusedGap = nil -- start learning the server's limit afresh
    end
    if not full then say("This client has no full-scan API.") return end
    say("Full scan %s, every %s.", db.settings.full and "on" or "off", ns.FormatDuration(db.settings.fullInterval))
  elseif cmd == "chat" then
    local v = rest:lower()
    if v == "on" or v == "off" then db.settings.chat = (v == "on") end
    say("Chat log %s.", db.settings.chat and "on" or "off")
  elseif cmd == "interval" then
    local n = tonumber(rest)
    if n then db.settings.interval = math.max(MIN_INTERVAL, math.floor(n)) end
    say("Scanning every %ds.", db.settings.interval)
  elseif cmd == "reset" then
    local realm = ns.RealmKey()
    if rest:lower() == "all" then
      db.realms[realm] = nil
      db.realms[ns.FullRealmKey()] = nil
      say("Forgot all history for %s.", realm)
    else
      local id = parseItem(rest)
      if not id then say("Usage: /turnover reset <item>|all") return end
      ns.Store.Reset(db, realm, id)
      ns.Store.Reset(db, ns.FullRealmKey(), id)
      say("Forgot history for %s.", itemLabel(id))
    end
  else
    for _, line in ipairs(HELP) do say(line) end
  end
end
