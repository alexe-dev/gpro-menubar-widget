# Trading 212 → menu bar bridge

A Chrome extension that reads the CFD account summary from a Trading 212 tab you already have open and forwards it to the menu bar widget over loopback.

It touches nothing but the rendered page: no private endpoints, no credentials, no traffic leaving the machine. The page is a single-page app, so the numbers only exist in the live DOM — which is why this is a content script rather than an HTTP fetch.

## Install

1. Open `chrome://extensions`, turn on **Developer mode**
2. **Load unpacked** → select this `extension` folder
3. Open Trading 212, go to the CFD portfolio view where `ACCOUNT VALUE` is visible
4. The widget picks the numbers up within a few seconds

## What it reads

`ACCOUNT VALUE` and the result line under it, plus `MARGIN`, `HEALTH` and `CASH`.

Cards are anchored on the `data-testid` attributes Trading 212 puts on them (`cfd-portfolio-stats-total-amount`, `cfd-portfolio-result-value`, `cfd-portfolio-margin-widget`, `cfd-portfolio-health-widget`, `account-cash-widget`), with a lookup by visible label as a fallback. CSS class names are generated per release and are never used.

The result is shown without a sign — the loss is conveyed by red text and a down arrow — so the sign is taken from the element's computed color.

The extension popup shows all five values. The menu bar shows the account total in thousands; the full breakdown lives in the widget's dropdown.

## Limits

The tab has to stay open **and visible**. In a background tab the browser throttles timers, Arc may put the tab to sleep, and Trading 212 itself stops repainting — so the numbers freeze at their last value. The extension reports `hidden: true` in that case and the widget marks the figures with a sleep icon instead of pretending they are current, then refreshes the moment the tab regains focus.

Keeping Trading 212 in its own window on a separate desktop works: a window that is merely covered still counts as visible, a minimized or background tab does not. In Arc, also exclude the site from tab sleeping. Unchanged numbers are resent every 30 seconds as a heartbeat, so the widget can tell a quiet account from a closed tab; if nothing arrives for 90 seconds it marks the data stale rather than showing a frozen figure as current.

If Trading 212 renames the test ids and the labels together, reading breaks and the popup says so. Fixing it means updating `TESTIDS` / `LABELS` in `content.js`.
