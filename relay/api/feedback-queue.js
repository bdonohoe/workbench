// Hands queued feedback to the developer's Mac, which starts an agent to
// look into each message. Only a request carrying FEEDBACK_QUEUE_SECRET
// gets anything. Each message is given out once and then it's gone.
//
//   GET  /api/feedback-queue                  {"ok":true,"configured":...}
//   POST /api/feedback-queue                  the oldest message, or null
//        Authorization: Bearer <secret>       {"item":{...}|null,"remaining":N}

import { timingSafeEqual } from "node:crypto";
import { queueConfigured, takeOldest } from "./_queue.js";

function matches(given, secret) {
  const a = Buffer.from(given);
  const b = Buffer.from(secret);
  return a.length === b.length && timingSafeEqual(a, b);
}

export default async function handler(req, res) {
  const configured = queueConfigured();
  if (req.method === "GET") return res.status(200).json({ ok: true, configured });
  if (req.method !== "POST") return res.status(405).json({ reason: "Use POST." });
  if (!configured) return res.status(503).json({ reason: "The feedback queue isn't set up on the relay." });

  const header = String(req.headers.authorization ?? "");
  const given = header.startsWith("Bearer ") ? header.slice("Bearer ".length).trim() : "";
  if (!given || !matches(given, process.env.FEEDBACK_QUEUE_SECRET)) {
    return res.status(401).json({ reason: "That queue key isn't right." });
  }

  try {
    const { item, remaining } = await takeOldest();
    res.setHeader("cache-control", "no-store");
    return res.status(200).json({ item, remaining });
  } catch {
    return res.status(502).json({ reason: "The feedback queue couldn't be read. Try again in a bit." });
  }
}
