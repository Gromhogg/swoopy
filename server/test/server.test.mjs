// Tests for the unlock server, run with: node --test   (in server/). No network: KV, Stripe and Resend are stand-ins.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import worker, { fulfill } from "../src/index.js";
import { ALPHABET, checkPart, keyId, makeKey, readKey } from "../src/key.js";
import { verifyStripeSignature } from "../src/stripe.js";
import { fromBase64 } from "../src/token.js";
import { maskEmail } from "../src/pages.js";
import { MemoryKV } from "./memory-kv.mjs";

const pair = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
const signingKey = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
const MACHINE = "0123456789abcdef0123456789abcdef";
const OTHER_MACHINE = "fedcba9876543210fedcba9876543210";

let env, calls, stripeSessions, resendFails;

function paidSession(id, extra = {}) {
  return {
    id, object: "checkout.session", status: "complete", payment_status: "paid", livemode: false,
    customer_details: { email: "Buyer@Example.com" }, payment_intent: `pi_${id.slice(-6)}`, payment_link: "plink_test_1",
    amount_total: 500, currency: "usd", ...extra,
  };
}

beforeEach(() => {
  env = {
    PRO: new MemoryKV(),
    KEY_SECRET: "test-key-secret",
    SIGNING_KEY: signingKey,
    STRIPE_WEBHOOK_SECRET: "whsec_test_secret",
    STRIPE_SECRET_KEY: "rk_test_123",
    RESEND_API_KEY: "re_test_123",
    EMAIL_FROM: "Swoopy <keys@example.com>",
    ALLOW_TEST_KEYS: "true",
  };
  calls = [];
  stripeSessions = new Map();
  resendFails = false;
  // Stand-ins for Stripe's API and Resend.
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    const u = new URL(url);
    if (u.host === "api.stripe.com") {
      assert.equal(init.headers.Authorization, "Bearer rk_test_123");
      const listMatch = u.pathname === "/v1/checkout/sessions" && u.searchParams.get("payment_intent");
      if (listMatch) {
        const data = [...stripeSessions.values()].filter((s) => s.payment_intent === listMatch);
        return Response.json({ object: "list", data });
      }
      const id = u.pathname.split("/").pop();
      return stripeSessions.has(id) ? Response.json(stripeSessions.get(id)) : Response.json({ error: {} }, { status: 404 });
    }
    if (u.host === "api.resend.com") {
      return resendFails ? new Response("nope", { status: 500 }) : Response.json({ id: "email_1" });
    }
    throw new Error(`unexpected fetch ${url}`);
  };
});

function stripeHeader(body, secret = env.STRIPE_WEBHOOK_SECRET, time = Math.floor(Date.now() / 1000)) {
  const signature = createHmac("sha256", secret).update(`${time}.${body}`).digest("hex");
  return `t=${time},v1=${signature}`;
}

async function call(method, path, { body, headers = {} } = {}) {
  const init = { method, headers };
  if (body !== undefined) init.body = typeof body === "string" ? body : JSON.stringify(body);
  return worker.fetch(new Request(`https://pro.test${path}`, init), env);
}

async function sendEvent(type, object, options = {}) {
  const body = JSON.stringify({ id: "evt_1", type, livemode: false, data: { object } });
  return call("POST", "/stripe-webhook", { body, headers: { "Stripe-Signature": options.header ?? stripeHeader(body) } });
}

async function verifyToken(token) {
  const [body, signature] = token.split(".");
  const ok = await crypto.subtle.verify({ name: "Ed25519" }, pair.publicKey, fromBase64(signature), new TextEncoder().encode(body));
  return { ok, payload: JSON.parse(new TextDecoder().decode(fromBase64(body))) };
}

const emails = () => calls.filter((c) => c.url.startsWith("https://api.resend.com"));

// --- keys ---

