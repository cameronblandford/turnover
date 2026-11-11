# Turnover

A World of Warcraft addon that estimates **how fast items sell** on the auction
house, built for WoW Forever. It adds one line to item tooltips and a
**Top movers** tab to the auction house, and nothing else: no windows or
minimap button:

```
Turnover ~142/hr at 12s 30c · 3.2h seen
```

That line reads: about 142 units sold per hour, at an average of 12s 30c each,
based on 3.2 hours of watching. It only appears once an item has been watched
for 10 minutes.

### Top movers tab

A tab at the bottom of the auction house window lists the items selling
fastest right now:

- **Columns:** units sold per hour, average sale price, value sold per
  hour, number listed, and how long the item has been watched.
- **Time window:** pick the last 1h, 6h, 24h or 7d. Click a column header
  to sort by it.
- **Interaction:** hover a row for the item tooltip; shift-click to link
  it in chat.
- **What's ranked:** items with at least 10 minutes of data and some sales
  in the window.

It's a separate panel over the auction window. It doesn't change
Blizzard's own tabs, so buying and posting work exactly as before.

## How it works

The auction house never tells addons about other players' sales, so Turnover
infers them. While the auction house is open, it searches each watched item
about once a minute and compares the results with the previous search:

- **Listings that disappear early** count as sold, at their buyout price.
- **Cancel-and-relist**: if the same seller lists the same stack size again,
  the stack isn't counted.
- **Possible expiry**: listings that might have run out of time, or have no
  buyout, aren't counted.

When it can't tell, it leaves the listing out, so the numbers are a **lower
bound**. Sales between two scans more than 15 minutes apart aren't counted.
Purchases that happen while you're away from the auction house are never seen.

Your own searches are used as well. If one of them returns every result on a
single page and includes a watched item, it's recorded at no extra cost.

### Full scans

Every minute (while you're idle at the auction house) it also takes a
snapshot of the whole auction house with `C_AuctionHouse.ReplicateItems`.
That gives rough rates for every item, not just the watchlist. Results are
read a chunk per frame to avoid a hitch. If another addon runs a full scan,
Turnover reads those results too. Watched items keep using their
per-minute data, which is much more precise for fast sellers.

### Activity log

While the auction house is open, it reports what it's doing in grey in the
chat window:

```
Turnover Scanning 2 items.
Turnover Copper Ore: 1100 listed in 55 auctions, 100 sold, 1 relisted
Turnover Copper Bar: 50 listed in 5 auctions, none sold
Turnover Put your last search back.
```

Turn it off with `/turnover chat off`.

### Staying out of the way

- It only scans while the auction house is open, and only after you've been
  idle there for 8 seconds.
- If you start a search, it stops its own scan straight away.
- After a scan it re-runs your last search, so the Browse tab shows what you
  were looking at.

### Client support

Turnover detects the auction house API at runtime:

- **Classic API** (`QueryAuctionItems`): exact-name searches, paged.
- **Retail API** (`C_AuctionHouse`): commodity and item searches, matched by
  auction ID, including partial commodity purchases.

## Commands

| Command | |
|---|---|
| `/turnover` (or `/tov`) | Sell rates for watched items |
| `/turnover watch <item>` | Track an item. Shift-click its link, or give the item ID |
| `/turnover unwatch <item>` | Stop tracking (history is kept) |
| `/turnover scan` | Scan now (auction house must be open) |
| `/turnover top` | Open the Top movers panel, or say why it can't |
| `/turnover auto on\|off` | Automatic scanning |
| `/turnover interval <seconds>` | Time between scans (minimum 20) |
| `/turnover full on\|off\|<seconds>` | Whole-auction-house scans (default every 60s, the minimum) |
| `/turnover chat on\|off` | Activity log in the chat window |
| `/turnover reset <item>\|all` | Forget history on this realm and faction |

Copper Ore and Copper Bar are watched by default. Data is stored per realm and
faction in `TurnoverDB`.

## Install

Copy or link this folder to
`World of Warcraft/_forever_/Interface/AddOns/Turnover`.

## Development

The core logic runs outside the game against a simulated auction house:

```sh
lua5.1 tests/run.lua
luacheck .
```

## License

MIT
