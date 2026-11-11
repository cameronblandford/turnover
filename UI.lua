-- UI: a "Top movers" tab on the auction house window.
--
-- The tab is our own button, and the list is our own panel laid over the
-- auction window's content. Nothing is added to Blizzard's tab or display-mode
-- tables, so buying and posting code never runs through addon code. Clicking
-- any Blizzard tab, or closing the auction house, hides the panel again.

local _, ns = ...

local UI = {}
ns.UI = UI

local WINDOWS = {
  { label = "1h", secs = 3600 },
  { label = "6h", secs = 6 * 3600 },
  { label = "24h", secs = 86400 },
  { label = "7d", secs = 7 * 86400 },
}
local COLUMNS = {
  { key = "name",   label = "Item",      width = 260, justify = "LEFT" },
  { key = "rate",   label = "Sold / hr", width = 80,  justify = "RIGHT" },
  { key = "avg",    label = "Avg price", width = 130, justify = "RIGHT" },
  { key = "gold",   label = "Value / hr", width = 140, justify = "RIGHT" },
  { key = "supply", label = "Listed",    width = 70,  justify = "RIGHT" },
  { key = "seen",   label = "Watched",   width = 70,  justify = "RIGHT" },
}
local ROW_H = 20
local TOP = 64 -- space above the first row (title + headers)
local BOTTOM = 26 -- footer
local LEFT = 14

local panel, tab, rows, headers, windowButtons, footer, empty
local data, offset = {}, 0
local sortKey, sortDesc = "rate", true
local refreshQueued = false

local function settings() return ns.Settings() end

-- Blizzard's own auction house tabs, never including ours.
local function blizzardTabs()
  local tabs = AuctionHouseFrame and AuctionHouseFrame.Tabs
  local out = {}
  if type(tabs) == "table" then
    for _, t in ipairs(tabs) do
      if t ~= tab then out[#out + 1] = t end
    end
  end
  return out
end

local function windowIndex()
  local i = settings().topWindow
  return WINDOWS[i] and i or 1
end

local function itemDisplay(id)
  local name, quality = ns.ItemInfo(id)
  local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id))
    or (GetItemIcon and GetItemIcon(id))
  local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
  return name or ("item " .. id), icon, color
end

local function sortData()
  local key, desc = sortKey, sortDesc
  table.sort(data, function(a, b)
    local x, y = a[key], b[key]
    if key == "name" then x, y = x:lower(), y:lower() end
    if x == y then return a.id < b.id end
    if desc then return x > y end
    return x < y
  end)
end

local function cell(d, key)
  if key == "rate" then return ns.FormatRate(d.rate) end
  if key == "avg" then return ns.FormatMoney(d.avg) end
  if key == "gold" then return ns.FormatMoney(d.gold) end
  if key == "supply" then return tostring(d.supply) end
  if key == "seen" then return ns.FormatDuration(d.seen) end
end

local function visibleRows()
  return math.max(1, math.floor(((panel:GetHeight() or 0) - TOP - BOTTOM) / ROW_H))
end

local function onRowEnter(row)
  if not row.itemID then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  if GameTooltip.SetItemByID then GameTooltip:SetItemByID(row.itemID) end
  GameTooltip:Show()
end

local function onRowLeave() GameTooltip:Hide() end

local function onRowClick(row)
  if not row.itemID or not (IsModifiedClick and IsModifiedClick("CHATLINK")) then return end
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local _, link = get(row.itemID)
  if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
end

local function makeRow(i)
  local row = CreateFrame("Button", nil, panel)
  row:SetHeight(ROW_H)
  row:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT, -TOP - (i - 1) * ROW_H)
  row:SetPoint("RIGHT", panel, "RIGHT", -LEFT, 0)
  local stripe = row:CreateTexture(nil, "BACKGROUND")
  stripe:SetAllPoints()
  stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.03 or 0)
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(ROW_H - 4, ROW_H - 4)
  row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
  row.cells = {}
  local x = 0
  for c, col in ipairs(COLUMNS) do
    local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    local inset = c == 1 and ROW_H + 2 or 0
    fs:SetPoint("LEFT", row, "LEFT", x + inset, 0)
    fs:SetWidth(col.width - inset - 6)
    fs:SetJustifyH(col.justify)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    row.cells[col.key] = fs
    x = x + col.width
  end
  row:SetScript("OnEnter", onRowEnter)
  row:SetScript("OnLeave", onRowLeave)
  row:SetScript("OnClick", onRowClick)
  return row
