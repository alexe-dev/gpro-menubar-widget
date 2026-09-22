# Trading 212 → menu bar bridge

A Chrome extension that reads the CFD account summary from a Trading 212 tab you already have open and forwards it to the menu bar widget over loopback.

It touches nothing but the rendered page: no private endpoints, no credentials, no traffic leaving the machine. The page is a single-page app, so the numbers only exist in the live DOM — which is why this is a content script rather than an HTTP fetch.

## Install

1. Open `chrome://extensions`, turn on **Developer mode**
2. **Load unpacked** → select this `extension` folder
3. Open Trading 212, go to the CFD portfolio view where `ACCOUNT VALUE` is visible
4. The widget picks the numbers up within a few seconds

## What it reads

`ACCOUNT VALUE` and the profit line under it, plus `MARGIN`, `HEALTH` and `CASH`. Cards are located by those visible labels, not by CSS classes — Trading 212 generates class names that change between releases, the labels do not.

The extension popup shows all five values. The menu bar shows the account total in thousands; the full breakdown lives in the widget's dropdown.

## Limits

The tab has to stay open — minimized or in the background is fine, closed is not. If the numbers stop arriving, the widget marks them `stale` after two minutes rather than showing a frozen figure as current.

If Trading 212 renames those labels, reading breaks and the popup says so. Fixing it means updating `FIELDS` in `content.js`.
