# Swoopy Pro: the $5 unlock key (plan)

Written 2026-10-15 for the owner's decision: "The voice changer, the sliders (all sliders), the deeper when slow, and
the soundboard" are paid; Advanced processing stays free; the voice style stays on Cartoon in the free version.
"People pay through whatever method (i think stripe would be easiest) and they get a 25 digit key that they paste in
emailed to them ... the key should cost 5 dollars, and is unlimited access." Later the same evening: one public app,
gated by the key.

Mac only. The Windows (beta) app is not part of this: it stays as it is (everything free) until a Windows unlock is
built.

## What changed 2026-10-16: emailed keys, no server

The owner: "For now, let's hold off on the stripe keys for this new version: Have it where a person mails my email (at
cbsweetland@gmail.com) and I send them a key over email directly. This also makes it so I can send out keys for
free." So there is no Stripe and no server for now. Sections 2, 4, 5, 6 and 9 below describe the Stripe version; they
are kept for later and are not what the app does today. Section 10 is done (branch `v3-pro`).

- **How someone gets Pro:** in the app, **Unlock Pro** (title bar, the Swoopy menu, or a click on anything
  locked) opens a small window: "Swoopy Pro: $5", what it adds, "Email cbsweetland@gmail.com for a key", an
  **Email for a key** button (a new email in Mail, subject "Swoopy Pro key"), the key box and **Unlock**. The
  owner makes a key and emails it back; the person pastes it and clicks Unlock. No internet is needed for that.
- **The key (until 2026-10-19; now "older keys", see "Signed keys" below):** still 25 characters in 5 groups from `23456789ABCDEFGHJKMNPQRSTUVWXYZ`. The first 5 are a random
  serial number, the next 16 come from HMAC-SHA-256 of `"PSPRO2:" + serial` with the owner's secret (each from two
  bytes of it, modulo 31; about 79 bits), the last 4 are the same typo check as before (SHA-256 of `"PSPRO1:"` + the
  first 21). Typing is forgiving as before. `Sources/Pro.swift` (`ProKey`) and `tools/pro-keys.sh` make keys the same
  way; `tools/pro-keys-test.txt` holds fixed test keys both check (`tools/pro-keys.sh test`, app `--pro-test`).
- **The secret (until 2026-10-19; no longer built in, see "Signed keys" below):** 32 random bytes as 64 hex characters in `~/Library/Application Support/Pitch Shift Keys/secret.txt`
  (folder 700, file 600), made by the key tool the first time. Never in git. `build.sh` builds it into the app from
  there (or from `PRO_KEY_SECRET`); a build without it has nothing locked, so builds from the public code just work.
  `release.sh` stops if there's no secret (`PRO_KEY_SECRET= ./release.sh X` releases with everything free). **Keep a
  copy of the Pitch Shift Keys folder somewhere safe:** without the same secret, a new build would refuse every key
  already sent out.
- **What the app keeps:** `~/Library/Application Support/Pitch Shift/Pro.json` = the key and the date it was entered
  (no token, no Mac id). Checked again at every launch, with no internet.
- **The owner's tool (until 2026-10-19, see "Signed keys" below):** `tools/pro-keys.sh new "their email"` (prints the key, adds `date  name  key` to `issued.txt`
  next to the secret), `list`, `check KEY`. Plain Bash with the Mac's own `openssl` and `shasum`.
- **Free and Pro** as in section 1, now with the Voice changer and Auto EQ locked too: free = What you hear with
  Advanced processing on/off, Your voice with the style at Cartoon, Test; Pro = the Voice changer (and adding voices),
  Natural ↔ Cartoon, Bass ↔ Treble, Auto EQ, Deeper when slow, the Soundboard.
