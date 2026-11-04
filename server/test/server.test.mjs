// Tests for the key server, run with: node --test   (in server/). No network: the database is a stand-in.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import worker from "../src/index.js";
import { ALPHABET, keyId, makeKey, raw, readKey } from "../src/key.js";
import { fromBase64url, signToken } from "../src/token.js";

// The fixed examples the app and the key tool check too (tools/pro-keys-test.txt).
const fixed = readFileSync(new URL("../../tools/pro-keys-test.txt", import.meta.url), "utf8").split("\n")
  .filter((line) => !line.startsWith("#")).map((line) => line.trim().split(/\s+/));
const SECRET = fixed.find((parts) => parts[0] === "once-secret")[1];
const SIGNING_KEY = fixed.find((parts) => parts[0] === "private")[1];
const PUBLIC_KEY = fixed.find((parts) => parts[0] === "public")[1];
const ONCE = fixed.filter((parts) => parts[0] === "once");
const TOKEN = fixed.find((parts) => parts[0] === "token");

const MACHINE = "0123456789abcdef0123456789abcdef";
const OTHER_MACHINE = "fedcba9876543210fedcba9876543210";

// A stand-in for D1 that understands the server's three statements.
function memoryDB() {
  const rows = new Map();
  function run(sql, args) {
    if (sql.startsWith("INSERT INTO used")) {
      if (!rows.has(args[0])) rows.set(args[0], { machine: args[1], at: args[2] });
      return [];
    }
    if (sql.startsWith("SELECT machine FROM used")) return rows.has(args[0]) ? [{ machine: rows.get(args[0]).machine }] : [];
    throw new Error(`unknown SQL: ${sql}`);
  }
  const statement = (sql, args = []) => ({
    sql, args,
    bind: (...values) => statement(sql, values),
    first: async () => run(sql, args)[0] ?? null,
  });
  return { rows, prepare: (sql) => statement(sql), batch: async (list) => list.map((s) => ({ results: run(s.sql, s.args) })) };
}

let env;
beforeEach(() => {
  env = { DB: memoryDB(), KEY_SECRET: SECRET, SIGNING_KEY };
});

async function post(path, body, extra = env) {
  const response = await worker.fetch(new Request(`https://swoopy.test${path}`, {
    method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
  }), extra);
  return { status: response.status, body: await response.json() };
}

async function tokenIsGood(token, key, machine) {
  const [payload, signature] = token.split(".");
  const publicKey = await crypto.subtle.importKey("raw", Buffer.from(PUBLIC_KEY, "hex"), { name: "Ed25519" }, false, ["verify"]);
  const fields = JSON.parse(new TextDecoder().decode(fromBase64url(payload)));
  return (await crypto.subtle.verify({ name: "Ed25519" }, publicKey, fromBase64url(signature), new TextEncoder().encode(payload)))
    && fields.p === "swoopy-pro" && fields.k === (await keyId(raw(key))) && fields.m === machine;
}

test("the fixed example keys are made the same way", async () => {
  assert.ok(ONCE.length >= 3);
  for (const [, serial, key] of ONCE) {
    assert.equal(await makeKey(SECRET, serial), key);
    assert.deepEqual(await readKey(SECRET, key), { ok: true, raw: raw(key), serial });
    assert.deepEqual(await readKey(SECRET + "x", key), { ok: false, error: "wrong-key" });
  }
});

test("the fixed example token is made the same way", async () => {
  const [, key, machine, token] = TOKEN;
  const made = await signToken(SIGNING_KEY, { v: 1, p: "swoopy-pro", k: await keyId(raw(key)), m: machine, t: 1793750400 });
  assert.equal(made, token);
  assert.ok(await tokenIsGood(token, key, machine));
});

test("typing is forgiving, and every one-character typo is caught", async () => {
  const key = ONCE[0][2];
  assert.equal((await readKey(SECRET, ` ${key.toLowerCase().replace(/-/g, " ")}\n`)).ok, true);
  const plain = raw(key);
  for (let i = 0; i < plain.length; i++) {
    for (const c of ALPHABET) {
      if (c === plain[i]) continue;
      const changed = plain.slice(0, i) + c + plain.slice(i + 1);
      assert.equal((await readKey(SECRET, changed)).ok, false, changed);
    }
  }
  assert.deepEqual(await readKey(SECRET, plain.slice(1)), { ok: false, error: "typo" });
});

test("a key unlocks the first Mac, again on that Mac, and never another", async () => {
  const key = ONCE[1][2];
  const first = await post("/activate", { key, machine: MACHINE });
  assert.equal(first.status, 200);
  assert.ok(await tokenIsGood(first.body.token, key, MACHINE));
  assert.ok(!(await tokenIsGood(first.body.token, key, OTHER_MACHINE)));
  assert.ok(!(await tokenIsGood(first.body.token, ONCE[2][2], MACHINE)));

  const again = await post("/activate", { key: key.toLowerCase(), machine: MACHINE });
  assert.equal(again.status, 200);
  assert.ok(await tokenIsGood(again.body.token, key, MACHINE));

  const other = await post("/activate", { key, machine: OTHER_MACHINE });
  assert.deepEqual(other, { status: 409, body: { ok: false, error: "used" } });
  assert.equal(env.DB.rows.size, 1);
  assert.equal(env.DB.rows.get(ONCE[1][1]).machine, MACHINE);

  // Another key still works on the other Mac.
  assert.equal((await post("/activate", { key: ONCE[2][2], machine: OTHER_MACHINE })).status, 200);
});

test("/check says whether a key was used, and changes nothing", async () => {
  const key = ONCE[0][2];
  assert.deepEqual(await post("/check", { key }), { status: 200, body: { ok: true, used: false } });
  assert.equal(env.DB.rows.size, 0);
  await post("/activate", { key, machine: MACHINE });
  assert.deepEqual(await post("/check", { key }), { status: 200, body: { ok: true, used: true } });
  assert.deepEqual(await post("/check", { key: "TEST2-3X6Y8-PV3CN-222EU-P8M7Z" }), { status: 400, body: { ok: false, error: "typo" } });
});

test("wrong keys, typos and bad requests are refused without saving anything", async () => {
  const fake = await makeKey("someone else's secret", "ABCD");
  assert.deepEqual(await post("/activate", { key: fake, machine: MACHINE }), { status: 404, body: { ok: false, error: "wrong-key" } });
  assert.deepEqual(await post("/activate", { key: ONCE[0][2].slice(0, -1) + "2", machine: MACHINE }),
    { status: 400, body: { ok: false, error: "typo" } });
  assert.equal((await post("/activate", { key: ONCE[0][2], machine: "not-a-mac" })).body.error, "bad-request");
  assert.equal((await post("/activate", { key: ONCE[0][2] })).body.error, "bad-request");
  assert.equal((await post("/activate", "not json")).body.error, "bad-request");
  assert.equal(env.DB.rows.size, 0);
});

test("the rate limit, unknown addresses, and a server problem", async () => {
  const limited = { ...env, RATE_LIMIT: { limit: async () => ({ success: false }) } };
  assert.deepEqual(await post("/activate", { key: ONCE[0][2], machine: MACHINE }, limited),
    { status: 429, body: { ok: false, error: "rate-limited" } });
  assert.equal(env.DB.rows.size, 0);
  const missing = await worker.fetch(new Request("https://swoopy.test/thanks"), env);
  assert.equal(missing.status, 404);
  const broken = await post("/activate", { key: ONCE[0][2], machine: MACHINE }, { ...env, SIGNING_KEY: "" });
  assert.deepEqual(broken, { status: 500, body: { ok: false, error: "server" } });
});
