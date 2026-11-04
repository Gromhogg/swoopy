# Swoopy Pro: the key server

A small Cloudflare Worker (free plan) that makes each Swoopy Pro key unlock **one Mac**. People email the owner for a
key; the owner makes it with `tools/pro-keys.sh new "name"` and emails it back. When the key is entered, Swoopy sends
it here once with its Mac id (a hash that can't be traced back to the Mac). The first Mac gets it; the same Mac can
enter it again later (a reinstall); every other Mac is refused. The plan behind it:
[../notes/paid-unlock-plan.md](../notes/paid-unlock-plan.md).

| Address | What it does |
|---|---|
| `POST /activate` | The app sends `{key, machine}`. Answers `{ok: true, token}` (signed for this key and this Mac; the app keeps it and checks it at every launch with no internet), or `{ok: false, error: "used"}` for any other Mac. |
| `POST /check` | `{key}` → `{ok: true, used: true/false}`. Changes nothing. The key tool asks it. |
| `GET /` | "Swoopy Pro" (to see it's up). |

Errors: `typo`, `wrong-key` (not made with this server's secret), `used`, `rate-limited` (10 tries a minute per
internet address), `bad-request`, `server`.

**Nothing to set up for a new key:** keys are made on the owner's Mac from `server-secret.txt`, and the server checks
them with the same secret. It keeps only which keys were used and by which Mac id (the D1 database `swoopy-pro`, table
`used`).

## Secrets

Never in a file in this folder. They live in `~/Library/Application Support/Pitch Shift Keys/` (made once by
`tools/pro-keys.sh server-setup`) and on Cloudflare (`npx wrangler secret put NAME`).

| Secret | What it is | From |
|---|---|---|
| `KEY_SECRET` | makes and checks keys; never change it once keys are sent out | `server-secret.txt` |
| `SIGNING_KEY` | signs the tokens (the app holds the public half: `ProConfig.serverKey`) | `server-signing-private.txt` |

## Setting it up (done 2026-11-03)

On the owner's Cloudflare account (`account_id` in `wrangler.toml`), in this folder, after `npm install`:

1. `npx wrangler d1 create swoopy-pro` (its id is in `wrangler.toml`), then `npm run migrate` (makes the table).
2. The two secrets, straight from the files (nothing is printed):
   `tr -d ' \n' < "$HOME/Library/Application Support/Pitch Shift Keys/server-secret.txt" | npx wrangler secret put KEY_SECRET`
   and the same with `server-signing-private.txt` for `SIGNING_KEY`.
3. `npm run deploy`. Its address goes in `../Sources/ProConfig.swift` (`server`) and `../tools/pro-keys.swift`
   (`serverURL`).

## Checking it

- `npm test`: the tests, with a stand-in database. No internet, no accounts. They check the fixed examples in
  `../tools/pro-keys-test.txt`, which the app (`--pro-test`) and the key tool (`test`) check too.
- On this Mac: `npx wrangler d1 migrations apply swoopy-pro --local --persist-to DIR`, then
  `npx wrangler dev --local --env-file FILE --persist-to DIR` (FILE: `KEY_SECRET=…` and `SIGNING_KEY=…` lines, kept
  outside the repo). Point the app at it with `--pro-server http://127.0.0.1:8787 --pro-file F --pro-key KEY`, and
  the key tool with `SWOOPY_PRO_SERVER=http://127.0.0.1:8787`.

## Looking things up

- Which keys were used: Cloudflare dashboard → **Storage & Databases → D1 → swoopy-pro → used**, or
  `npx wrangler d1 execute swoopy-pro --remote --command "SELECT * FROM used"`. `issued.txt` says who each serial
  number (the first 4 characters of a key) was made for.
- Someone got a new Mac: make them a new key (`tools/pro-keys.sh new`). Or free the old one so it works on the next
  Mac that enters it: `npx wrangler d1 execute swoopy-pro --remote --command "DELETE FROM used WHERE serial = 'ABCD'"`.
- Free plan limits that matter: 100,000 requests a day; D1 100,000 writes a day (one per new Mac).
- The Stripe version of this server (selling keys with a payment page) was removed on 2026-11-03; it's in git history
  before that date if it's ever wanted.
