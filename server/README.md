# Swoopy Pro: the unlock server

**Not used yet.** Since 2026-10-16 the app doesn't talk to any server: people email the owner for a key, the owner
makes it with `tools/pro-keys.sh` and emails it back, and the app checks it on its own (see
[../notes/paid-unlock-plan.md](../notes/paid-unlock-plan.md), "What changed 2026-10-16"). This folder is kept for a
later version that sells keys through Stripe. Its keys and the app's are made differently, and the app no longer has
the `/activate` and `/check` calls, so both would need changing before it's used.

A small Cloudflare Worker that sells and checks Swoopy Pro keys ($5, once, all your Macs). It runs on
Cloudflare's free plan. The plan behind it: [../notes/paid-unlock-plan.md](../notes/paid-unlock-plan.md).

| Address | What it does |
|---|---|
| `POST /stripe-webhook` | Stripe's message after a payment: makes the key, saves it, emails it. A full refund turns the key off. |
| `GET /thanks?session_id=…` | The page Stripe sends the buyer to after paying. Shows the key. |
| `POST /activate` | The app sends `{key, machine}` and gets a signed token back. |
| `POST /check` | The app can ask whether a key was turned off. |

**Secrets never go in a file in this folder.** They are stored on Cloudflare with `npx wrangler secret put NAME`
(or, for local tests only, in `.dev.vars`, which git ignores).

| Secret | What it is | Where it comes from |
|---|---|---|
| `SIGNING_KEY` | signs the tokens the app checks | `npm run make-keys` |
| `KEY_SECRET` | makes the keys; never change it once keys are sold | `npm run make-keys` |
| `STRIPE_SECRET_KEY` | a restricted Stripe key that can only read Checkout Sessions | Stripe dashboard |
| `STRIPE_WEBHOOK_SECRET` | proves a message comes from Stripe (`whsec_…`) | Stripe dashboard |
| `RESEND_API_KEY` | sends the key email (optional) | resend.com |

## Setting it up (once)

You need: a Cloudflare account (free), a Stripe account, and Node.js (`brew install node`). Open Terminal in this
folder (`cd …/Pitch_Shifter/server`).

1. `npm install`, then `npx wrangler login` (a browser page opens: click **Allow**).
2. `npx wrangler kv namespace create PRO` and paste the `id` it prints into `wrangler.toml` (the `PUT_THE_KV_ID_HERE`
   line).
3. `npm run deploy`. It prints the Worker's address, like `https://pitch-shift-pro.YOURNAME.workers.dev`.
4. `npm run make-keys` stores `SIGNING_KEY` and `KEY_SECRET` on Cloudflare and prints the **public key**. Put the
   address from step 3 and the public key in `../Sources/ProConfig.swift` (`server` and `publicKey`).
5. Stripe, in **test mode** first (the "Test mode" switch at the top of the dashboard):
   - **Product catalog → Add product**: name "Swoopy Pro", price **5.00 USD**, **One-off**. Save.
   - On the product, **Create payment link**. Under **After payment**, choose **Don't show confirmation page** and
     enter `https://pitch-shift-pro.YOURNAME.workers.dev/thanks?session_id={CHECKOUT_SESSION_ID}` (exactly like
     that, with the curly brackets). Create the link and copy it (`https://buy.stripe.com/…`) into
     `../Sources/ProConfig.swift` (`buyURL`). Its id (`plink_…`, in the address bar on the link's page) can go in
     `wrangler.toml` as `STRIPE_PAYMENT_LINK` so only this link makes keys.
   - **Workbench → Webhooks → Create an event destination** (dashboard.stripe.com/webhooks): **Your account**,
     payload **Snapshot** (not Thin; keep the API version it offers), events `checkout.session.completed`,
     `checkout.session.async_payment_succeeded` and `charge.refunded`; **Continue → Webhook endpoint → Continue**;
     Endpoint URL `https://pitch-shift-pro.YOURNAME.workers.dev/stripe-webhook`. On the page that opens, click
     **Reveal secret** (`whsec_…`), run `npx wrangler secret put STRIPE_WEBHOOK_SECRET` and paste it.
   - **API keys → Create restricted key** (dashboard.stripe.com/apikeys): start from zero permissions, name
     "Swoopy Pro server", set **Checkout Sessions** to **Read** and leave everything else on None, **Create key**.
     Copy it (`rk_test_…`), run `npx wrangler secret put STRIPE_SECRET_KEY` and paste it.
6. Email (optional, recommended): make a free account at resend.com, **Domains → Add domain** (a domain you own, for
   example bought on Cloudflare for about $10 a year) and add the DNS records it shows (on Cloudflare: one click,
   "Sign in to Cloudflare" / auto-configure). Then **API Keys → Create API key** (sending access), run
   `npx wrangler secret put RESEND_API_KEY` and paste it. In `wrangler.toml` set
   `EMAIL_FROM = "Swoopy <keys@YOURDOMAIN>"`, then `npm run deploy` again.
7. Test: open the payment link, pay with card `4242 4242 4242 4242`, any future date, any 3 digits. The thank-you page
   shows a key; the email arrives (if set up). Build the app, click **Unlock Pro**, paste the key: unlocked.
8. Go live: in Stripe, switch test mode off and repeat step 5 in live mode (new product, link, webhook, restricted
   key; put the live link in `ProConfig.swift` and the live secrets with `wrangler secret put`). In `wrangler.toml`
   set `ALLOW_TEST_KEYS = "false"`. `npm run deploy`. Build and release the app.

## Checking it

- `npm test` (or `node --test`): the tests, with stand-ins for KV, Stripe and Resend. No internet, no accounts.
- `node scripts/local-server.mjs SECRETS.json --seed cs_test_one` runs it on this Mac for testing the app
  (`SECRETS.json` from `node scripts/make-keys.mjs --json`, test secrets only; see the top of the file). The app
  can be pointed at it with `--pro-server http://127.0.0.1:8787` and `--pro-file` for a test file.
- `npm run dev` runs it in Cloudflare's own runtime on this Mac (test secrets in `.dev.vars`).

## Looking things up

- A buyer lost their key: in the Cloudflare dashboard, **Storage & Databases → KV → PRO**, search for
  `email:their@email` (all small letters). It lists their keys.
- A refund turns the key off by itself (only new activations are refused; Macs already unlocked stay unlocked unless
  the app's re-check is switched on, see `ProConfig.recheckDays`).
- Stripe's fee on $5 in the US: 2.9 % + $0.30 ≈ $0.45 (cards from other countries ≈ 1.5 % more).
- Free plan limits that matter: 100,000 requests a day, 1,000 KV writes a day (2 per sale, 1 per new Mac), Resend
  100 emails a day.