test("keys: 25 characters in 5 groups, only the 31 clear characters, check part right", async () => {
  const seen = new Set();
  for (let i = 0; i < 200; i++) {
    const key = await makeKey("secret", `cs_test_${i}`);
    assert.match(key, /^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{5}(-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{5}){4}$/);
    assert.equal((await readKey(key)).ok, true);
    seen.add(key);
  }
  assert.equal(seen.size, 200);
  assert.equal(ALPHABET.length, 31);
  for (const c of "01ILO") assert.ok(!ALPHABET.includes(c));
});

test("keys: the same payment always gives the same key; another secret gives another", async () => {
  assert.equal(await makeKey("s", "cs_test_a"), await makeKey("s", "cs_test_a"));
  assert.notEqual(await makeKey("s", "cs_test_a"), await makeKey("s", "cs_test_b"));
  assert.notEqual(await makeKey("s", "cs_test_a"), await makeKey("t", "cs_test_a"));
});

test("keys: fixed examples never change (changing them would break every key sold)", async () => {
  // Also checked by the Mac app's own check (Sources/Pro.swift) in notes/paid-unlock-plan.md's test steps.
  assert.equal(await makeKey("test-key-secret", "cs_test_example"), "FQH6E-GT28H-MM9M6-3PNV8-JE5JA");
  assert.equal(await checkPart("23456789ABCDEFGHJKMNP"), "KJRU");
  assert.equal(await keyId("FQH6E-GT28H-MM9M6-3PNV8-JE5JA"), "87da2a255ef91aa8bf43db4693b87082");
});

test("keys: every one-character typo is caught offline", async () => {
  const key = await makeKey("secret", "cs_test_typo");
  const raw = key.replace(/-/g, "");
  let caught = 0, tried = 0;
  for (let i = 0; i < raw.length; i++) {
    for (const c of ALPHABET) {
      if (c === raw[i]) continue;
      tried += 1;
      if (!(await readKey(raw.slice(0, i) + c + raw.slice(i + 1))).ok) caught += 1;
    }
  }
  assert.equal(caught, tried);
  // Two neighbours swapped:
  for (let i = 0; i < raw.length - 1; i++) {
    if (raw[i] === raw[i + 1]) continue;
    const swapped = raw.slice(0, i) + raw[i + 1] + raw[i] + raw.slice(i + 2);
    assert.equal((await readKey(swapped)).ok, false);
  }
});

test("keys: small letters, spaces and missing dashes are fine; wrong length or characters are not", async () => {
  const key = await makeKey("secret", "cs_test_read");
  assert.deepEqual(await readKey(key.toLowerCase().replace(/-/g, " ")), { ok: true, key });
  assert.deepEqual(await readKey(` ${key.replace(/-/g, "")}\n`), { ok: true, key });
  assert.equal((await readKey(key.slice(0, -1))).reason, "length");
  assert.equal((await readKey("O" + key.slice(1))).reason, "characters");
  assert.equal((await readKey(null)).reason, "length");
});

// --- Stripe webhook ---

test("webhook: Stripe's signature is checked (wrong secret, old message, missing header)", async () => {
  const body = "{}";
  const now = Math.floor(Date.now() / 1000);
  assert.equal(await verifyStripeSignature(body, stripeHeader(body), env.STRIPE_WEBHOOK_SECRET), true);
  assert.equal(await verifyStripeSignature(body, stripeHeader(body, "whsec_other"), env.STRIPE_WEBHOOK_SECRET), false);
  assert.equal(await verifyStripeSignature(body, stripeHeader(body, env.STRIPE_WEBHOOK_SECRET, now - 600), env.STRIPE_WEBHOOK_SECRET), false);
  assert.equal(await verifyStripeSignature(body, null, env.STRIPE_WEBHOOK_SECRET), false);
  assert.equal(await verifyStripeSignature(body + " ", stripeHeader(body), env.STRIPE_WEBHOOK_SECRET), false);
  // A header with an old v0 and a second v1 still works when one v1 is right.
  const header = stripeHeader(body).replace("v1=", "v0=abc,v1=dead,v1=");
  assert.equal(await verifyStripeSignature(body, header, env.STRIPE_WEBHOOK_SECRET), true);

  const session = paidSession("cs_test_forged");
  const response = await sendEvent("checkout.session.completed", session, { header: stripeHeader("{}", "whsec_wrong") });
  assert.equal(response.status, 400);
  assert.equal(env.PRO.data.size, 0);
});

