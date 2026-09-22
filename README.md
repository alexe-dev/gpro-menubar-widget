# GPRO menu bar widget

A native macOS menu bar widget showing a stock's current price, **including pre-market and after-hours**, refreshed every 5 seconds.

A single Swift file, no dependencies, no Xcode project — it builds with the system `swiftc`.

```
1.30 ▲0.02% 🌅
```

## What it shows

In the menu bar: the price, the percentage change in color, and an icon for the current trading session — sunrise for pre-market, sun for regular hours, sunset for after-hours, moon when the market is closed.

In the dropdown: the price to 4 decimals with the absolute change, the instrument name and session, the regular session close and the previous close marked with `◂ база` — "base" (the number the percentage is computed from), the day and 52-week ranges, and the timestamps of the last tick and the last poll.

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

Environment variables:

| Variable | Default | Description |
|---|---|---|
| `TICKER` | `GPRO` | Any Yahoo Finance symbol |
| `REFRESH` | `5` | Poll interval in seconds |

```bash
TICKER=AAPL REFRESH=2 open GPRO.app
```

For the launch agent, set these through the plist's `EnvironmentVariables` key.

## Where the data comes from

The Yahoo Finance chart API, one-minute bars with `includePrePost=true`:

```
https://query1.finance.yahoo.com/v8/finance/chart/GPRO?interval=1m&range=1d&includePrePost=true
```

The extended-hours price is taken as the last non-null `close` of the minute series — it is not exposed in `meta`, which only carries the regular session price. The current session is determined by where the tick's timestamp falls within `meta.currentTradingPeriod`. During pre-market and after-hours the percentage is computed against the regular session close, during regular hours against the previous close, matching Yahoo itself.

This is not a tick stream: the latest minute bar updates within the minute, so the real granularity is seconds to tens of seconds rather than strictly the poll interval. For genuine real-time data you would need a WebSocket provider such as Finnhub or Polygon (both require an API key).

Unofficial endpoint with no stability guarantees. Built for personal use.

## License

MIT