- **Honest limits (new; the secret part is fixed by "Signed keys" below):** an emailed key can't be turned off once sent (no server to ask), and the secret is inside
  the app, so someone who digs it out of the app file could make keys (the same "pay for the ready-made build" limit
  as the public code in section 8). A key works on any number of Macs. If keys get passed around, the fix is a new
  secret in a later version (old keys then stop working, so the owner would re-send keys to people in `issued.txt`),
  or the Stripe server below.
- **The Terminal options follow the lock (2026-10-19):** before, the hidden Terminal options (`--render-voice …
  --voice Woman`, `--test-voice`, `--render-sounds` and so on) ignored the lock, so a locked copy could still make
  the paid sounds from Terminal. Now a locked copy plays every Terminal mode as the free version does, like the
  window: the paid options are ignored with one note ("Swoopy Pro is locked: --voice ignored (free version)"),
  and the Soundboard modes and adding, renaming or removing voices stop with a message. `--as-free` does the same in
  any copy. Two more ways around the lock were closed: `--pro-secret` (a test option) could unlock the window and the
  sound with a home-made key, so it now only works for checking keys; and the hidden picture mode (`--preview`, which
  shows Pro unlocked) no longer starts any sound if one of its switches is pressed.
- **Signed keys (2026-10-19, the owner: "fix #2 with the longer keys"):** before, the secret that makes keys was
  built into the app, so anyone who dug it out of the app file could make keys. Now keys are **signed**: the owner's
  Mac holds a key pair, `signing-private.txt` (makes keys; never leaves the Pitch Shift Keys folder) and
  `signing-public.txt` (checks keys; the only part built into the app). The app can check a key but can't make one.
  - **A new key** is 115 characters, shown in 23 groups of 5, 6 groups per line (4 lines): "P2" (the kind of key),
    a 5-character serial, 104 characters holding an Ed25519 signature of `"PSPRO3:P2" + serial`, and the same
    4-character typo check as before (SHA-256 of `"PSPRO1:"` + the first 111). Same 31 easy-to-read characters.
    The key box is 4 lines tall; pasting a key from an email with line breaks, spaces, dashes or small letters just
    works (they're taken out as it comes in).
  - **Keys sent out before** (25 characters) keep working without the old secret in the app: when it builds,
    `build.sh` (through `tools/pro-config.sh`, which never prints a key) reads `issued.txt` and builds in only a
    fingerprint of each older key (SHA-256 of `"PSPRO-OLD:"` + the key). The app accepts an older key only if its
    fingerprint is on that list. So the owner's own key (saved in Pro.json) keeps working after the update, as long
    as it's in `issued.txt` (the key tool put every key it made there). An older key made after the build, or never
    listed, isn't accepted: make new keys the new way.
  - **The owner's tool:** `tools/pro-keys.sh setup` (makes the key pair once; never replaces one that's there),
    `new "name"` (a signed key, printed in 4 lines to paste into the email, and added to `issued.txt`), `list`,
    `check KEY` (both kinds; the key can be pasted with its line breaks in quotes). It runs on the Mac's own Swift
    (Command Line Tools), no installs: the Mac's `openssl` (LibreSSL 3.3.6) can't make Ed25519 signatures. The old
    copy of `pro-keys.sh` in the Keys folder still makes the older keys: don't use it any more.
  - **Back up the whole Pitch Shift Keys folder again** (secret.txt, signing-private.txt, signing-public.txt,
    issued.txt): without `signing-private.txt` no more keys can be made for the app, and a new key pair would make
    every signed key already sent out stop working. `secret.txt` is no longer built into anything, but keep it.
  - **Builds:** `build.sh` reads `signing-public.txt` (or `PRO_PUBLIC_KEY`) and `issued.txt` (or `PRO_ISSUED`); with
    no public key nothing is locked. `release.sh` stops without the public key (`PRO_PUBLIC_KEY= ./release.sh X` =
    everything free) or without `issued.txt` (`PRO_ISSUED= ./release.sh X` = no older keys). `PRO_KEY_SECRET` is no
    longer used.
  - **Checks:** `tools/pro-keys.sh test` and the app's `--pro-test tools/pro-keys-test.txt` check the same fixed
    examples (older keys from the test secret, signed keys from a test key pair whose private half is in that file on
    purpose: it unlocks nothing in a real build). Test options `--pro-public-key HEX` and `--pro-old-keys ISSUED`
    (replacing `--pro-secret`) work only for checking keys, never for the sound or the window.
  - **What a determined person can still do:** build the app from the public code without the public key (nothing
    locked), or edit the app file to skip the check (then the app's signature breaks and macOS warns again, but it can
    be done); share a key (a key works on any number of Macs, and there's no server to turn one off). What they can't
    do any more: make new keys from what's inside the app.
- **Later, with Stripe:** sections 5, 6 and 9 still apply, but the server would have to make keys the new way (or
  the app learn both kinds) and the app would need its `/activate` call back. `server/README.md` says the folder is
  not used yet.

## 1. Free and Pro

| | Free | Pro ($5 once) |
|---|---|---|
| What you hear: pick apps, the amount, − 0 +, on/off | yes | yes |
| Advanced processing on/off | yes | yes |
| Bass ↔ Treble slider | locked (stays in the middle) | yes |
| Auto EQ switch and its five sliders (when that branch is merged) | locked (off) | yes |
| Your voice: mic, on/off, the amount, − 0 +, Test | yes | yes |
| Natural ↔ Cartoon slider | locked (the voice is Cartoon) | yes |
| Deeper when slow | locked (off) | yes |
| Soundboard (the Sounds button) | locked | yes |
| Voice changer card and everything in it (when that branch is merged) | locked (off) | yes |

- A locked control is dimmed and shows a small lock. Pointing at it says "Swoopy Pro". Clicking it does
  nothing except open the unlock window.
- Settings saved while Pro was on are kept, but not used while Pro is locked. Once Pro is unlocked again they come
  back as they were.
- With Pro unlocked, the app looks and sounds exactly like the version without any of this (checked: same sound,
  byte for byte; same window, pixel for pixel).

## 2. What the buyer sees

1. In Swoopy: a small **Unlock Pro** button at the top right of the window (and "Unlock Swoopy Pro…" in
   the Swoopy menu), or a click on any locked control. A small window opens: "Buy for $5", a box for the key,
   and Unlock.
2. "Buy for $5" opens Stripe's payment page in the browser. They pay $5.
3. Stripe sends them to a thank-you page that shows their key right away ("We also emailed it to you"), with a Copy
   button. An email with the same key arrives a few seconds later.
4. They paste the key into Swoopy and click Unlock. Done, for good, on this Mac. The same key works on all
   their Macs, as often as they like, and never runs out.

## 3. The key

- **25 letters and digits**, shown as 5 groups of 5: `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.
- Only 31 characters are used: `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (no 0 or O, no 1, I or L, so nothing can be read two
  ways). Typing is forgiving: small letters, spaces and missing dashes are fine.
- The first 21 characters are the secret part: about 104 bits, so nobody can guess a key. They are made on the server
  from a server secret and the Stripe payment's id (HMAC-SHA-256). That means one payment always gives the same key,
  even if Stripe's message and the thank-you page both arrive at the same moment, and nobody without the server
  secret can work out a key.
- The last 4 characters are a **check part** (from a SHA-256 of the first 21). The app checks it before it goes online,
  so a typo is caught right away ("That key has a typo"). A wrong character slips through only about once in
  900,000 times, and then the server still says no.
- Example (made with the test secret in `server/test`, it unlocks nothing): `FQH6E-GT28H-MM9M6-3PNV8-JE5JA`

## 4. How the app checks a key

- **Online, once:** when a key is entered, the app sends the key and a Mac id to the server's `/activate`. The Mac id
  is a SHA-256 of the Mac's hardware id mixed with "pitch-shift-pro", so it can't be traced back or matched with
  anything else. The server checks the key, notes the Mac (no limit on how many), and answers with a **signed
  token**: a short text signed with the server's Ed25519 private key.
- **Offline, forever after:** the app saves the key and the token in
  `~/Library/Application Support/Pitch Shift/Pro.json`. At every launch it checks the token's signature with the
  public key built into the app, and that the token belongs to this key and this Mac. No internet needed. The file
  lives outside the app's settings, so removing and reinstalling Swoopy keeps Pro.
- Editing the file can't unlock anything: without the server's private key, nobody can make a token that passes the
  check. (Anyone can change the public code itself, see "Honest limits".)
- If the token stops passing (for example a new server key one day), the app tries the saved key again quietly when
  it's online, so the buyer never has to find their key again.
- **Re-check (`/check`):** the server can tell the app whether a key was turned off (refund). The app's re-check is
  built but switched off (`ProConfig.recheckDays = 0`), so today the app only goes online when a key is entered. Turn
  it on later if keys get shared around.
- No server set up in a build (empty public key in `Sources/ProConfig.swift`): nothing is locked and there is no
  Unlock button, so a build from the code without the setup works like before.

## 5. The server (Cloudflare Worker, free plan)

A small program on Cloudflare (folder `server/`, JavaScript, no other packages needed to run it). It stores keys in
Cloudflare KV (a simple key-value store).

| Address | What it does |
|---|---|
| `POST /stripe-webhook` | Stripe calls it after a payment. Checks Stripe's signature, makes the key, saves it, emails it. On a full refund it turns the key off. |
| `GET /thanks?session_id=…` | The page Stripe sends the buyer to. Shows the key ("We also emailed it to you"). If Stripe's message hasn't arrived yet, it asks Stripe directly and makes the same key. |
| `POST /activate` | The app sends `{key, machine}`. Checks the key, notes the Mac, answers with the signed token. |
| `POST /check` | The app sends `{key, machine}`. Answers "active", "revoked" or "unknown". Changes nothing. |

- **Saved per key:** the key, the buyer's email, when, the Stripe payment ids, test or live, turned off or not, how
  many Macs. Plus a list of keys per email, so a lost key can be found. Nothing else: no names, no addresses, no IP
  addresses (the per-address limit only counts in memory).
- **Limits:** 10 activations or checks per minute per internet address (Cloudflare's rate limit, no extra cost).
  Test-mode keys are refused unless `ALLOW_TEST_KEYS` is `"true"` (set it to `"false"` when going live).
- **Secrets** (never in a file in the repo; only typed into `wrangler secret put`): `STRIPE_SECRET_KEY` (a
  restricted key that can only read Checkout Sessions), `STRIPE_WEBHOOK_SECRET`, `SIGNING_KEY` (Ed25519 private
  key), `KEY_SECRET` (makes the keys), `RESEND_API_KEY` (email). `server/scripts/make-keys.mjs` makes the two
  server-made secrets and prints the public key for the app.
- **Email:** Resend's free plan (3,000 emails a month, 100 a day). It needs a domain the owner controls (about $10 a
  year, for example bought through Cloudflare). Cloudflare's own email sending needs the $5-a-month Workers Paid plan
  to email buyers, so it's not used. Without email set up, the server still works: the thank-you page then says
  "Save this key" instead of "We also emailed it".
- **Tests:** `cd server && node --test` (mocked KV, mocked Stripe and email, a signed Stripe test payload).

## 6. Stripe

- One product "Swoopy Pro", one price: $5.00 USD, one time. One Payment Link for it. After payment it sends the
  buyer to `https://<worker>/thanks?session_id={CHECKOUT_SESSION_ID}`.
- A webhook to `https://<worker>/stripe-webhook` with the events `checkout.session.completed`,
  `checkout.session.async_payment_succeeded` and `charge.refunded`.
- Stripe's fee on $5 in the US: 2.9 % + $0.30 = about $0.45, so about **$4.55** stays (cards from other countries
  cost about 1.5 % more).