test("webhook: a paid session makes a key, saves it and emails it once", async () => {
  const session = paidSession("cs_test_a1b2c3d4e5");
  const response = await sendEvent("checkout.session.completed", session);
  assert.equal(response.status, 200);
  const key = await makeKey(env.KEY_SECRET, session.id);
  const saved = await env.PRO.get(`key:${key}`, "json");
  assert.equal(saved.email, "Buyer@Example.com");
  assert.equal(saved.session, session.id);
  assert.equal(saved.paymentIntent, session.payment_intent);
  assert.equal(saved.mode, "test");
  assert.equal(saved.emailed, true);
  assert.deepEqual(await env.PRO.get("email:buyer@example.com", "json"), [key]);
  assert.equal(emails().length, 1);
  const sent = JSON.parse(emails()[0].init.body);
  assert.deepEqual(sent.to, ["Buyer@Example.com"]);
  assert.ok(sent.text.includes(key) && sent.html.includes(key));
  assert.equal(emails()[0].init.headers["Idempotency-Key"], `pitch-shift-pro-${session.id}`);
  // Stripe sends the same message again: same key, no second email, nothing new saved.
  const writes = env.PRO.writes;
  assert.equal((await sendEvent("checkout.session.completed", session)).status, 200);
  assert.equal(emails().length, 1);
  assert.equal(env.PRO.writes, writes);
});

test("webhook: unpaid, unfinished or other-product sessions get no key", async () => {
  env.STRIPE_PAYMENT_LINK = "plink_test_1";
  await sendEvent("checkout.session.completed", paidSession("cs_test_unpaid1", { payment_status: "unpaid" }));
  await sendEvent("checkout.session.completed", paidSession("cs_test_open001", { status: "open" }));
  await sendEvent("checkout.session.completed", paidSession("cs_test_other01", { payment_link: "plink_other" }));
  await sendEvent("payment_intent.created", { id: "pi_1" });
  assert.equal(env.PRO.data.size, 0);
  assert.equal(emails().length, 0);
  // A delayed payment that later succeeds does get one.
  await sendEvent("checkout.session.async_payment_succeeded", paidSession("cs_test_later01"));
  assert.equal(env.PRO.data.size, 2); // the key and the email list
});

test("webhook: when Resend fails, Stripe is asked to send again, and the retry emails", async () => {
  const session = paidSession("cs_test_mailfail");
  resendFails = true;
  assert.equal((await sendEvent("checkout.session.completed", session)).status, 500);
  const key = await makeKey(env.KEY_SECRET, session.id);
  assert.equal((await env.PRO.get(`key:${key}`, "json")).emailed, false);
  resendFails = false;
  assert.equal((await sendEvent("checkout.session.completed", session)).status, 200);
  assert.equal((await env.PRO.get(`key:${key}`, "json")).emailed, true);
});

test("webhook: without email set up, keys are still made and nothing is sent", async () => {
  delete env.RESEND_API_KEY;
  const session = paidSession("cs_test_noemail1");
  assert.equal((await sendEvent("checkout.session.completed", session)).status, 200);
  assert.equal(emails().length, 0);
  const html = await (await call("GET", `/thanks?session_id=${session.id}`)).text();
  assert.ok(html.includes("Save this key"));
});

test("webhook: a full refund turns the key off; a part refund doesn't", async () => {
  const session = paidSession("cs_test_refund01");
  stripeSessions.set(session.id, session);
  await sendEvent("checkout.session.completed", session);
  const key = await makeKey(env.KEY_SECRET, session.id);
  await sendEvent("charge.refunded", { id: "ch_1", object: "charge", refunded: false, amount_refunded: 100, payment_intent: session.payment_intent });
  assert.equal((await env.PRO.get(`key:${key}`, "json")).revoked, false);
  await sendEvent("charge.refunded", { id: "ch_1", object: "charge", refunded: true, amount_refunded: 500, payment_intent: session.payment_intent });
  assert.equal((await env.PRO.get(`key:${key}`, "json")).revoked, true);
  const answer = await call("POST", "/activate", { body: { key, machine: MACHINE } });
  assert.equal(answer.status, 403);
  assert.equal((await answer.json()).error, "revoked");
  assert.equal((await (await call("GET", `/thanks?session_id=${session.id}`)).text()).includes("refunded"), true);
});

