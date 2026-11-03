// Swoopy Pro: the unlock server (a Cloudflare Worker with one KV store, "PRO").
//   POST /stripe-webhook   Stripe's message after a payment: make the key, save it, email it. A full refund turns
//                          the key off.
//   GET  /thanks?session_id=…   the page Stripe sends the buyer to: shows the key.
//   POST /activate         the app sends { key, machine }: answers { ok: true, token } (a signed token).
//   POST /check            the app sends { key, machine }: answers { ok: true, status: active | revoked | unknown }.
// Saved in KV: "key:XXXXX-…" → the key's record; "email:<email>" → the keys bought with that email (to find a lost
// key). Secrets (wrangler secret put): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, SIGNING_KEY, KEY_SECRET,
// RESEND_API_KEY. See README.md.
import { keyId, makeKey, readKey } from "./key.js";
import { sendKeyEmail, emailReady } from "./email.js";
import { keyPage, notFoundPage, pendingPage, refundedPage } from "./pages.js";
import { sessionCounts, stripeGet, verifyStripeSignature } from "./stripe.js";
import { signToken } from "./token.js";

const MACHINES_KEPT = 100;  // Macs listed per key (the count keeps going past this)

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

// Cloudflare's rate limit (10 a minute per internet address and address type). Without the binding (local tests)
// everything is let through.
async function allowed(env, request, kind) {
  if (!env.RATE_LIMIT) return true;
  const address = request.headers.get("CF-Connecting-IP") || "unknown";
  const { success } = await env.RATE_LIMIT.limit({ key: `${kind}:${address}` });
  return success;
}

async function record(env, key) {
  return env.PRO.get(`key:${key}`, "json");
}

async function save(env, entry) {
  await env.PRO.put(`key:${entry.key}`, JSON.stringify(entry));
}

// Makes (or finds) the key for a paid Checkout Session. Returns null when the session shouldn't get one.
export async function fulfill(env, session) {
  if (!sessionCounts(env, session)) return null;
  const key = await makeKey(env.KEY_SECRET, session.id);
  const existing = await record(env, key);
  if (existing) return existing;
  const email = String(session.customer_details?.email || session.customer_email || "").trim();
  const entry = {
    key,
    email,
    created: new Date().toISOString(),
    session: session.id,
    paymentIntent: typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id ?? null,
    mode: session.livemode ? "live" : "test",
    revoked: false,
    emailed: false,
    macs: 0,
    machines: {},
  };
  await save(env, entry);
  if (email) {
    const indexKey = `email:${email.toLowerCase()}`;
    const keys = (await env.PRO.get(indexKey, "json")) || [];
    if (!keys.includes(key)) await env.PRO.put(indexKey, JSON.stringify([...keys, key]));
  }
  return entry;
}

async function webhook(request, env) {
  const raw = await request.text();
  if (!(await verifyStripeSignature(raw, request.headers.get("Stripe-Signature"), env.STRIPE_WEBHOOK_SECRET))) {
    return json({ ok: false, error: "signature" }, 400);
  }
  const event = JSON.parse(raw);
  const object = event.data?.object;
  if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") {
    const entry = await fulfill(env, object);
    if (!entry) return json({ ok: true, note: "no key for this session" });
    // Email once. If Resend fails, answer 500 so Stripe sends the message again later (it retries for 3 days).
    if (!entry.emailed && entry.email && emailReady(env)) {
      await sendKeyEmail(env, entry.email, entry.key, entry.session);
      await save(env, { ...entry, emailed: true });
    }
    return json({ ok: true });
  }
  if (event.type === "charge.refunded" && object?.refunded && object.payment_intent) {
    // A full refund: find the payment's Checkout Session, and so its key, and turn the key off.
    const intent = typeof object.payment_intent === "string" ? object.payment_intent : object.payment_intent.id;
    const sessions = await stripeGet(env, `checkout/sessions?payment_intent=${encodeURIComponent(intent)}`);
    for (const session of sessions?.data ?? []) {
      const entry = await record(env, await makeKey(env.KEY_SECRET, session.id));
      if (entry && !entry.revoked) await save(env, { ...entry, revoked: true, revokedAt: new Date().toISOString() });
    }
    return json({ ok: true });
  }
  return json({ ok: true, note: "ignored" });
}

