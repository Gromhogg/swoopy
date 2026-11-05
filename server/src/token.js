// The token the app keeps: "PAYLOAD.SIGNATURE", both base64url. PAYLOAD is JSON, SIGNATURE is Ed25519 over the
// PAYLOAD text exactly as sent. The app checks it with no internet, with the public key in Sources/ProConfig.swift.
const encoder = new TextEncoder();

export function base64url(bytes) {
  let text = "";
  for (const byte of new Uint8Array(bytes)) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64url(text) {
  const clean = String(text).replace(/-/g, "+").replace(/_/g, "/");
  const binary = atob(clean + "=".repeat((4 - (clean.length % 4)) % 4));
  return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

function unhex(text) {
  const clean = String(text ?? "").trim();
  if (!/^[0-9a-f]{64}$/i.test(clean)) throw new Error("SIGNING_KEY must be 64 hex characters");
  return Uint8Array.from(clean.match(/../g), (b) => parseInt(b, 16));
}

// An Ed25519 private key's 32 bytes, wrapped the way WebCrypto takes it (PKCS#8).
const PKCS8_START = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];

let cached = { secret: null, key: null };

async function signingKey(secret) {
  if (cached.secret !== secret) {
    const pkcs8 = new Uint8Array([...PKCS8_START, ...unhex(secret)]);
    cached = { secret, key: await crypto.subtle.importKey("pkcs8", pkcs8, { name: "Ed25519" }, false, ["sign"]) };
  }
  return cached.key;
}

// SIGNING_KEY: the private key as 64 hex characters (tools/pro-keys.sh server-setup makes it).
// payload: { v: 1, p: "swoopy-pro", k: key id, m: Mac id, t: seconds since 1970 }
export async function signToken(secret, payload) {
  const body = base64url(encoder.encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign({ name: "Ed25519" }, await signingKey(secret), encoder.encode(body));
  return `${body}.${base64url(signature)}`;
}
