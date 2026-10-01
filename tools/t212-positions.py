#!/usr/bin/env python3
"""Turn Trading 212 CSV exports into the positions file the widget calculates from.

    ./tools/t212-positions.py ~/Downloads/from_2026-01-01_to_*.csv ~/Downloads/from_2026-09-30_to_*.csv

Several exports can be passed at once and are merged: a later export only covers its own
window, so the earlier ones still hold the positions opened before it. Overlapping days are
deduplicated. Writes positions.json next to the app — re-run after trading, since an export
is a snapshot rather than a feed.
"""
import csv
import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

LEVERAGE = 5.0   # 1:5 on equity CFDs; override per symbol below if yours differ

# Trading 212 values a long at the bid while Yahoo reports the last trade, which sits near
# the mid — on a wide spread that difference is real money. Held as a fraction of price,
# since the absolute spread moves with the quote: read SELL/BUY off the instrument page and
# divide the difference by the mid.
# Instruments whose CFD trades in extended hours. For the rest the platform holds the
# regular close until its own session opens, so valuing them at a pre-market price would
# invent movement the account does not have.
EXTENDED_HOURS = {"MU"}

SPREADS = {
    "GPRO": 0.0230,   # 1.29 / 1.32
    "KOD": 0.0015,    # 91.04 / 91.18
    "MU": 0.0029,     # 1060.96 / 1063.99
}


def identity(row):
    """A stable key per record, since exports differ in their column set.

    Comparing whole rows looked sufficient until two exports of the same day disagreed
    on one column, and every shared order was counted twice.
    """
    kind = row["Record Type"]
    if kind == "Order":
        return ("order", row["Order ID"])
    if kind == "Closed position":
        return ("closed", row["Position ID"], row["Order ID"])
    if kind == "Transaction":
        return ("transaction", row.get("Transaction ID", ""))
    if kind == "Interest on cash":
        return ("cash interest", row.get("Cash interest ID", ""), row["Date (UTC)"])
    # Overnight interest carries no id of its own.
    return (kind, row["Date (UTC)"], row["Position ID"], row["Amount (account currency)"])


def parse(paths):
    # Exports overlap at their boundaries, so the same record is collapsed to one.
    seen = set()
    rows = []
    for path in paths:
        for row in csv.DictReader(open(path)):
            key = identity(row)
            if key in seen:
                continue
            seen.add(key)
            rows.append(row)

    closed = {r["Position ID"] for r in rows if r["Record Type"] == "Closed position"}
    live = [
        r for r in rows
        if r["Record Type"] == "Order"
        and r["Intent"] == "OPEN"
        and r["Status"] == "EXECUTED"
        and r["Position ID"] not in closed
    ]

    books = defaultdict(lambda: {"units": 0.0, "cost": 0.0, "count": 0, "currency": "", "direction": ""})
    for r in live:
        units = float(r["Units"])
        price = float(r["Executed price (instrument currency)"])
        book = books[r["Symbol"]]
        book["units"] += units
        book["cost"] += units * price
        book["count"] += 1
        book["currency"] = r["Instrument currency"]
        book["direction"] = r["Direction"]

    # Cash without open-position P/L. A closed position's "Total result" already contains
    # its overnight interest and dividends, so only interest on still-open positions is
    # added separately — counting all of it would double up.
    live_ids = {r["Position ID"] for r in live}
    cash = sum(
        float(r["Amount (account currency)"])
        for r in rows if r["Record Type"] in ("Transaction", "Interest on cash")
    ) + sum(
        float(r["Total result (account currency)"])
        for r in rows if r["Record Type"] == "Closed position"
    ) + sum(
        float(r["Amount (account currency)"])
        for r in rows
        if r["Record Type"] == "Overnight interest" and r["Position ID"] in live_ids
    )

    account_currency = next((r["Account currency"] for r in rows if r["Account currency"]), "CZK")


    return {
        "generated": datetime.now().astimezone().isoformat(timespec="seconds"),
        "accountCurrency": account_currency,
        "cashFallback": round(cash, 2),
        "positions": [
            {
                "symbol": symbol,
                "direction": book["direction"],
                "units": round(book["units"], 4),
                "avgPrice": round(book["cost"] / book["units"], 6),
                "currency": book["currency"],
                "leverage": LEVERAGE,
                "spreadPct": SPREADS.get(symbol, 0.0),
                "extendedHours": symbol in EXTENDED_HOURS,
                "lots": book["count"],
            }
            for symbol, book in sorted(books.items())
        ],
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)

    data = parse(sys.argv[1:])
    out = Path(__file__).resolve().parent.parent / "positions.json"
    out.write_text(json.dumps(data, indent=2) + "\n")

    print(f"{out}")
    for p in data["positions"]:
        print(f"  {p['symbol']:6} {p['direction']:4} {p['units']:>12,.2f} units  avg {p['avgPrice']:.4f} {p['currency']}"
              f"  ({p['lots']} lots, 1:{p['leverage']:.0f}, spread {p['spreadPct'] * 100:.2f}%"
              f"{', extended hours' if p['extendedHours'] else ''})")
    print(f"  cash fallback {data['cashFallback']:,.2f} {data['accountCurrency']}")
    print("  deposits and withdrawals are entered in the widget (⌘N): a CFD export does not"
          " see money moved in from the Invest side")


if __name__ == "__main__":
    main()
