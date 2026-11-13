-- Tooltip: up to two lines on items the auction house data covers.
--   Turnover AH 89c each · ~812/hr sold
--   Turnover Auction it: nets ~85c vs 20c at a vendor

local _, ns = ...

local LABEL = "|cff8ab4f8Turnover|r "
local STALE = 60 * 60 -- mention the price's age once it's over an hour old

function ns.TooltipLines(itemID, t)
  t = t or time()
  local price, priceAt = ns.MarketPrice(itemID)
  local s = ns.Summary(itemID, t)
  local rated = s ~= nil and s.seen >= ns.MIN_SEEN
  if not priceAt and not rated then return nil end

  local parts = {}
  if price then
    parts[#parts + 1] = "AH " .. ns.FormatMoney(price) .. " each"
  elseif priceAt then
    parts[#parts + 1] = "none on the AH"
  end
  if rated then
    local sold = "~" .. ns.FormatRate(s.rate) .. "/hr sold"
    if not price and s.avg then sold = sold .. " at " .. ns.FormatMoney(s.avg) end
    parts[#parts + 1] = sold
  end
  if priceAt and t - priceAt > STALE then
    parts[#parts + 1] = "as of " .. ns.FormatDuration(t - priceAt) .. " ago"
  end

  local lines = { LABEL .. table.concat(parts, " · ") }
  local advice = ns.Advice.Text(ns.VendorPrice(itemID), price or (s and s.avg),
    s and s.rate, s and s.seen)
  if advice then lines[2] = LABEL .. advice end
  return lines
end

function ns.TooltipText(itemID)
  local lines = ns.TooltipLines(itemID)
  return lines and lines[1]
end

local function addLines(tooltip, itemID)
  local lines = itemID and ns.TooltipLines(itemID)
  if not lines then return end
  for _, text in ipairs(lines) do tooltip:AddLine(text, 0.7, 0.7, 0.7) end
end

local function wanted(tooltip)
  return tooltip == GameTooltip or tooltip == ItemRefTooltip
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if wanted(tooltip) and data and type(data.id) == "number" then addLines(tooltip, data.id) end
  end)
else
  local function onSetItem(tooltip)
    local _, link = tooltip:GetItem()
    addLines(tooltip, link and tonumber(link:match("item:(%d+)")))
  end
  for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tooltip then tooltip:HookScript("OnTooltipSetItem", onSetItem) end
  end
end
