-- Store: per-realm history of observed sales.
--
-- For every watched item it keeps the last snapshot and a list of
-- observations { startTime, endTime, unitsSold, copperSold }. Observations
-- that follow on from each other within the same clock hour are merged, so
-- one entry covers at most an hour of watching.

local _, ns = ...

local Store = {}
ns.Store = Store

local HOUR = 3600
Store.MAX_OBS = 24 * 60 -- about 60 days of continuous watching, per item

function Store.Init(db)
  db.version = db.version or 1
  db.realms = db.realms or {}
end

function Store.Get(db, realm, itemID, create)
  local items = db.realms[realm]
  if not items then
    if not create then return nil end
    items = {}
    db.realms[realm] = items
  end
  local rec = items[itemID]
  if not rec and create then
    rec = { obs = {} }
    items[itemID] = rec
  end
  return rec
end

function Store.Reset(db, realm, itemID)
  local items = db.realms[realm]
  if items then items[itemID] = nil end
end

function Store.AddObservation(rec, t0, t1, units, value)
  local obs = rec.obs
  local tail = obs[#obs]
  if tail and tail[2] == t0 and math.floor(tail[1] / HOUR) == math.floor(t0 / HOUR) then
    tail[2] = t1
    tail[3] = tail[3] + units
    tail[4] = tail[4] + value
  else
    obs[#obs + 1] = { t0, t1, units, value }
  end
  while #obs > Store.MAX_OBS do table.remove(obs, 1) end
end

-- Records a complete snapshot of an item's listings taken at time t (seconds,
-- wall clock). Sales are only counted against the previous snapshot when it
-- is at most maxGap seconds old; after a longer gap too much may have
-- happened unseen, so the snapshot just becomes the new baseline.
--
-- Returns the Diff result, or nil plus "first" / "gap" when there was nothing
-- to compare against.
function Store.Record(db, realm, itemID, listings, t, maxGap)
  local rec = Store.Get(db, realm, itemID, true)
  local last, diff, reason = rec.last, nil, nil
  if last and t >= last.t and t - last.t <= maxGap then
    diff = ns.Diff.Compare(last.listings, listings, t - last.t)
    Store.AddObservation(rec, last.t, t, diff.soldUnits, diff.soldValue)
  else
    reason = last and "gap" or "first"
  end
  local supply = 0
  for _, l in ipairs(listings) do supply = supply + l.count end
  rec.last = { t = t, listings = listings }
  rec.supply = supply
  return diff, reason
end

-- Returns unitsPerHour, secondsObserved, averageUnitPrice (or nil), units
-- over observations that ended within the last `window` seconds.
function Store.Rate(rec, t, window)
  local secs, units, value = 0, 0, 0
  for _, o in ipairs(rec.obs) do
    if o[2] >= t - window then
      secs = secs + (o[2] - o[1])
      units = units + o[3]
      value = value + o[4]
    end
  end
  local rate = secs > 0 and units * HOUR / secs or 0
  local avg = units > 0 and value / units or nil
  return rate, secs, avg, units
end