end

local function render()
  local n = visibleRows()
  for i = #rows + 1, n do rows[i] = makeRow(i) end
  offset = math.max(0, math.min(offset, #data - n))
  for i, row in ipairs(rows) do
    local d = i <= n and data[offset + i]
    if d then
      row.itemID = d.id
      row.icon:SetTexture(d.icon)
      local nameCell = row.cells.name
      nameCell:SetText(d.name)
      if d.color then nameCell:SetTextColor(d.color.r, d.color.g, d.color.b)
      else nameCell:SetTextColor(1, 1, 1) end
      for _, col in ipairs(COLUMNS) do
        if col.key ~= "name" then row.cells[col.key]:SetText(cell(d, col.key)) end
      end
      row:Show()
    else
      row.itemID = nil
      row:Hide()
    end
  end
  for _, h in ipairs(headers) do
    if h.key == sortKey then h.text:SetTextColor(1, 1, 1) else h.text:SetTextColor(1, 0.82, 0) end
  end
  empty:SetShown(#data == 0)
  if #data == 0 then
    footer:SetText("")
  else
    footer:SetText(("%d-%d of %d items with sales in the last %s. Scroll for more. Estimates are a lower bound.")
      :format(offset + 1, math.min(#data, offset + n), #data, WINDOWS[windowIndex()].label))
  end
end

function UI.Data() return data end

function UI.Refresh()
  if not panel or not panel:IsShown() then return end
  data = ns.TopMovers(WINDOWS[windowIndex()].secs)
  for _, d in ipairs(data) do d.name, d.icon, d.color = itemDisplay(d.id) end
  sortData()
  render()
end

function ns.OnDataChanged()
  if not panel or not panel:IsShown() or refreshQueued then return end
  refreshQueued = true
  C_Timer.After(0.5, function()
    refreshQueued = false
    UI.Refresh()
  end)
end

local function updateWindowButtons()
  for i, b in ipairs(windowButtons) do
    if i == windowIndex() then b:LockHighlight() else b:UnlockHighlight() end
  end
end

function UI.ShowPanel()
  if not panel then return end
  panel:Show()
  if PanelTemplates_SelectTab then
    PanelTemplates_SelectTab(tab)
    for _, t in ipairs(blizzardTabs()) do PanelTemplates_DeselectTab(t) end
  end
  offset = 0
  updateWindowButtons()
  UI.Refresh()
end

function UI.HidePanel()
  if not panel or not panel:IsShown() then return end
  panel:Hide()
  if PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(tab) end
end

local function makeTab(ah)
  -- The generic tab template, not AuctionHouseFrameTabTemplate: that one adds
  -- itself to AuctionHouseFrame.Tabs, putting our tab into Blizzard's tab logic.
  local last = blizzardTabs()
  last = last[#last] or _G.AuctionHouseFrameAuctionsTab
  local t = CreateFrame("Button", "TurnoverAuctionTab", ah, "PanelTabButtonTemplate")
  t:SetText("Top movers")
  if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, t, 0) end
  if last and last ~= t then
    t:SetPoint("LEFT", last, "RIGHT", 3, 0)
  else
    t:SetPoint("TOPLEFT", ah, "BOTTOMLEFT", 20, 2)
  end
  if PanelTemplates_DeselectTab then PanelTemplates_DeselectTab(t) end
  t:Show()
  t:SetScript("OnClick", function()
    if PlaySound and SOUNDKIT then PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB) end
    UI.ShowPanel()
  end)
  return t
end

local function build()
  local ah = AuctionHouseFrame
  tab = makeTab(ah)

  panel = CreateFrame("Frame", "TurnoverTopMovers", ah)
  panel:SetPoint("TOPLEFT", ah, "TOPLEFT", 3, -22)
  panel:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -3, 3)
  panel:SetFrameLevel(ah:GetFrameLevel() + 100)
  panel:EnableMouse(true)
  panel:EnableMouseWheel(true)
  panel:Hide()
  local bg = panel:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.06, 0.98)

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT, -12)
  title:SetText("Top movers")

  windowButtons = {}
  for i = #WINDOWS, 1, -1 do
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(44, 20)
    b:SetText(WINDOWS[i].label)
    if i == #WINDOWS then
      b:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -LEFT, -10)
    else
      b:SetPoint("RIGHT", windowButtons[i + 1], "LEFT", -4, 0)
    end
    b:SetScript("OnClick", function()
      settings().topWindow = i
      offset = 0
      updateWindowButtons()
      UI.Refresh()
    end)
    windowButtons[i] = b
  end
  local windowLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  windowLabel:SetPoint("RIGHT", windowButtons[1], "LEFT", -8, 0)
  windowLabel:SetText("Sales in the last")

  headers = {}
  local x = LEFT
  for _, col in ipairs(COLUMNS) do
    local h = CreateFrame("Button", nil, panel)
    h:SetSize(col.width, 18)
    h:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -TOP + 20)
    h.key = col.key
    h.text = h:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    h.text:SetPoint("LEFT", h, "LEFT", 0, 0)
    h.text:SetWidth(col.width - 6)
    h.text:SetJustifyH(col.justify)
    h.text:SetText(col.label)
    h:SetScript("OnClick", function()
      if sortKey == col.key then
        sortDesc = not sortDesc
      else
        sortKey, sortDesc = col.key, col.key ~= "name"
      end
      sortData()
      render()
    end)
    headers[#headers + 1] = h
    x = x + col.width
  end

  footer = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", LEFT, 8)

  empty = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
  empty:SetPoint("CENTER", panel, "CENTER", 0, 0)
  empty:SetWidth(420)
  empty:SetText("No sales seen in this time window yet. Keep the auction house open for a while: "
    .. "full scans run every minute, and items need 10 minutes of watching to be ranked.")

  rows = {}
  UI.panel, UI.tab, UI.rows = panel, tab, rows -- for tests and debugging
  panel:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - delta * 3
    render()
  end)
  panel:SetScript("OnSizeChanged", function() if panel:IsShown() then render() end end)

  -- Any Blizzard tab or display change puts the normal view back.
  if ah.SetDisplayMode then hooksecurefunc(ah, "SetDisplayMode", UI.HidePanel) end
  for _, t in ipairs(blizzardTabs()) do t:HookScript("OnClick", UI.HidePanel) end
  ns.Log("Added the Top movers tab to the auction house.")
