const totalEl = document.getElementById("total");
const pnlEl = document.getElementById("pnl");
const gridEl = document.getElementById("grid");
const statusEl = document.getElementById("status");
const portEl = document.getElementById("port");

const money = (value, currency) =>
  `${value.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${currency}`;

async function refresh() {
  const { port = 47632 } = await chrome.storage.local.get({ port: 47632 });
  portEl.value = port;

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.url?.includes("trading212.com")) {
    statusEl.textContent = "Open a Trading 212 tab to read the account.";
    return;
  }

  chrome.tabs.sendMessage(tab.id, { type: "status" }, (account) => {
    if (chrome.runtime.lastError) {
      statusEl.textContent = "Reload the Trading 212 tab to activate the reader.";
      return;
    }
    if (!account) {
      statusEl.textContent =
        "Could not find the account cards. Open the CFD portfolio view where ACCOUNT VALUE is visible.";
      return;
    }

    totalEl.textContent = money(account.balance, account.currency);

    if (account.pnl != null) {
      const up = account.pnl >= 0;
      pnlEl.className = `pnl ${up ? "up" : "down"}`;
      pnlEl.textContent =
        `${up ? "+" : "−"}${money(Math.abs(account.pnl), account.currency)}` +
        (account.pnlPercent != null ? ` (${Math.abs(account.pnlPercent).toFixed(2)}%)` : "");
    }

    const rows = [
      ["Margin", account.margin != null ? money(account.margin, account.currency) : null],
      ["Health", account.health],
      ["Cash", account.cash != null ? money(account.cash, account.currency) : null],
    ].filter(([, value]) => value != null);

    gridEl.innerHTML = "";
    for (const [label, value] of rows) {
      const name = document.createElement("div");
      name.textContent = label;
      const cell = document.createElement("div");
      cell.textContent = value;
      gridEl.append(name, cell);
    }

    statusEl.textContent = `Sending to the menu bar widget on port ${port}.`;
  });
}

portEl.addEventListener("change", () => {
  chrome.storage.local.set({ port: Number(portEl.value) || 47632 });
});

refresh();
