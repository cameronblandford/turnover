-- Core: saved data, scan scheduling, slash commands.

local addonName, ns = ...

local DEFAULT_SETTINGS = {
  auto = true,         -- scan the watchlist while the auction house is open
  interval = 60,       -- seconds between scans
  idle = 8,            -- seconds the player must be idle before a scan starts
  maxGap = 15 * 60,    -- longest gap between snapshots that still counts
  window = 7 * 86400,  -- how far back the rate looks
}
local DEFAULT_WATCH = { 2770, 2840 } -- Copper Ore, Copper Bar
local MIN_INTERVAL = 20
local FIRST_SCAN_DELAY = 3
local TICK = 0.1

local db, scanner
local nextScanAt, acc = 0, 0
local frame = CreateFrame("Frame")

local function say(fmt, ...)
  print("|cff8ab4f8Turnover|r " .. fmt:format(...))
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

function ns.WatchList() return db and db.watch or {} end
function ns.IsWatched(itemID) return db ~= nil and db.watch[itemID] == true end

function ns.OnSnapshot(itemID, listings, t)
  if not db then return end
  ns.Store.Record(db, ns.RealmKey(), itemID, listings, t, db.settings.maxGap)
end

function ns.Summary(itemID, t)
  if not db then return nil end
  local rec = ns.Store.Get(db, ns.RealmKey(), itemID)
  if not rec then return nil end
  local rate, seen, avg, units = ns.Store.Rate(rec, t or time(), db.settings.window)
  return { rate = rate, seen = seen, avg = avg, units = units,
           supply = rec.supply, lastAt = rec.last and rec.last.t }
end

function ns.FormatRate(r)
  if r >= 10 then return ("%d"):format(math.floor(r + 0.5)) end
  return ("%.1f"):format(r)
end

function ns.FormatDuration(s)
  if s < 3600 then return ("%dm"):format(math.floor(s / 60)) end
  if s < 86400 then return ("%.1fh"):format(s / 3600) end
  return ("%.1fd"):format(s / 86400)
end

function ns.FormatMoney(copper)
  copper = math.floor(copper + 0.5)
  if GetCoinTextureString then return GetCoinTextureString(copper) end
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then return ("%dg %ds %dc"):format(g, s, c) end
  if s > 0 then return ("%ds %dc"):format(s, c) end
  return ("%dc"):format(c)
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
  local s = db.settings
  if s.auto and t >= nextScanAt and not scanner.Busy()
      and t - scanner.LastUserActivity() >= s.idle then
    nextScanAt = t + s.interval
    scanner.Start(watchedIDs())
  end
end

local function initDB()
  TurnoverDB = TurnoverDB or {}
  db = TurnoverDB
  db.settings = db.settings or {}
  for k, v in pairs(DEFAULT_SETTINGS) do
    if db.settings[k] == nil then db.settings[k] = v end
  end
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
  elseif not scanner then
    return
  elseif event == "AUCTION_HOUSE_SHOW" then
    nextScanAt = GetTime() + FIRST_SCAN_DELAY
    frame:SetScript("OnUpdate", onUpdate)
  elseif event == "AUCTION_HOUSE_CLOSED" then
    frame:SetScript("OnUpdate", nil)
    scanner.Stop()
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
  say("%s, auto-scan %s every %ds.", scanner and scanner.label or "no auction API found",
    db.settings.auto and "on" or "off", db.settings.interval)
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
  "/turnover auto on|off - scan automatically while the auction house is open",
  "/turnover interval <seconds> - time between automatic scans",
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
  elseif cmd == "interval" then
    local n = tonumber(rest)
    if n then db.settings.interval = math.max(MIN_INTERVAL, math.floor(n)) end
    say("Scanning every %ds.", db.settings.interval)
  elseif cmd == "reset" then
    local realm = ns.RealmKey()
    if rest:lower() == "all" then
      db.realms[realm] = nil
      say("Forgot all history for %s.", realm)
    else
      local id = parseItem(rest)
      if not id then say("Usage: /turnover reset <item>|all") return end
      ns.Store.Reset(db, realm, id)
      say("Forgot history for %s.", itemLabel(id))
    end
  else
    for _, line in ipairs(HELP) do say(line) end
  end
end
