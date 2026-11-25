// Forwards Workbench's notifications to Apple.
//
// Apple only accepts pushes for the phone app when they're signed with a
// key from its developer team, so that key lives here instead of on every
// Mac. Workbench sends the phone's device token and the notification; this
// signs the request and passes it to Apple unchanged. Nothing is stored or
// logged. Apple's status and reason come back as-is, so the Mac can retry
// in the other environment on BadDeviceToken the way it does when it talks
// to Apple directly.
//
// Environment: APNS_KEY (the .p8 file's contents), APNS_KEY_ID, APNS_TEAM_ID.

import crypto from "node:crypto";
import http2 from "node:http2";
import { limiter } from "./_limit.js";

const HOSTS = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};
const TOPIC = "me.birchtree.BenchPhone";
const TOPICS = new Set([TOPIC, `${TOPIC}.push-type.liveactivity`]);
const PUSH_TYPES = new Set(["alert", "liveactivity"]);
// Apple's own limit for both kinds.
const MAX_PAYLOAD = 4096;

// Per caller. A Mac sends a notification when Claude finishes or needs
// you, and Live Activity updates while it works, so this is far above what
// one Mac sends, but it stops a script using the relay to flood Apple.
const tooMany = limiter({ windowMs: 60 * 60 * 1000, perWindow: 3000 });

// Apple wants a fresh token at least hourly, and no more than every 20 minutes.
let cached = null;
function providerToken() {
  const now = Math.floor(Date.now() / 1000);
  if (cached && now - cached.issued < 50 * 60) return cached.token;
  const part = (object) => Buffer.from(JSON.stringify(object)).toString("base64url");
  const input = `${part({ alg: "ES256", kid: process.env.APNS_KEY_ID })}.${part({ iss: process.env.APNS_TEAM_ID, iat: now })}`;
  const key = process.env.APNS_KEY.replace(/\\n/g, "\n");
  const signature = crypto.sign("sha256", Buffer.from(input), { key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  cached = { token: `${input}.${signature}`, issued: now };
  return cached.token;
}

function toApple(environment, deviceToken, headers, body) {
  return new Promise((resolve, reject) => {
    const client = http2.connect(HOSTS[environment]);
    client.on("error", reject);
    const request = client.request({ ":method": "POST", ":path": `/3/device/${deviceToken}`, ...headers });
    let status = 0;
    let text = "";
    request.setEncoding("utf8");
    request.on("response", (response) => { status = response[":status"]; });
    request.on("data", (chunk) => { text += chunk; });
    request.on("end", () => { client.close(); resolve({ status, text }); });
    request.on("error", (error) => { client.close(); reject(error); });
    request.setTimeout(10_000, () => { request.close(); reject(new Error("Apple didn't answer in time.")); });
    request.end(body);
  });
}

function refuse(res, status, reason) {
  res.status(status).json({ reason });
}

export default async function handler(req, res) {
  if (req.method === "GET") return res.status(200).json({ ok: true, configured: Boolean(process.env.APNS_KEY) });
  if (req.method !== "POST") return refuse(res, 405, "Use POST.");
  if (!process.env.APNS_KEY || !process.env.APNS_KEY_ID || !process.env.APNS_TEAM_ID) return refuse(res, 503, "The push service isn't set up.");
  if (tooMany(req)) return refuse(res, 429, "TooManyRequests");

  const { environment, token, topic, pushType, priority = 10, collapseID, payload } = req.body ?? {};
  if (!HOSTS[environment]) return refuse(res, 400, "environment must be sandbox or production.");
  if (typeof token !== "string" || !/^[0-9a-f]{64,200}$/i.test(token)) return refuse(res, 400, "BadDeviceToken");
  if (!TOPICS.has(topic)) return refuse(res, 400, "TopicDisallowed");
  if (!PUSH_TYPES.has(pushType)) return refuse(res, 400, "InvalidPushType");
  if (priority !== 5 && priority !== 10) return refuse(res, 400, "BadPriority");
  if (collapseID != null && (typeof collapseID !== "string" || Buffer.byteLength(collapseID) > 64)) return refuse(res, 400, "BadCollapseId");
  if (payload == null || typeof payload !== "object" || Array.isArray(payload)) return refuse(res, 400, "PayloadEmpty");
  const body = JSON.stringify(payload);
  if (Buffer.byteLength(body) > MAX_PAYLOAD) return refuse(res, 413, "PayloadTooLarge");

  const headers = {
    authorization: `bearer ${providerToken()}`,
    "apns-topic": topic,
    "apns-push-type": pushType,
    "apns-priority": String(priority),
    "content-type": "application/json",
  };
  if (collapseID) headers["apns-collapse-id"] = collapseID;

  try {
    const answer = await toApple(environment, token, headers, body);
    if (answer.status === 200) return res.status(200).json({ ok: true });
    let reason = `Apple answered ${answer.status}.`;
    try { reason = JSON.parse(answer.text).reason ?? reason; } catch {}
    // A rejected provider token is our problem, not the request's.
    if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") cached = null;
    return refuse(res, answer.status, reason);
  } catch (error) {
    return refuse(res, 502, error.message || "Couldn't reach Apple.");
  }
}
