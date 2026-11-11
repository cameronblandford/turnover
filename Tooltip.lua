-- Tooltip: one line on item tooltips, only once there's enough data.

local _, ns = ...

local MIN_SEEN = 10 * 60 -- don't show a rate based on less than 10 minutes of watching
local LABEL = "|cff8ab4f8Turnover|r "

function ns.TooltipText(itemID)
  local s = ns.Summary(itemID)
  if not s or s.seen < MIN_SEEN then return nil end
  local text = LABEL .. "~" .. ns.FormatRate(s.rate) .. "/hr"
  if s.avg then text = text .. " at " .. ns.FormatMoney(s.avg) end
  return text .. " · " .. ns.FormatDuration(s.seen) .. " seen"
end

local function addLine(tooltip, itemID)
  local text = itemID and ns.TooltipText(itemID)
  if text then tooltip:AddLine(text, 0.7, 0.7, 0.7) end
end

local function wanted(tooltip)
  return tooltip == GameTooltip or tooltip == ItemRefTooltip
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if wanted(tooltip) and data and type(data.id) == "number" then addLine(tooltip, data.id) end
  end)
else
  local function onSetItem(tooltip)
    local _, link = tooltip:GetItem()
    addLine(tooltip, link and tonumber(link:match("item:(%d+)")))
  end
  for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tooltip then tooltip:HookScript("OnTooltipSetItem", onSetItem) end
  end
end