- Test mode first (test card 4242 4242 4242 4242), then the same steps in live mode.

## 7. The app

- `Sources/Pro.swift`: the Pro state, the key check, the token check, the Mac id, talking to the server, the unlock
  window, and the "free version" values (style Cartoon, tone middle, Deeper when slow off).
- `Sources/ProConfig.swift`: the server address, the public key and the payment link. `build.sh` can replace them
  for a test build (`PRO_SERVER`, `PRO_PUBLIC_KEY`, `PRO_BUY_URL`).
- Window: locked look and clicks for the Bass ↔ Treble and Natural ↔ Cartoon sliders, Deeper when slow and Sounds;
  the Unlock Pro button in the title bar (gone once unlocked); the menu item.
- Command line: `--pro-key KEY` (unlock from Terminal, for testing), `--pro-reset` (lock again), `--pro-status`;
  `--pro-file F` and `--pro-server URL` for tests; `--as-free` makes every Terminal mode use the free version's values
  (and a locked copy always does, see "The Terminal options follow the lock" above).
- Hidden previews: `pro-locked`, `pro-unlock` (the unlock window; with `pro-typo` or `pro-done` for its messages),
  `pro-unlocked`. Previews without these show Pro unlocked (like before).
- The sound engine is not changed.

## 8. Honest limits

