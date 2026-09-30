#!/usr/bin/env python3
"""Turn a Trading 212 CSV export into the positions file the widget calculates from.

    ./tools/t212-positions.py ~/Downloads/from_2026-01-01_to_2026-09-30_*.csv

Writes positions.json next to the app. Re-run it after opening or closing positions:
the export is a snapshot, not a feed.
"""
import csv
import json
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

LEVERAGE = 5.0   # 1:5 on equity CFDs; override per symbol below if yours differ

# Trading 212 values a long at the bid while Yahoo reports the last trade, which sits
# near the mid — on a wide spread that difference is real money. Read SELL/BUY off the
# instrument page and put the difference here.
SPREADS = {"GPRO": 0.03, "KOD": 0.14}


def parse(path):
    rows = list(csv.DictReader(open(path)))

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

    # Money in and out of this account. A CFD export only sees what reached the CFD side,
    # so the platform's own History screen (which spans the whole account) can differ —
    # the widget lets you override the net figure.
    deposits = sum(float(r["Amount (account currency)"]) for r in rows
                   if r["Record Type"] == "Transaction" and r["Transaction type"] == "Deposit")
    withdrawals = sum(float(r["Amount (account currency)"]) for r in rows
                      if r["Record Type"] == "Transaction" and r["Transaction type"] == "Withdrawal")

    return {
        "generated": datetime.now().astimezone().isoformat(timespec="seconds"),
        "accountCurrency": account_currency,
        "cashFallback": round(cash, 2),
        "deposits": round(deposits, 2),
        "withdrawals": round(withdrawals, 2),
        "netDeposits": round(deposits + withdrawals, 2),
        "positions": [
            {
                "symbol": symbol,
                "direction": book["direction"],
                "units": round(book["units"], 4),
                "avgPrice": round(book["cost"] / book["units"], 6),
                "currency": book["currency"],
                "leverage": LEVERAGE,
                "spread": SPREADS.get(symbol, 0.0),
                "lots": book["count"],
            }
            for symbol, book in sorted(books.items())
        ],
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)

    data = parse(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / "positions.json"
    out.write_text(json.dumps(data, indent=2) + "\n")

    print(f"{out}")
    for p in data["positions"]:
        print(f"  {p['symbol']:6} {p['direction']:4} {p['units']:>12,.2f} units  avg {p['avgPrice']:.4f} {p['currency']}"
              f"  ({p['lots']} lots, 1:{p['leverage']:.0f}, spread {p['spread']})")
    print(f"  cash fallback {data['cashFallback']:,.2f} {data['accountCurrency']}")
    print(f"  deposits {data['deposits']:,.2f}  withdrawals {data['withdrawals']:,.2f}"
          f"  net {data['netDeposits']:,.2f}")


if __name__ == "__main__":
    main()
