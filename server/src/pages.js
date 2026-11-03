// The thank-you page (and its "still going through" / "not found" versions). Plain HTML, no outside files.
import { escapeHtml } from "./email.js";

// "bob.smith@gmail.com" → "b•••@gmail.com"
export function maskEmail(email) {
  const [name, domain] = String(email).split("@");
  if (!name || !domain) return "";
  return `${name[0]}•••@${domain}`;
}

function page(title, body, { refresh = false, status = 200 } = {}) {
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
${refresh ? '<meta http-equiv="refresh" content="5">' : ""}<meta name="robots" content="noindex">
<title>${escapeHtml(title)}</title>
<style>
:root{--bg:#f6f4fb;--card:#fff;--text:#1d1b22;--soft:#6b6773;--box:#f3effd;--line:#e4def3}
@media (prefers-color-scheme:dark){:root{--bg:#141217;--card:#1f1c24;--text:#f2eff7;--soft:#a8a2b3;--box:#2a2533;--line:#38324a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;display:flex;min-height:100vh;align-items:center;justify-content:center;padding:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:32px 28px;max-width:520px;width:100%;box-shadow:0 2px 12px rgba(0,0,0,.06)}
h1{margin:0 0 8px;font-size:26px;background:linear-gradient(90deg,rgb(115,64,242),rgb(242,77,153));-webkit-background-clip:text;background-clip:text;color:transparent}
p{margin:10px 0}.soft{color:var(--soft);font-size:14px}
.key{font:700 clamp(15px,4.6vw,22px)/1.3 Menlo,Consolas,monospace;letter-spacing:.5px;background:var(--box);border-radius:12px;padding:14px 12px;text-align:center;margin:18px 0 12px;user-select:all;word-break:break-all}
button{font:600 15px -apple-system,BlinkMacSystemFont,sans-serif;color:#fff;border:0;border-radius:9px;padding:9px 18px;background:linear-gradient(90deg,rgb(115,64,242),rgb(242,77,153));cursor:pointer}
ol{padding-left:22px;margin:16px 0 0}li{margin:4px 0}
</style></head><body><main class="card">${body}</main></body></html>`;
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex",
      "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'",
    },
  });
}

export function keyPage(key, email, emailed) {
  const sent = emailed && email
    ? `We also emailed it to ${escapeHtml(maskEmail(email))}.`
    : "Save this key somewhere safe (a note or your Passwords app).";
  return page("Your Swoopy Pro key", `<h1>Thank you!</h1>
<p>Here is your Swoopy Pro key. ${sent}</p>
<div class="key" id="key">${escapeHtml(key)}</div>
<button id="copy" type="button">Copy key</button>
<ol class="soft"><li>Open Swoopy and click <b>Unlock Pro</b>.</li><li>Paste the key and click <b>Unlock</b>.</li>
<li>It works on all your Macs, for good.</li></ol>
<script>
document.getElementById("copy").onclick = async () => {
  const b = document.getElementById("copy");
  try { await navigator.clipboard.writeText(document.getElementById("key").textContent); b.textContent = "Copied"; }
  catch (e) { const r = document.createRange(); r.selectNodeContents(document.getElementById("key"));
    getSelection().removeAllRanges(); getSelection().addRange(r); b.textContent = "Press ⌘C to copy"; }
};
</script>`);
}

export function pendingPage() {
  return page("Payment going through", `<h1>Almost there</h1>
<p>Your payment is still going through. This page shows your key as soon as it's done.</p>
<p class="soft">It checks again every few seconds.</p>`, { refresh: true });
}

export function refundedPage() {
  return page("Key turned off", `<h1>Key turned off</h1><p>This payment was refunded, so its key no longer works.</p>`, { status: 410 });
}

export function notFoundPage() {
  return page("Payment not found", `<h1>Payment not found</h1>
<p>We couldn't find that payment. If you just paid, check your email for your key.</p>`, { status: 404 });
}