The code is GPL and public, so the key only gates the ready-made app: anyone who can build the app from the code can
remove the lock (the Terminal test modes follow the lock since 2026-10-19). The GPL also means buyers (and
anyone they share the app with) may ask for the source code, and must be given it. This is the usual "pay for the
convenient, ready-made build" model, and it's fine for a $5 app. A closed-source paid app would be different: Rubber
Band is GPL and would need Breakfast Quay's commercial licence (£590 one-time with a credit in the app, £1,490 for a
small publisher with no credit), and Swoopy Mic is built from BlackHole (GPL-3), which would need its own
permission from Existential Audio (no public price found) or a different virtual mic.

## 9. The owner's checklist (in this order)

**Costs:** Stripe has no monthly fee, about $0.45 of each $5 sale (and $15 if a buyer disputes a charge). Cloudflare
(Worker + KV + rate limit) and Resend: free plans. The only other cost is a domain for the email, about $10 a year,
and it's optional (without it the key is shown only on the thank-you page). Nothing from Apple (the app stays
unsigned, like now).

1. **Stripe account:** stripe.com → Sign up, confirm the email. Stay in **test mode** (the test/sandbox switch at the
   top) until step 13.
2. **Cloudflare account:** dash.cloudflare.com/sign-up (free plan). Nothing else to do in the dashboard.
3. **Terminal, in the project's `server` folder:** `npm install`, then `npx wrangler login` → a browser page opens →
   **Allow**.
