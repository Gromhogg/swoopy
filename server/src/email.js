// Emails the key to the buyer through Resend (free plan: 3,000 emails a month, 100 a day; needs a domain of your own).
// Without RESEND_API_KEY and EMAIL_FROM nothing is sent, and the thank-you page tells the buyer to save the key.
export function emailReady(env) {
  return Boolean(env.RESEND_API_KEY && env.EMAIL_FROM);
}

export function keyEmail(env, key) {
  const help = env.SUPPORT_EMAIL ? `\n\nQuestions? Write to ${env.SUPPORT_EMAIL}.` : "";
  const text = `Thank you for buying Swoopy Pro!

Your key:

${key}

In Swoopy, click Unlock Pro, paste the key and click Unlock. It works on all your Macs, for good.${help}`;
  const html = `<div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;color:#222;line-height:1.5">
<p>Thank you for buying Swoopy Pro!</p>
<p>Your key:</p>
<p style="font-family:Menlo,Consolas,monospace;font-size:20px;font-weight:bold;letter-spacing:1px;padding:12px 16px;border-radius:10px;background:#f3effd;display:inline-block">${key}</p>
<p>In Swoopy, click <b>Unlock Pro</b>, paste the key and click <b>Unlock</b>. It works on all your Macs, for good.</p>
${env.SUPPORT_EMAIL ? `<p style="color:#666">Questions? Write to ${escapeHtml(env.SUPPORT_EMAIL)}.</p>` : ""}
</div>`;
  return { subject: "Your Swoopy Pro key", text, html };
}

export function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

// Sends the key. `tag` (the Stripe session id) stops Resend from sending the same email twice.
// Returns true when sent, false when email isn't set up; throws when Resend refuses.
export async function sendKeyEmail(env, to, key, tag) {
  if (!emailReady(env)) return false;
  const { subject, text, html } = keyEmail(env, key);
  const message = { from: env.EMAIL_FROM, to: [to], subject, text, html };
  if (env.SUPPORT_EMAIL) message.reply_to = env.SUPPORT_EMAIL;
  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `pitch-shift-pro-${tag}`,
    },
    body: JSON.stringify(message),
  });
  if (!response.ok) throw new Error(`Resend answered ${response.status}: ${(await response.text()).slice(0, 200)}`);
  return true;
}
