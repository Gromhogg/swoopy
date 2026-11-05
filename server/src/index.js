// Swoopy Pro: the key server (a Cloudflare Worker with one D1 database, "DB"). Each key unlocks one Mac.
//   POST /activate  the app sends { key, machine }. The first Mac to send a key gets it: { ok: true, token }. The
//                   same Mac can send it again (a reinstall) and gets a new token; any other Mac gets
//                   { ok: false, error: "used" }.
//   POST /check     { key } → { ok: true, used: true | false }. Changes nothing (the owner's key tool asks it).
// Errors: "typo", "wrong-key" (not made with KEY_SECRET), "used", "rate-limited", "bad-request", "server".
// Secrets (wrangler secret put): KEY_SECRET (makes and checks keys), SIGNING_KEY (signs the tokens). See README.md.
import { keyId, readKey } from "./key.js";
import { signToken } from "./token.js";

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

const STATUS = { typo: 400, "bad-request": 400, "wrong-key": 404, used: 409, "rate-limited": 429 };
const problem = (error) => json({ ok: false, error }, STATUS[error] ?? 500);

// Cloudflare's rate limit (10 a minute per internet address). Without the binding (tests) everything is let through.
async function allowed(env, request) {
  if (!env.RATE_LIMIT) return true;
  const { success } = await env.RATE_LIMIT.limit({ key: request.headers.get("CF-Connecting-IP") || "unknown" });
  return success;
}

async function readBody(request) {
  try {
    return await request.json();
  } catch {
    return null;
  }
}

async function activate(request, env) {
  const body = await readBody(request);
  const machine = String(body?.machine ?? "");
  if (!/^[0-9a-f]{32}$/.test(machine)) return problem("bad-request");
  const key = await readKey(env.KEY_SECRET, body?.key);
  if (!key.ok) return problem(key.error);
  // Both in one go, so two Macs sending the same key at once can't both get it.
  const [, found] = await env.DB.batch([
    env.DB.prepare("INSERT INTO used (serial, machine, at) VALUES (?1, ?2, ?3) ON CONFLICT (serial) DO NOTHING")
      .bind(key.serial, machine, new Date().toISOString()),
    env.DB.prepare("SELECT machine FROM used WHERE serial = ?1").bind(key.serial),
  ]);
  if (found.results?.[0]?.machine !== machine) return problem("used");
  const token = await signToken(env.SIGNING_KEY, {
    v: 1,
    p: "swoopy-pro",
    k: await keyId(key.raw),
    m: machine,
    t: Math.floor(Date.now() / 1000),
  });
  return json({ ok: true, token });
}

async function check(request, env) {
  const key = await readKey(env.KEY_SECRET, (await readBody(request))?.key);
  if (!key.ok) return problem(key.error);
  const row = await env.DB.prepare("SELECT machine FROM used WHERE serial = ?1").bind(key.serial).first();
  return json({ ok: true, used: Boolean(row) });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;
    try {
      if (route === "GET /") return new Response("Swoopy Pro\n", { headers: { "Content-Type": "text/plain" } });
      if (route !== "POST /activate" && route !== "POST /check") return json({ ok: false, error: "not-found" }, 404);
      if (!(await allowed(env, request))) return problem("rate-limited");
      return route === "POST /activate" ? await activate(request, env) : await check(request, env);
    } catch (error) {
      console.error(`${route} failed: ${error?.message ?? error}`);
      return problem("server");
    }
  },
};
