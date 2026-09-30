# GPRO menu bar widget

A native macOS menu bar widget showing a stock's current price, **including pre-market and after-hours**, refreshed every 5 seconds.

A single Swift file, no dependencies, no Xcode project — it builds with the system `swiftc`.

```
1.30 ▲0.02% 🌅
```

## What it shows

In the menu bar: the price, the percentage change in color, and an icon for the current trading session — sunrise for pre-market, sun for regular hours, sunset for after-hours, moon when the market is closed.

In the dropdown: the price to 4 decimals with the absolute change, the instrument name and session, the regular session close and the previous close marked with `◂ base` (the number the percentage is computed from), the day and 52-week ranges, the timestamps of the last tick and the last poll, and the latest headline per symbol — click it to open in the browser.

## Install

```bash
git clone git@github.com:alexe-dev/gpro-menubar-widget.git
cd gpro-menubar-widget
./build.sh
open GPRO.app
```

Launch at login:

```bash
./install-autostart.sh
```

This installs the `local.gpro.widget` launch agent. Quitting from the app's own menu does not trigger a restart; a crash does. To remove it:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.gpro.widget.plist
```

## Configuration

**Symbols** — two are tracked at once. Pick them from the menu (`Symbol: GPRO` ⌘S, `Second symbol: KOD` ⌘D) and type any Yahoo Finance ticker such as `AAPL` or `BTC-USD`. Both choices are remembered; if a ticker does not resolve, the previous one is kept. Defaults are `GPRO` and `KOD`.

The menu bar shows both quotes in order, primary first. The dropdown gives the primary symbol the full treatment — base marker, ranges, news — and the secondary one a compact block with its price, change, name and ranges. Clicking that block opens it on Yahoo Finance. Each symbol carries its latest headline.

**Language** — English or Russian, switchable from the menu. English by default, the choice is remembered.

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `TICKER` | `GPRO` | Initial primary symbol, used until one is picked from the menu |
| `TICKER2` | `KOD` | Initial secondary symbol |
| `REFRESH` | `5` | Poll interval in seconds |

```bash
TICKER=AAPL REFRESH=2 open GPRO.app
```

For the launch agent, set these through the plist's `EnvironmentVariables` key. Both settings live in `UserDefaults` under the `local.gpro.widget` domain.

## Where the data comes from

The Yahoo Finance chart API, one-minute bars with `includePrePost=true`:

```
https://query1.finance.yahoo.com/v8/finance/chart/GPRO?interval=1m&range=1d&includePrePost=true
https://query1.finance.yahoo.com/v1/finance/search?q=GPRO&newsCount=1    # headline, polled every 5 minutes
```

The extended-hours price is taken as the last non-null `close` of the minute series — it is not exposed in `meta`, which only carries the regular session price. The current session is determined by where the tick's timestamp falls within `meta.currentTradingPeriod`. During pre-market and after-hours the percentage is computed against the regular session close, during regular hours against the previous close, matching Yahoo itself.

This is not a tick stream: the latest minute bar updates within the minute, so the real granularity is seconds to tens of seconds rather than strictly the poll interval. For genuine real-time data you would need a WebSocket provider such as Finnhub or Polygon (both require an API key).

Unofficial endpoint with no stability guarantees. Built for personal use.

## Trading 212 balance (optional)

The `extension/` folder holds a Chrome extension that reads the CFD account summary from an open Trading 212 tab and posts it to the widget over loopback (`127.0.0.1:47632`, configurable via `BALANCE_PORT`). The account total then appears in the menu bar in thousands next to the health percentage, with the profit, margin and cash breakdown in the dropdown. Health is colored by level: amber below 40%, red below 20%.

Nothing is scraped by the widget itself and nothing leaves the machine — see `extension/README.md`.

## Computed account figures

Trading 212's CFD platform only updates while its own session is open — after the close its balance, margin and health freeze until the next morning. The widget therefore computes them itself from Yahoo prices, which keep running through pre-market, after-hours and overnight.

Generate the positions file from a Trading 212 CSV export (History → Export):

```bash
./tools/t212-positions.py ~/Downloads/from_2026-01-01_to_2026-09-30_*.csv
```

This writes `positions.json` next to the app: open positions with their units, average entry price and leverage, plus the account cash excluding open-position P/L. Re-run it whenever you open or close positions — an export is a snapshot, not a feed.

While Trading 212's own session is open and the tab is live, its figures are shown as they arrive — that is what the account actually trades on. The moment the session closes or the tab goes away, they freeze, and the computed ones take over.

The arithmetic mirrors the platform's own:

```
bid        = last − sign · spread / 2         # the side a position closes at
ask        = last + sign · spread / 2         # the side it is margined at
value      = Σ  units · bid · fx
margin     = Σ  units · ask · fx / leverage
p/l        = Σ  sign · units · (bid − entry) · fx
result     = p/l − 0.5% · |p/l|               # Trading 212's FX fee
equity     = cash + result
health     = equity < margin  ?  equity / margin × 50
                             :  equity / (equity + margin) × 100
free funds = max(equity − margin, 0)
```

Overnight interest is not part of the result — it is charged to cash daily, and the platform lists it separately. The dropdown also breaks the result down per symbol, the same rows Trading 212 shows under each instrument: result, value and margin.

The two-branch health formula is Trading 212's [account margin status](https://helpcentre.trading212.com/hc/en-us/articles/360007119457-What-does-my-account-margin-status-show); both branches meet at 50%. A margin call email goes out at 45% and positions start closing at 25%.

Spreads matter more than they look: Trading 212 values a long at the bid while Yahoo reports the last trade, near the mid. On 52,000 GPRO units a 0.03 spread is ~17,000 CZK of result. Put the spreads you see on the instrument pages into `SPREADS` in `tools/t212-positions.py`.

Cash is the one input an export cannot keep current, so it is re-pinned automatically: whenever a live reading arrives from the browser extension, cash is set to that equity minus the unrealised P/L computed at the same moment. Between market sessions the widget carries that cash forward and only the prices move.

Cash is only re-pinned during the regular session. Outside it the platform's numbers are frozen at the close, and calibrating against them would drag the computed equity back to that frozen figure — defeating the point.

Accuracy against the platform, measured per symbol on a closed market: value, margin, p/l, FX fee and result all land within **0.03%** of the figures Trading 212 shows. The FX rate it uses turns out to be the market one — `USDCZK=X` reproduced its totals to four digits.

## Targets

Each symbol can carry a take-profit price (`Targets (TP)` in the menu, ⌘T). Enter the price a position would close at — the bid for a long, the same number a Trading 212 TP order takes. A symbol left blank keeps its current price, so a partly filled set still answers "and then what".

The dropdown then gains a second block running the same arithmetic at those prices: the result per symbol, the account value that would follow, and the health, free funds and upside that come with it.

## License

MIT