4. `npx wrangler kv namespace create PRO` → paste the `id` it prints into `server/wrangler.toml`
   (`PUT_THE_KV_ID_HERE`).
5. `npm run deploy` → the first time it asks for a workers.dev name (any name) → note the address,
   `https://pitch-shift-pro.NAME.workers.dev`.
6. `npm run make-keys` → stores the two server-made secrets and prints the **public key**. Put the address (step 5)
   and the public key into `Sources/ProConfig.swift` (`server`, `publicKey`).
7. **Stripe product:** Product catalog → **+ Add product** → name "Swoopy Pro", **One-off**, **5.00 USD** →
   save.
8. **Payment link:** on the product, **Create payment link** → **After the payment** tab → instead of the
   confirmation page, **redirect customers to your website** →
   `https://pitch-shift-pro.NAME.workers.dev/thanks?session_id={CHECKOUT_SESSION_ID}` (curly brackets included) →
   create. Copy the `https://buy.stripe.com/…` link into `Sources/ProConfig.swift` (`buyURL`). Optional: its
   `plink_…` id into `wrangler.toml` (`STRIPE_PAYMENT_LINK`).
9. **Webhook:** Workbench → **Webhooks** → **Create an event destination** → **Your account** → payload
   **Snapshot** (not Thin) → events `checkout.session.completed`, `checkout.session.async_payment_succeeded`,
   `charge.refunded` → **Continue** → **Webhook endpoint** → **Continue** → Endpoint URL
   `https://pitch-shift-pro.NAME.workers.dev/stripe-webhook` → create → **Reveal secret** → in Terminal
   `npx wrangler secret put STRIPE_WEBHOOK_SECRET` and paste it.