// --- thank-you page ---

test("thanks: shows the key made by the webhook", async () => {
  const session = paidSession("cs_test_thanks01");
  await sendEvent("checkout.session.completed", session);
  const response = await call("GET", `/thanks?session_id=${session.id}`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.equal(response.headers.get("Referrer-Policy"), "no-referrer");
  const html = await response.text();
  assert.ok(html.includes(await makeKey(env.KEY_SECRET, session.id)));
  assert.ok(html.includes("We also emailed it to B•••@Example.com"));
  assert.equal(calls.filter((c) => c.url.startsWith("https://api.stripe.com")).length, 0);
});

test("thanks: before Stripe's message arrives, it asks Stripe and makes the same key", async () => {
  const session = paidSession("cs_test_early001");
  stripeSessions.set(session.id, session);
  const html = await (await call("GET", `/thanks?session_id=${session.id}`)).text();
  const key = await makeKey(env.KEY_SECRET, session.id);
  assert.ok(html.includes(key));
  assert.equal(emails().length, 0); // the webhook does the email
  await sendEvent("checkout.session.completed", session);
  assert.equal(emails().length, 1);
  assert.deepEqual(await env.PRO.get("email:buyer@example.com", "json"), [key]); // one key, not two
});

test("thanks: unpaid shows 'still going through'; unknown and bad ids show 'not found'", async () => {
  stripeSessions.set("cs_test_pending1", paidSession("cs_test_pending1", { payment_status: "unpaid" }));
  const pending = await call("GET", "/thanks?session_id=cs_test_pending1");
  assert.ok((await pending.text()).includes("still going through"));
  assert.equal((await call("GET", "/thanks?session_id=cs_test_unknown1")).status, 404);
  assert.equal((await call("GET", "/thanks?session_id=<script>")).status, 404);
  assert.equal((await call("GET", "/thanks")).status, 404);
  assert.equal(env.PRO.data.size, 0);
});

test("thanks: Stripe being down shows the page that tries again", async () => {
  globalThis.fetch = async () => new Response("down", { status: 503 });
  const response = await call("GET", "/thanks?session_id=cs_test_down0001");
  assert.ok((await response.text()).includes("still going through"));
});

// --- activation ---

async function boughtKey(id = "cs_test_buy00001", extra = {}) {
  await fulfill(env, paidSession(id, extra));
  return makeKey(env.KEY_SECRET, id);
}

test("activate: a good key gets a token signed for this key and this Mac", async () => {
  const key = await boughtKey();
  const response = await call("POST", "/activate", { body: { key: key.toLowerCase(), machine: MACHINE } });
  assert.equal(response.status, 200);
  const answer = await response.json();
  assert.equal(answer.ok, true);
  const { ok, payload } = await verifyToken(answer.token);
  assert.equal(ok, true);
  assert.equal(payload.v, 1);
  assert.equal(payload.p, "pitch-shift-pro");
  assert.equal(payload.k, await keyId(key));
  assert.equal(payload.m, MACHINE);
  assert.equal(payload.x, "test");
  assert.ok(Math.abs(payload.t - Date.now() / 1000) < 10);
  // Changing one character of the token breaks the signature.
  const [body, signature] = answer.token.split(".");
  const flipped = body.slice(0, 10) + (body[10] === "A" ? "B" : "A") + body.slice(11);
  const broken = await crypto.subtle.verify({ name: "Ed25519" }, pair.publicKey, fromBase64(signature), new TextEncoder().encode(flipped));
  assert.equal(broken, false);
});

test("activate: any number of Macs; the same Mac again writes nothing", async () => {
  const key = await boughtKey();
  await call("POST", "/activate", { body: { key, machine: MACHINE } });
  let writes = env.PRO.writes;
  await call("POST", "/activate", { body: { key, machine: MACHINE } });
  assert.equal(env.PRO.writes, writes);
  await call("POST", "/activate", { body: { key, machine: OTHER_MACHINE } });
  const saved = await env.PRO.get(`key:${key}`, "json");
  assert.equal(saved.macs, 2);
  assert.deepEqual(Object.keys(saved.machines).sort(), [MACHINE, OTHER_MACHINE].sort());
  for (let i = 0; i < 150; i++) {
    const machine = i.toString(16).padStart(32, "a");
    assert.equal((await call("POST", "/activate", { body: { key, machine } })).status, 200);
  }
  const after = await env.PRO.get(`key:${key}`, "json");
  assert.equal(after.macs, 152);
  assert.equal(Object.keys(after.machines).length, 100);
});

test("activate: typos, unknown keys, test keys when switched off, bad requests", async () => {
  const key = await boughtKey();
  const typo = key.slice(0, 3) + (key[3] === "A" ? "B" : "A") + key.slice(4);
  const answers = [
    [{ key: typo, machine: MACHINE }, 400, "typo"],
    [{ key: await makeKey(env.KEY_SECRET, "cs_test_neverpaid"), machine: MACHINE }, 404, "not-found"],
    [{ key, machine: "not-a-mac-id" }, 400, "bad-request"],
    [{ key }, 400, "bad-request"],
  ];
  for (const [body, status, error] of answers) {
    const response = await call("POST", "/activate", { body });
    assert.equal(response.status, status, error);
    assert.equal((await response.json()).error, error);
  }
  assert.equal((await call("POST", "/activate", { body: "not json" })).status, 400);
  env.ALLOW_TEST_KEYS = "false";
  const response = await call("POST", "/activate", { body: { key, machine: MACHINE } });
  assert.equal(response.status, 403);
  assert.equal((await response.json()).error, "test-key");
  const live = await boughtKey("cs_live_buy00001", { livemode: true });
  assert.equal((await call("POST", "/activate", { body: { key: live, machine: MACHINE } })).status, 200);
});

test("activate and check: the rate limit answers 429", async () => {
  const key = await boughtKey();
  const seen = [];
  env.RATE_LIMIT = { limit: async ({ key: k }) => { seen.push(k); return { success: seen.length <= 2 }; } };
  const headers = { "CF-Connecting-IP": "203.0.113.9" };
  assert.equal((await call("POST", "/activate", { body: { key, machine: MACHINE }, headers })).status, 200);
  assert.equal((await call("POST", "/check", { body: { key, machine: MACHINE }, headers })).status, 200);
  const third = await call("POST", "/activate", { body: { key, machine: MACHINE }, headers });
  assert.equal(third.status, 429);
  assert.equal((await third.json()).error, "rate-limited");
  assert.deepEqual(seen, ["activate:203.0.113.9", "check:203.0.113.9", "activate:203.0.113.9"]);
});

test("check: active, revoked, unknown; it saves nothing", async () => {
  const key = await boughtKey();
  const status = async (k) => (await (await call("POST", "/check", { body: { key: k, machine: MACHINE } })).json()).status;
  const writes = env.PRO.writes;
  assert.equal(await status(key), "active");
  assert.equal(await status(await makeKey(env.KEY_SECRET, "cs_test_nobody")), "unknown");
  assert.equal(env.PRO.writes, writes);
  const saved = await env.PRO.get(`key:${key}`, "json");
  await env.PRO.put(`key:${key}`, JSON.stringify({ ...saved, revoked: true }));
  assert.equal(await status(key), "revoked");
});

test("other addresses and methods: 404, and the email mask", async () => {
  assert.equal((await call("GET", "/activate")).status, 404);
  assert.equal((await call("GET", "/nothing")).status, 404);
  assert.equal((await call("GET", "/")).status, 200);
  assert.equal(maskEmail("bob@gmail.com"), "b•••@gmail.com");
  assert.equal(maskEmail("nonsense"), "");
});
