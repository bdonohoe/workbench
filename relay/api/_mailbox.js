// Mailboxes for prompts queued from the phone while a Mac sleeps. Each one
// lives in an Upstash Redis database, reached over its REST API, so the
// relay still has no dependencies. The relay only ever holds sealed
// (encrypted) text under a random mailbox id. Vercel doesn't serve files in
// api/ whose names start with "_", so this is only a helper.
//
// Keys:
//   queue:<mailbox>         hash of id -> {"sealed","addedAt"} as JSON
//   queue:<mailbox>:taken   set of ids the Mac has picked up
//   queue:<mailbox>:claimed hash like the first, of prompts taken but not
//                           yet acked by the Mac, so a lost answer to take
//                           doesn't lose them
//
// Environment (Vercel's Upstash integration sets one pair or the other):
//   KV_REST_API_URL, KV_REST_API_TOKEN
//   UPSTASH_REDIS_REST_URL, UPSTASH_REDIS_REST_TOKEN

export const MAX_WAITING = 25;
export const KEEP_SECONDS = 14 * 24 * 60 * 60;
export const CLAIM_SECONDS = 24 * 60 * 60;

// Each script runs inside Redis in one step, so its checks and writes can't
// be interleaved with another request. The JS mirrors below do the same
// thing for the tests. Change them together.

// KEYS: hash, taken. ARGV: id, entry JSON, max waiting, keep seconds.
export const ADD_SCRIPT = `
if redis.call('SISMEMBER', KEYS[2], ARGV[1]) == 1 then return 'taken' end
if redis.call('HEXISTS', KEYS[1], ARGV[1]) == 0
   and redis.call('HLEN', KEYS[1]) >= tonumber(ARGV[3]) then return 'full' end
redis.call('HSET', KEYS[1], ARGV[1], ARGV[2])
redis.call('EXPIRE', KEYS[1], ARGV[4])
return 'ok'
`;

// KEYS: hash, taken, claimed. ARGV: keep seconds, claim seconds.
// Moves what's waiting into claimed, then answers everything claimed,
// including any the Mac never acked: id, entry, id, entry...
export const TAKE_SCRIPT = `
local flat = redis.call('HGETALL', KEYS[1])
for i = 1, #flat, 2 do
  redis.call('SADD', KEYS[2], flat[i])
  redis.call('HSET', KEYS[3], flat[i], flat[i + 1])
end
if #flat > 0 then
  redis.call('EXPIRE', KEYS[2], ARGV[1])
  redis.call('EXPIRE', KEYS[3], ARGV[2])
end
redis.call('DEL', KEYS[1])
return redis.call('HGETALL', KEYS[3])
`;

export function newStore() {
  return { hashes: new Map(), sets: new Map(), ttl: new Map() };
}

/// Runs a script's JS twin against an in-memory store. Tests only.
export function mirror(script, store, keys, argv) {
  const [hashKey, takenKey, claimedKey] = keys;
  const hash = store.hashes.get(hashKey) ?? new Map();
  const taken = store.sets.get(takenKey) ?? new Set();
  const claimed = store.hashes.get(claimedKey) ?? new Map();
  if (script === ADD_SCRIPT) {
    const [id, entry, max, keep] = argv;
    if (taken.has(id)) return "taken";
    if (!hash.has(id) && hash.size >= Number(max)) return "full";
    hash.set(id, entry);
    store.hashes.set(hashKey, hash);
    store.ttl.set(hashKey, Number(keep));
    return "ok";
  }
  if (script === TAKE_SCRIPT) {
    for (const [id, entry] of hash) {
      taken.add(id);
      claimed.set(id, entry);
    }
    if (hash.size > 0) {
      store.sets.set(takenKey, taken);
      store.ttl.set(takenKey, Number(argv[0]));
      store.hashes.set(claimedKey, claimed);
      store.ttl.set(claimedKey, Number(argv[1]));
    }
    store.hashes.delete(hashKey);
    store.ttl.delete(hashKey);
    return [...claimed].flat();
  }
  throw new Error("Unknown script");
}

function database() {
  const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
  const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;
  return url && token ? { url: url.replace(/\/$/, ""), token } : null;
}

export function mailboxConfigured() {
  return Boolean(database());
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

const hashKey = (mailbox) => `queue:${mailbox}`;
const takenKey = (mailbox) => `queue:${mailbox}:taken`;
const claimedKey = (mailbox) => `queue:${mailbox}:claimed`;

function itemsFrom(pairs) {
  const items = [];
  for (let i = 0; i + 1 < (pairs ?? []).length; i += 2) {
    try {
      const { sealed, addedAt } = JSON.parse(pairs[i + 1]);
      items.push({ id: pairs[i], sealed, addedAt });
    } catch {
      // A damaged entry is skipped.
    }
  }
  return items;
}

/// Keeps a sealed prompt. Answers "ok", "taken" or "full".
export async function addPrompt(mailbox, id, sealed) {
  const entry = JSON.stringify({ sealed, addedAt: new Date().toISOString() });
  const [outcome] = await run([
    ["EVAL", ADD_SCRIPT, "2", hashKey(mailbox), takenKey(mailbox), id, entry, String(MAX_WAITING), String(KEEP_SECONDS)],
  ]);
  return outcome;
}

/// What's waiting, and which of the asked-about ids the Mac already took.
export async function listPrompts(mailbox, ids) {
  const commands = [["HGETALL", hashKey(mailbox)]];
  if (ids.length > 0) commands.push(["SMISMEMBER", takenKey(mailbox), ...ids]);
  const [pairs, flags] = await run(commands);
  const taken = ids.filter((_, index) => Number(flags?.[index]) === 1);
  return { items: itemsFrom(pairs), taken };
}

export async function deletePrompt(mailbox, id) {
  await run([["HDEL", hashKey(mailbox), id]]);
}

/// Hands over everything waiting, plus anything taken before that the Mac
/// hasn't acked. Taken ids can't be added again.
export async function takePrompts(mailbox) {
  const [pairs] = await run([
    ["EVAL", TAKE_SCRIPT, "3", hashKey(mailbox), takenKey(mailbox), claimedKey(mailbox),
      String(KEEP_SECONDS), String(CLAIM_SECONDS)],
  ]);
  return itemsFrom(pairs);
}

/// The Mac has these saved, so take stops handing them over.
export async function ackPrompts(mailbox, ids) {
  if (ids.length === 0) return;
  await run([["HDEL", claimedKey(mailbox), ...ids]]);
}