async function thanks(request, env, url) {
  const sessionId = url.searchParams.get("session_id") || "";
  if (!/^cs_(test|live)_[A-Za-z0-9]{8,250}$/.test(sessionId)) return notFoundPage();
  if (!(await allowed(env, request, "thanks"))) return pendingPage();
  let entry = await record(env, await makeKey(env.KEY_SECRET, sessionId));
  if (!entry) {
    // Stripe's message may not be here yet: ask Stripe about the session directly.
    const session = await stripeGet(env, `checkout/sessions/${sessionId}`);
    if (!session) return notFoundPage();
    if (session.status === "open" || session.payment_status === "unpaid") return pendingPage();
    entry = await fulfill(env, session);
    if (!entry) return notFoundPage();
  }
  if (entry.revoked) return refundedPage();
  return keyPage(entry.key, entry.email, emailReady(env));
}

// Reads { key, machine } from the app. Returns { key } or a Response with the problem.
async function readRequest(request) {
  let body;
  try {
    body = await request.json();
  } catch {
    return { problem: json({ ok: false, error: "bad-request" }, 400) };
  }
  const machine = String(body?.machine ?? "");
  if (!/^[0-9a-f]{32}$/.test(machine)) return { problem: json({ ok: false, error: "bad-request" }, 400) };
  const read = await readKey(body?.key);
  if (!read.ok) return { problem: json({ ok: false, error: "typo" }, 400) };
  return { key: read.key, machine };
}

async function activate(request, env) {
  if (!(await allowed(env, request, "activate"))) return json({ ok: false, error: "rate-limited" }, 429);
  const { key, machine, problem } = await readRequest(request);
  if (problem) return problem;
  const entry = await record(env, key);
  if (!entry) return json({ ok: false, error: "not-found" }, 404);
  if (entry.revoked) return json({ ok: false, error: "revoked" }, 403);
  if (entry.mode === "test" && env.ALLOW_TEST_KEYS !== "true") return json({ ok: false, error: "test-key" }, 403);
  // Note the Mac (no limit). Only a new Mac is written, so reinstalling costs nothing.
  if (!entry.machines?.[machine]) {
    const machines = { ...(entry.machines || {}) };
    if (Object.keys(machines).length < MACHINES_KEPT) machines[machine] = new Date().toISOString();
    await save(env, { ...entry, machines, macs: (entry.macs || 0) + 1, lastActivated: new Date().toISOString() });
  }
  const token = await signToken(env.SIGNING_KEY, {
    v: 1,
    p: "pitch-shift-pro",
    k: await keyId(key),
    m: machine,
    t: Math.floor(Date.now() / 1000),
    x: entry.mode,
  });
  return json({ ok: true, token });
}

async function check(request, env) {
  if (!(await allowed(env, request, "check"))) return json({ ok: false, error: "rate-limited" }, 429);
  const { key, problem } = await readRequest(request);
  if (problem) return problem;
  const entry = await record(env, key);
  return json({ ok: true, status: !entry ? "unknown" : entry.revoked ? "revoked" : "active" });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;
    try {
      switch (route) {
        case "POST /stripe-webhook": return await webhook(request, env);
        case "GET /thanks": return await thanks(request, env, url);
        case "POST /activate": return await activate(request, env);
        case "POST /check": return await check(request, env);
        case "GET /": return new Response("Swoopy Pro\n", { headers: { "Content-Type": "text/plain" } });
        default: return json({ ok: false, error: "not-found" }, 404);
      }
    } catch (error) {
      console.error(`${route} failed: ${error?.message ?? error}`);
      // The buyer's page tries again by itself a few seconds later.
      if (route === "GET /thanks") return pendingPage();
      return json({ ok: false, error: "server" }, 500);
    }
  },
};
