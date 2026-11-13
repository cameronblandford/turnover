-- Tooltip: label on the left, value on the right, like the game's own
-- price lines. Only shown for items the auction house data covers.
--
--   Turnover AH price        2s 82c (3h old)
--   Sold per hour                       ~32
--   Best option     Auction (+2s 43c each)

local _, ns = ...

local STALE = 60 * 60 -- mention the price's age once it's over an hour old
local GREY, END = "|cff909090", "|r"

-- Returns { {left, right}, ... } or nil.
function ns.TooltipRows(itemID, t)
  t = t or time()
  local price, priceAt = ns.MarketPrice(itemID)
  local s = ns.Summary(itemID, t)
  local rated = s ~= nil and s.seen >= ns.MIN_SEEN
  if not priceAt and not rated then return nil end

  local rows = {}
  local priceText
  if price then
    priceText = ns.FormatMoney(price)
  elseif priceAt then
    priceText = GREY .. "none listed" .. END
  else
    priceText = GREY .. "unknown" .. END
  end
  if priceAt and t - priceAt > STALE then
    priceText = priceText .. GREY .. " (" .. ns.FormatDuration(t - priceAt) .. " old)" .. END
  end
  rows[#rows + 1] = { "|cff8ab4f8Turnover|r AH price", priceText }

  if rated then
    local sold = "~" .. ns.FormatRate(s.rate)
    if not price and s.avg then sold = sold .. GREY .. " at " .. END .. ns.FormatMoney(s.avg) end
    rows[#rows + 1] = { "Sold per hour", sold }
  end

  local advice = ns.Advice.Text(ns.VendorPrice(itemID), price or (s and s.avg), s and s.rate, s and s.seen)
  if advice then rows[#rows + 1] = { "Best option", advice } end
  return rows
end

local function addRows(tooltip, itemID)
  local rows = itemID and ns.TooltipRows(itemID)
  if not rows then return end
  for _, row in ipairs(rows) do
    tooltip:AddDoubleLine(row[1], row[2], 1, 0.82, 0, 1, 1, 1)
  end
end

local function wanted(tooltip)
  return tooltip == GameTooltip or tooltip == ItemRefTooltip
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if wanted(tooltip) and data and type(data.id) == "number" then addRows(tooltip, data.id) end
  end)
else
  local function onSetItem(tooltip)
    local _, link = tooltip:GetItem()
    addRows(tooltip, link and tonumber(link:match("item:(%d+)")))
  end
  for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tooltip then tooltip:HookScript("OnTooltipSetItem", onSetItem) end
  end
end
