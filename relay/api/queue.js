// A mailbox for prompts queued from the phone while the Mac is asleep. The
// relay only sees sealed text and a random mailbox id, and neither is
// logged. Ids and the mailbox travel in the JSON body, never in the URL.
//
//   GET  /api/queue                            {"ok":true,"configured":...}
//   POST /api/queue {mailbox, action, ...}
//     add     {id, sealed}                     {"ok":true}
//     list    {ids}                            {"items":[...],"taken":[...]}
//     delete  {id}                             {"ok":true}
//     take                                     {"items":[...]}
//     ack     {ids}                            {"ok":true}
//   take hands back anything taken before and not acked yet, so a lost
//   answer doesn't lose prompts. The Mac acks once it has saved them.
//   409 {"taken":true} when the Mac already took that id, 413 when too big,
//   429 when the mailbox is full, 503 when the database isn't set up,
//   403 when one caller sends far too many requests.

import { ackPrompts, addPrompt, deletePrompt, listPrompts, mailboxConfigured, takePrompts } from "./_mailbox.js";
import { limiter } from "./_limit.js";

const MAX_SEALED = 32768;
const MAX_LISTED = 100;
const MAILBOX = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;
// Per caller. The Mac checks every five minutes and on wake, and the phone
// adds and lists as you queue prompts, so this leaves plenty of room while
// stopping a script from filling the database with mailboxes.
const tooMany = limiter({ windowMs: 60 * 60 * 1000, perWindow: 600 });

function readBody(req) {
  if (typeof req.body === "string") {
    try {
      return JSON.parse(req.body);
    } catch {
      return null;
    }
  }
  return req.body && typeof req.body === "object" ? req.body : null;
}

const validId = (id) => typeof id === "string" && UUID.test(id);
const validIds = (ids) => Array.isArray(ids) && ids.length <= MAX_LISTED && ids.every(validId);

export default async function handler(req, res) {
  const configured = mailboxConfigured();
  if (req.method === "GET") return res.status(200).json({ ok: true, configured });
  if (req.method !== "POST") return res.status(405).json({ reason: "Use POST." });
  res.setHeader("cache-control", "no-store");
  if (!configured) return res.status(503).json({ reason: "The queue isn't set up on the relay." });
  // Not 429: the apps read that as a full mailbox and give up on the
  // prompt. Anything else they treat as a passing failure and retry.
  if (tooMany(req)) return res.status(403).json({ reason: "Too many requests. Try again in a while." });

  const body = readBody(req);
  if (!body || typeof body.mailbox !== "string" || !MAILBOX.test(body.mailbox)) {
    return res.status(400).json({ reason: "That mailbox isn't right." });
  }
  const mailbox = body.mailbox;

  try {
    switch (body.action) {
      case "add": {
        if (!validId(body.id)) return res.status(400).json({ reason: "That id isn't right." });
        if (typeof body.sealed !== "string" || body.sealed.length === 0) {
          return res.status(400).json({ reason: "Nothing to queue." });
        }
        if (body.sealed.length > MAX_SEALED) return res.status(413).json({ reason: "That prompt is too big." });
        if (!BASE64.test(body.sealed)) return res.status(400).json({ reason: "That prompt isn't sealed text." });
        const outcome = await addPrompt(mailbox, body.id.toUpperCase(), body.sealed);
        if (outcome === "taken") return res.status(409).json({ taken: true });
        if (outcome === "full") return res.status(429).json({ reason: "Too many prompts are waiting." });
        return res.status(200).json({ ok: true });
      }
      case "list": {
        const ids = body.ids ?? [];
        if (!validIds(ids)) {
          return res.status(400).json({ reason: "Those ids aren't right." });
        }
        return res.status(200).json(await listPrompts(mailbox, ids.map((id) => id.toUpperCase())));
      }
      case "delete": {
        if (!validId(body.id)) return res.status(400).json({ reason: "That id isn't right." });
        await deletePrompt(mailbox, body.id.toUpperCase());
        return res.status(200).json({ ok: true });
      }
      case "take":
        return res.status(200).json({ items: await takePrompts(mailbox) });
      case "ack": {
        const ids = body.ids ?? [];
        if (!validIds(ids)) return res.status(400).json({ reason: "Those ids aren't right." });
        await ackPrompts(mailbox, ids.map((id) => id.toUpperCase()));
        return res.status(200).json({ ok: true });
      }
      default:
        return res.status(400).json({ reason: "That action isn't known." });
    }
  } catch {
    return res.status(502).json({ reason: "The queue couldn't be reached. Try again in a bit." });
  }
}
