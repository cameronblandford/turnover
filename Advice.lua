-- Advice: should you sell an item to a vendor or put it on the auction house?
--
-- Compares the vendor price with what an auction would actually pay: the
-- cheapest current listing, less the auction house cut. An item that's been
-- watched for a while with nothing selling counts against the auction house,
-- unless it pays far more than the vendor.

local _, ns = ...

local Advice = {}
ns.Advice = Advice

Advice.AH_CUT = 0.05          -- the auction house keeps 5% of the sale
Advice.SLOW_SEEN = 60 * 60    -- watched this long with no sales = not selling
Advice.SLOW_OVERRIDE = 3      -- still auction a non-seller if it pays 3x the vendor

-- vendor: vendor price per unit (0/nil = can't vendor). price: auction price
-- per unit. rate: units sold per hour. seen: seconds watched.
-- Returns kind, net per unit after the cut. Kinds:
--   "auction"       the auction house pays more and it sells
--   "auction-slow"  pays a lot more, but nothing has sold lately
--   "vendor"        the vendor pays at least as much
--   "vendor-slow"   the auction house pays a bit more, but nothing sells
-- or nil when there's no auction price to compare.
function Advice.Recommend(vendor, price, rate, seen)
  vendor = vendor or 0
  if not price or price <= 0 then return nil end
  local net = price * (1 - Advice.AH_CUT)
  if net <= vendor then return "vendor", net end
  local stalled = (seen or 0) >= Advice.SLOW_SEEN and (rate or 0) <= 0
  if stalled then
    if vendor > 0 and net < vendor * Advice.SLOW_OVERRIDE then return "vendor-slow", net end
    return "auction-slow", net
  end
  return "auction", net
end

local GREEN, ORANGE, END = "|cff50e050", "|cffffa040", "|r"

-- One line of advice for the tooltip, or nil.
function Advice.Text(vendor, price, rate, seen)
  local kind, net = Advice.Recommend(vendor, price, rate, seen)
  if not kind then return nil end
  local money = ns.FormatMoney
  vendor = vendor or 0
  if kind == "vendor" then
    return ("%sVendor it:%s %s vs ~%s from an auction"):format(ORANGE, END, money(vendor), money(net))
  elseif kind == "vendor-slow" then
    return ("%sVendor it:%s none sold in %s on the auction house"):format(ORANGE, END, ns.FormatDuration(seen))
  end
  local versus = vendor > 0 and (" vs %s at a vendor"):format(money(vendor)) or " (vendors won't buy it)"
  if kind == "auction-slow" then
    return ("%sAuction it, but slowly:%s ~%s%s; none sold in %s"):format(
      GREEN, END, money(net), versus, ns.FormatDuration(seen))
  end
  return ("%sAuction it:%s nets ~%s%s"):format(GREEN, END, money(net), versus)
end
