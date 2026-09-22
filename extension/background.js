// The POST happens here, not in the content script: a fetch to http://127.0.0.1 from an
// https page counts as mixed content, while the extension origin may call it directly.
chrome.runtime.onMessage.addListener((message, _sender, respond) => {
  if (message.type !== "balance") return;
  const port = message.port || 47632;
  fetch(`http://127.0.0.1:${port}/`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(message.payload),
  })
    .then(() => respond({ ok: true }))
    .catch((error) => respond({ ok: false, error: String(error) }));
  return true;   // keeps the channel open for the async reply
});
