#!/usr/bin/env python3
"""Publish what the phone needs into a private gist.

    ./tools/publish-sync.py            # update (or create) the gist
    ./tools/publish-sync.py --print    # just show the payload

Positions come from positions.json, everything else from the widget's own settings,
so the cash figure is the one calibrated against the platform — the phone cannot
calibrate by itself.
"""
import json
import plistlib
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GIST_FILE = "gpro-sync.json"
GIST_ID_PATH = ROOT / ".gist-id"
DEFAULTS = Path.home() / "Library/Preferences/local.gpro.widget.plist"


def settings():
    if not DEFAULTS.exists():
        return {}
    with DEFAULTS.open("rb") as handle:
        return plistlib.load(handle)


def payload():
    positions = json.loads((ROOT / "positions.json").read_text())
    prefs = settings()

    return {
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "accountCurrency": positions.get("accountCurrency", "CZK"),
        # The platform-calibrated cash, falling back to what the export implied.
        "cash": prefs.get("cashCalibrated", positions.get("cashFallback", 0)),
        "deposits": prefs.get("depositsTotal", 0),
        "withdrawals": prefs.get("withdrawalsTotal", 0),
        "symbols": [prefs.get("ticker", "GPRO"), prefs.get("ticker2", "KOD")],
        "targets": dict(prefs.get("takeProfit", {})),
        "positions": positions["positions"],
    }


def publish(data):
    body = json.dumps(data, indent=2)
    tmp = ROOT / GIST_FILE
    tmp.write_text(body + "\n")

    try:
        # A gist that has been deleted — after a leak, say — must not stop the publish.
        existing = GIST_ID_PATH.read_text().strip() if GIST_ID_PATH.exists() else ""
        alive = existing and subprocess.run(["gh", "api", f"gists/{existing}"],
                                            capture_output=True).returncode == 0
        if alive:
            gist_id = existing
            subprocess.run(["gh", "gist", "edit", gist_id, "-f", GIST_FILE, str(tmp)], check=True)
        else:
            out = subprocess.run(
                ["gh", "gist", "create", str(tmp), "-d", "GPRO widget sync"],
                check=True, capture_output=True, text=True).stdout.strip()
            gist_id = out.rsplit("/", 1)[-1]
            GIST_ID_PATH.write_text(gist_id + "\n")
        return gist_id
    finally:
        tmp.unlink(missing_ok=True)


def main():
    data = payload()
    if "--print" in sys.argv:
        print(json.dumps(data, indent=2))
        return

    gist_id = publish(data)
    # The id is what the phone wants: it reads the gist through the API, where a raw CDN
    # edge cannot serve a stale 404, and the id survives every republish.
    print(f"gist id  {gist_id}")
    print(f"page     https://gist.github.com/{gist_id}")


if __name__ == "__main__":
    main()
