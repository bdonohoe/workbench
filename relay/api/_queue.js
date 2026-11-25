// The feedback queue: messages waiting for a Mac to look into them. It
// lives in an Upstash Redis database, reached over its REST API, so the
// relay still has no dependencies. Vercel doesn't serve files in api/
// whose names start with "_", so this is only a helper.
//
// Environment (Vercel's Upstash integration sets one pair or the other):
//   KV_REST_API_URL, KV_REST_API_TOKEN
//   UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN
//   FEEDBACK_QUEUE_SECRET  what the Mac sends to pick messages up. The
//                          queue stays off without it.

import { randomUUID } from "node:crypto";

const KEY = "feedback:queue";
// Enough for a busy week. Older messages fall off, and they were all
// emailed anyway.
const MAX_WAITING = 50;
const KEEP_SECONDS = 14 * 24 * 60 * 60;

function database() {
  const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;
  return url && token ? { url: url.replace(/\/$/, ""), token } : null;
}

export function queueConfigured() {
  return Boolean(database() && process.env.FEEDBACK_QUEUE_SECRET);
}

async function run(commands) {
  const db = database();
  const answer = await fetch(`${db.url}/pipeline`, {
    method: "POST",
    headers: { authorization: `Bearer ${db.token}`, "content-type": "application/json" },
    body: JSON.stringify(commands),
    signal: AbortSignal.timeout(10_000),
  });
  if (!answer.ok) throw new Error(`Redis answered ${answer.status}`);
  const results = await answer.json();
  const failed = results.find((result) => result.error);
  if (failed) throw new Error(failed.error);
  return results.map((result) => result.result);
}

/// Keeps a message for the Mac. Does nothing when the queue isn't set up.
export async function enqueue(item) {
  if (!queueConfigured()) return;
  const entry = JSON.stringify({ id: randomUUID(), receivedAt: new Date().toISOString(), ...item });
  await run([
    ["RPUSH", KEY, entry],
    ["LTRIM", KEY, String(-MAX_WAITING), "-1"],
    ["EXPIRE", KEY, String(KEEP_SECONDS)],
  ]);
}

/// Takes the oldest waiting message off the queue, with how many are left.
/// One at a time, since four screenshots come close to the size limit of
/// a Vercel response.
export async function takeOldest() {
  const [entry, remaining] = await run([["LPOP", KEY], ["LLEN", KEY]]);
  let item = null;
  try {
    item = entry ? JSON.parse(entry) : null;
  } catch {
    item = null;
  }
  return { item, remaining: Number(remaining) || 0 };
}
