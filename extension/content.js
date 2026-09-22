// Reads the CFD account summary from the page the user already has open and posts it
// to the widget's loopback endpoint. Nothing is sent anywhere else, no page API is called.

const POLL_MS = 5000;

const HEARTBEAT_MS = 30000;

let port = 47632;
let lastPayload = null;
let lastSentAt = 0;

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

// Trading 212 ships stable data-testid attributes on the portfolio cards, so those
// are the primary anchors; the visible labels are only a fallback.
const TESTIDS = {
  amount: "cfd-portfolio-stats-total-amount",
  currency: "cfd-portfolio-stats-total-currency",
  result: "cfd-portfolio-result-value",
  margin: "cfd-portfolio-margin-widget",
  health: "cfd-portfolio-health-widget",
  cash: "account-cash-widget",
};

const LABELS = {
  margin: ["MARGIN", "TOTAL MARGIN"],
  health: ["HEALTH"],
  cash: ["CASH"],
};

const byTestId = (id) => document.querySelector(`[data-testid="${id}"]`);

// Handles "Kč 177,473.55" as well as "177 473,55 Kč": the last separator is the decimal one.
function parseAmount(text) {
  const cleaned = (text || "").replace(/\u00a0/g, " ").replace(/[^\d.,]/g, "");
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
  const match = (text || "").match(/Kč|[€$£¥₽]|EUR|USD|GBP|CZK/);
  return match ? match[0] : "";
}

// Fallback for the side cards if a testid ever disappears: find the label, then the
// nearest ancestor that actually holds a number.
function byLabel(labels) {
  const wanted = labels.map((label) => label.toUpperCase());
  for (const node of document.querySelectorAll("div, span, p")) {
    if (node.children.length || !wanted.includes(node.textContent.trim().toUpperCase())) continue;
    let card = node.parentElement;
    for (let depth = 0; depth < 5 && card; depth += 1) {
      const rest = card.textContent.replace(node.textContent, "");
      if (/\d/.test(rest)) return rest.trim();
      card = card.parentElement;
    }
  }
  return null;
}

// A card's own label is part of its text, so it is stripped before parsing.
function cardValue(testId, labels) {
  const card = byTestId(testId);
  if (card) {
    const text = card.textContent.replace(new RegExp(labels.join("|"), "i"), "").trim();
    if (/\d/.test(text)) return text;
  }
  return byLabel(labels);
}

// The sign of the result lives in the color and the arrow icon, not in the number.
function profit() {
  const node = byTestId(TESTIDS.result);
  if (!node) return {};
  const text = node.textContent.replace(/\u00a0/g, " ");
  const percent = text.match(/\(\s*(\d+[.,]\d+)\s*%\s*\)/);
  const amount = parseAmount(percent ? text.slice(0, percent.index) : text);
  if (amount === null) return {};

  const rgb = getComputedStyle(node).color.match(/\d+/g)?.map(Number) ?? [0, 0, 0];
  const negative = /[-−↘]/.test(text) || (rgb[0] > rgb[1] + 30 && rgb[0] > rgb[2] + 30);
  const sign = negative ? -1 : 1;
  return {
    pnl: amount * sign,
    pnlPercent: percent ? parseAmount(percent[1]) * sign : null,
  };
}

function readAccount() {
  const amountNode = byTestId(TESTIDS.amount);
  const balance = parseAmount(amountNode?.textContent);
  if (balance === null) return null;

  const currencyNode = byTestId(TESTIDS.currency);
  const margin = cardValue(TESTIDS.margin, LABELS.margin);
  const health = cardValue(TESTIDS.health, LABELS.health);
  const cash = cardValue(TESTIDS.cash, LABELS.cash);

  return {
    balance,
    currency: currencyOf(currencyNode?.textContent) || currencyOf(amountNode.textContent) || "Kč",
    margin: parseAmount(margin),
    health: health ? health.match(/\d+\s*%/)?.[0] ?? null : null,
    cash: parseAmount(cash),
    ...profit(),
  };
}

// --- sending -------------------------------------------------------------

function send(payload) {
  chrome.runtime.sendMessage({ type: "balance", port, payload }, (response) => {
    // The widget may simply not be running; the next tick retries.
    if (chrome.runtime.lastError || !response?.ok) return;
    lastPayload = JSON.stringify(payload);
    lastSentAt = Date.now();
  });
}

function tick() {
  const payload = readAccount();
  if (!payload) return;
  // Unchanged numbers still get resent as a heartbeat: otherwise a quiet market
  // looks the same to the widget as a closed tab, and it marks the data stale.
  const changed = JSON.stringify(payload) !== lastPayload;
  if (changed || Date.now() - lastSentAt > HEARTBEAT_MS) send(payload);
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