end

-- The auction window is load-on-demand, and AUCTION_HOUSE_SHOW can arrive
-- before it exists, so try at every point it might have appeared. WoW hides
-- Lua errors by default, so a failed build is reported in chat instead.
local buildError
local function tryBuild()
  if panel or buildError or not AuctionHouseFrame then return end
  local ok, err = pcall(build)
  if not ok then
    buildError = tostring(err)
    ns.Log("Couldn't add the Top movers tab: %s", buildError)
  end
end

-- Reason the panel can't be shown, or nil when it's there.
function UI.Problem()
  if buildError then return "the tab failed to build: " .. buildError end
  if not AuctionHouseFrame then return "the auction house window hasn't loaded; open the auction house first" end
  if not panel then tryBuild() end
  if not panel then return "the tab hasn't been built yet" end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, arg)
  if event == "AUCTION_HOUSE_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
    tryBuild()
    if not panel and C_Timer then C_Timer.After(0, tryBuild) end -- the window loads this frame
  elseif event == "ADDON_LOADED" then
    if arg == "Blizzard_AuctionHouseUI" then tryBuild() end
  elseif event == "PLAYER_LOGIN" then
    tryBuild() -- another addon may have loaded the auction window already
  elseif event == "AUCTION_HOUSE_CLOSED" then
    UI.HidePanel()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    ns.OnDataChanged() -- names and icons for newly cached items
  end
end)
for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "ADDON_LOADED",
                         "PLAYER_LOGIN", "AUCTION_HOUSE_CLOSED", "GET_ITEM_INFO_RECEIVED" }) do
  pcall(events.RegisterEvent, events, event)
end
