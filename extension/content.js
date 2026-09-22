// Reads the CFD account summary from the page the user already has open and posts it
// to the widget's loopback endpoint. Nothing is sent anywhere else, no page API is called.

const POLL_MS = 5000;

// Cards are found by their visible label: Trading 212's class names are generated
// and change between releases, the wording of these labels does not.
const FIELDS = {
  accountValue: ["ACCOUNT VALUE"],
  margin: ["MARGIN", "TOTAL MARGIN"],
  health: ["HEALTH"],
  cash: ["CASH"],
};

let port = 47632;
let lastPayload = null;

chrome.storage.local.get({ port: 47632 }).then((stored) => {
  port = stored.port;
  start();
});

chrome.storage.onChanged.addListener((changes) => {
  if (changes.port) port = changes.port.newValue;
});

chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message.type === "status") respond(readAccount());
  return true;
});

// --- parsing -------------------------------------------------------------

// Handles both "Kč 177,553.61" and "177 553,61 Kč": the last separator is the decimal one.
function parseAmount(text) {
  const cleaned = text.replace(/[^\d.,]/g, "");
  if (!cleaned) return null;
  const lastComma = cleaned.lastIndexOf(",");
  const lastDot = cleaned.lastIndexOf(".");
  const normalized =
    lastComma > lastDot
      ? cleaned.replace(/\./g, "").replace(",", ".")
      : cleaned.replace(/,/g, "");
  const value = parseFloat(normalized);
  return Number.isFinite(value) ? value : null;
}

function currencyOf(text) {
  const match = text.match(/Kč|[€$£¥₽]|EUR|USD|GBP|CZK/);
  return match ? match[0] : "";
}

function labelledCard(labels) {
  const wanted = labels.map((label) => label.toUpperCase());
  const nodes = document.querySelectorAll("div, span, p, h1, h2, h3, h4, label");
  for (const node of nodes) {
    const text = node.textContent.trim().toUpperCase();
    if (!wanted.includes(text)) continue;
    // The label itself carries no number: walk up until an ancestor holds one.
    let card = node.parentElement;
    for (let depth = 0; depth < 4 && card; depth += 1) {
      const rest = card.textContent.replace(node.textContent, "");
      if (/\d/.test(rest)) return { card, rest: rest.trim() };
      card = card.parentElement;
    }
  }
  return null;
}

function valueFor(labels) {
  const found = labelledCard(labels);
  if (!found) return null;
  return { amount: parseAmount(found.rest), text: found.rest, card: found.card };
}

// The profit line sits under the account value; its sign shows up as an arrow
// or a minus rather than in the number itself, so the color is the tiebreaker.
function profitFrom(accountCard) {
  if (!accountCard) return {};
  for (const node of accountCard.querySelectorAll("*")) {
    const text = node.textContent.trim();
    const percent = text.match(/\(\s*(\d+[.,]\d+)\s*%\s*\)/);
    if (!percent || node.children.length > 3) continue;
    const amount = parseAmount(text.slice(0, percent.index));
    if (amount === null) continue;
    const color = getComputedStyle(node).color;
    const rgb = color.match(/\d+/g)?.map(Number) ?? [0, 0, 0];
    const negative = /[-−↘]/.test(text) || (rgb[0] > rgb[1] + 30 && rgb[0] > rgb[2] + 30);
    return {
      pnl: negative ? -amount : amount,
      pnlPercent: parseAmount(percent[1]) * (negative ? -1 : 1),
    };
  }
  return {};
}

function readAccount() {
  const account = valueFor(FIELDS.accountValue);
  if (!account || account.amount === null) return null;

  const margin = valueFor(FIELDS.margin);
  const health = valueFor(FIELDS.health);
  const cash = valueFor(FIELDS.cash);

  return {
    balance: account.amount,
    currency: currencyOf(account.text) || "Kč",
    label: "Account value",
    margin: margin?.amount ?? null,
    health: health ? health.text.match(/\d+\s*%/)?.[0] ?? null : null,
    cash: cash?.amount ?? null,
    ...profitFrom(account.card),
  };
}

// --- sending -------------------------------------------------------------

function send(payload) {
  chrome.runtime.sendMessage({ type: "balance", port, payload }, (response) => {
    // The widget may simply not be running; the next tick retries.
    if (!chrome.runtime.lastError && response?.ok) lastPayload = JSON.stringify(payload);
  });
}

function tick() {
  const payload = readAccount();
  if (payload && JSON.stringify(payload) !== lastPayload) send(payload);
}

function start() {
  // The page rewrites these numbers itself, so an observer catches changes immediately,
  // while the interval covers re-renders that replace the whole subtree.
  let scheduled = false;
  new MutationObserver(() => {
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      tick();
    }, 500);
  }).observe(document.body, { childList: true, subtree: true, characterData: true });
  setInterval(tick, POLL_MS);
  tick();
}