10. **Restricted key:** API keys → **Create restricted key** → start from zero permissions → name "Swoopy Pro
    server" → **Checkout Sessions: Read**, everything else None → **Create key** → `npx wrangler secret put
    STRIPE_SECRET_KEY` and paste it.
11. **Email (optional):** buy a domain (Cloudflare → Domain Registration → Register Domains, about $10 a year) →
    resend.com → sign up → **Domains → Add domain** → let it add the DNS records on Cloudflare → **Verify** → **API
    Keys → Create API key** (sending access) → `npx wrangler secret put RESEND_API_KEY` → in `wrangler.toml` set
    `EMAIL_FROM = "Swoopy <keys@YOURDOMAIN>"` (and `SUPPORT_EMAIL` if you want an address for questions) →
    `npm run deploy`.
12. **Test a $5 test-mode purchase:** the main session builds a test app with `ProConfig.swift` filled in. Open it →
    **Unlock Pro** → **Buy for $5** → card `4242 4242 4242 4242`, any future date, any 3 digits, any ZIP → the
    thank-you page shows the key (and the email arrives) → paste it → **Unlock** → the locks disappear. Then try a
    refund in Stripe (Payments → the payment → Refund): that key can't unlock another Mac any more.
13. **Live:** switch test mode off. Stripe asks to activate the account (your details, a bank account, ID; a website:
    the GitHub page works if it says what's sold, the price, the refund rule and a contact). Repeat steps 7–10 in live
    mode (live product, link, webhook, restricted key; `wrangler secret put` again for the two Stripe secrets). Put the
    live link in `ProConfig.swift`. In `wrangler.toml` set `ALLOW_TEST_KEYS = "false"`, then `npm run deploy`. Then
    build and release the app as usual.

**What the main session can do with you through the connectors** once you log in (it can't log in for you):
- **Stripe connector:** create the product, the $5 price and the payment link with the redirect address (steps 7–8),
  look up test payments and make a test refund (step 12). Probably not the webhook (step 9) or the restricted key
  (step 10): those are dashboard clicks. The Stripe command-line tool on this Mac (`stripe login`, you click Allow)
  can make the webhook too, and send test events.
- **Cloudflare connector:** check the account, make the KV store (step 4) and look up keys later (a lost key: search
  `email:their@email` in the PRO store). Deploying and storing secrets (steps 3–6, 9–11) run in Terminal: after you
  click Allow for `wrangler login`, the main session can run all of those commands for you; you only paste the
  Stripe and Resend secrets when it asks (they must not pass through the chat).

## 10. Adding the other paid features (done 2026-10-16 on `v3-pro`)

- **Auto EQ** (`paid-auto-eq`): in `refresh()`: `autoEQSwitch.locked = locked`; in `buildWindow()`:
  `autoEQSwitch.onLockedClick = { self.showUnlock() }`; give `HearShifter` the saved Auto EQ settings only when
  `Pro.shared.unlocked` (else none, so it's off); in `proChanged()`: unlocked → put the saved settings back, locked
  → turn it off for every output without saving. The five sliders only show while Auto EQ is on, so they're hidden
  while locked. Add "Auto EQ" to `Pro.features`; `--as-free` should also turn Auto EQ off in `--render-file`.
- **Voice changer** (`v2-voice-changer`, PR #12): `changerCard.toggle.locked`, `strength.locked`,
  `realisticSwitch.locked` (all `GradientSwitch`/`GradientSlider`, so the lock look comes for free) and
  `changerCard.picker.isEnabled = false` while locked, each `onLockedClick` opening the unlock window; the changer
  stays off while locked even if `changerOn` was saved on; `proChanged()` puts the saved changer settings back. Add
  "the voice changer" to `Pro.features`; `--as-free` should ignore `--voice`. While locked the changer is off, so
  the one-at-a-time rule never gets in the way of the free amount.
- **Soundboard levels** (`v2-soundboard-calls`, PR #13): nothing to add (the Sounds button is already locked).
- Expect small merge conflicts in `Sources/Window.swift` (`refresh()`, `AppDelegate` settings, `buildWindow()`) and
  the help text in `Sources/main.swift`.

## 11. What was checked (2026-10-15, branch `paid-unlock`)

- Server: `cd server && node --test` → 22/22 (keys, every one-character typo and swapped pair caught, fixed key
  examples, Stripe signatures incl. wrong secret / old message / tampered body, webhook makes one key and one email,
  retries, unpaid / other link / partial refund ignored, full refund turns the key off, thank-you page before and
  after Stripe's message, Stripe down, activation token signed for key + Mac, unlimited Macs, rate limit, check).
- The same Worker in Cloudflare's own runtime (`wrangler dev`, local, no account): 10/10 (signed test webhook, wrong
  signature refused, thank-you page, activation, check, rate limit, and the Mac app unlocking against it).
  `wrangler deploy --dry-run` accepts the config (18.6 KB).
- Mac app against the local test server: 23/23 (typos caught with no network call, unknown / refunded keys, no
  internet, unlocking with small letters, works offline after, private file, a changed token / signature / key or a
  token from another signer all refused, reset, a build without the server set up has nothing locked).
- Sound: with Pro unlocked, 12 settings rendered byte-identical across main, the build without the server set up,
  and the test build (music normal / Advanced / Bass ↔ Treble fixed and moving / amount moving / ±14; voice Natural,
  0.5, Cartoon, moving style, Deeper when slow on slow speech, old preset). `--as-free`: 8/8 equal to main with the
  free values (Cartoon, middle tone, Deeper off), and 3/3 checks that the paid settings really change the sound.
- Window: 41 hidden previews at 588×369, 870×369, 306×744 (the window's largest is 306×640), dark and light; 40
  pictured. With Pro unlocked 14/14 pictures pixel-identical to main (one needed a retake: a single pixel differed
  once). Locked look, unlock window (empty, typo, unlocked, done), saved paid settings shown as the free values while
  locked, the Soundboard stays closed while locked; nothing above the desktop picture, settings unchanged, no real
  Pro.json made. The unlock window as a real sheet was pictured earlier the same evening; later the hidden windows
  were off screen and macOS can't picture a window with a sheet then (the same as the Advanced alert), so the last
  set shows it with `pro-alone` (its own window, same content). Pictures and check scripts: the worktree's
  `research/paid-unlock/` (git-ignored).

## 12. Not sure / left to decide

- After unlocking, someone who never moved the style slider gets main's default, Natural. (Keeping Cartoon until they
  move it would be a one-line change.)
- A build without the server's public key has nothing locked (so builds from the code just work). The release build
  must have it, or everything is free.
- A refund only stops new unlocks; Macs already unlocked stay unlocked unless the re-check is switched on
  (`ProConfig.recheckDays`).
- Taxes: selling digital things can mean sales tax or VAT in some places. Stripe Tax can work it out for a fee; worth
  a look before going live. Not handled here.
- The Sounds button keeps its normal button shape while locked (text and lock dimmed), so it still looks clickable,
  on purpose (it opens the unlock window).
- Done 2026-10-19: the command-line test modes (`--render-voice`, `--test-voice`, `--test-sounds`, …) follow the
  lock now (see the top of this file).
