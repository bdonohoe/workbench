import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import handler from "../api/queue.js";
import { newStore, mirror } from "../api/_mailbox.js";

const MAILBOX = "a".repeat(64);
const OTHER = "b".repeat(64);
const ID1 = "11111111-1111-4111-8111-111111111111";
const ID2 = "22222222-2222-4222-8222-222222222222";

let store;
let fetched;

// A stand-in for Upstash's /pipeline endpoint. EVAL runs the JS mirror of
// each Lua script from _mailbox.js.
function fakeFetch(url, init) {
  fetched.push(String(url));
  const commands = JSON.parse(init.body);
  const results = commands.map((command) => {
    const [name, ...args] = command;
    switch (name) {
      case "EVAL": {
        const [script, numkeys, ...rest] = args;
        const keys = rest.slice(0, Number(numkeys));
        const argv = rest.slice(Number(numkeys));
        return { result: mirror(script, store, keys, argv) };
      }
      case "HGETALL": {
        const hash = store.hashes.get(args[0]);
        return { result: hash ? [...hash].flat() : [] };
      }
      case "SMISMEMBER": {
        const set = store.sets.get(args[0]);
        return { result: args.slice(1).map((id) => (set?.has(id) ? 1 : 0)) };
      }
      case "HDEL": {
        const hash = store.hashes.get(args[0]);
        return { result: args.slice(1).filter((id) => hash?.delete(id)).length };
      }
      default:
        return { error: `unknown command ${name}` };
    }
  });
  return Promise.resolve({ ok: true, status: 200, json: async () => results });
}

function call(method, body) {
  const req = { method, body, headers: {} };
  const out = { status: 0, body: null, headers: {} };
  const res = {
    setHeader(k, v) { out.headers[k.toLowerCase()] = v; },
    status(n) { out.status = n; return res; },
    json(o) { out.body = o; return res; },
  };
  return handler(req, res).then(() => out);
}

const post = (body) => call("POST", body);
const add = (id, sealed = "c2VhbGVk", mailbox = MAILBOX) => post({ mailbox, action: "add", id, sealed });

beforeEach(() => {
  store = newStore();
  fetched = [];
  process.env.KV_REST_API_URL = "https://db.example.com";
  process.env.KV_REST_API_TOKEN = "token";
  delete process.env.UPSTASH_REDIS_REST_URL;
  delete process.env.UPSTASH_REDIS_REST_TOKEN;
  globalThis.fetch = fakeFetch;
});

test("add then list returns it", async () => {
  assert.equal((await add(ID1)).status, 200);
  const out = await post({ mailbox: MAILBOX, action: "list", ids: [] });
  assert.equal(out.status, 200);
  assert.equal(out.headers["cache-control"], "no-store");
  assert.equal(out.body.items.length, 1);
  assert.equal(out.body.items[0].id, ID1.toUpperCase());
  assert.equal(out.body.items[0].sealed, "c2VhbGVk");
  assert.ok(!Number.isNaN(Date.parse(out.body.items[0].addedAt)));
  assert.deepEqual(out.body.taken, []);
});

test("take returns everything and empties the mailbox", async () => {
  await add(ID1);
  await add(ID2, "b3RoZXI=");
  const out = await post({ mailbox: MAILBOX, action: "take" });
  assert.equal(out.status, 200);
  assert.deepEqual(out.body.items.map((i) => i.id).sort(), [ID1, ID2].map((s) => s.toUpperCase()).sort());
  const after = await post({ mailbox: MAILBOX, action: "list", ids: [] });
  assert.deepEqual(after.body.items, []);
});

test("second take after an ack returns nothing", async () => {
  await add(ID1);
  await post({ mailbox: MAILBOX, action: "take" });
  await post({ mailbox: MAILBOX, action: "ack", ids: [ID1] });
  const out = await post({ mailbox: MAILBOX, action: "take" });
  assert.equal(out.status, 200);
  assert.deepEqual(out.body.items, []);
});

test("a lost take answer is handed over again by the next take", async () => {
  await add(ID1);
  await add(ID2, "b3RoZXI=");
  // The first answer never reaches the Mac.
  await post({ mailbox: MAILBOX, action: "take" });
  const again = await post({ mailbox: MAILBOX, action: "take" });
  assert.equal(again.status, 200);
  assert.deepEqual(again.body.items.map((i) => i.id).sort(), [ID1, ID2].map((s) => s.toUpperCase()).sort());
  assert.equal(again.body.items.find((i) => i.id === ID2.toUpperCase()).sealed, "b3RoZXI=");
  // Still counted as taken, so the phone reads them as started.
  const listed = await post({ mailbox: MAILBOX, action: "list", ids: [ID1, ID2] });
  assert.deepEqual(listed.body.items, []);
  assert.deepEqual(listed.body.taken.sort(), [ID1, ID2].map((s) => s.toUpperCase()).sort());
});

test("take returns claimed prompts along with new ones", async () => {
  await add(ID1);
  await post({ mailbox: MAILBOX, action: "take" });
  await add(ID2);
  const out = await post({ mailbox: MAILBOX, action: "take" });
  assert.deepEqual(out.body.items.map((i) => i.id).sort(), [ID1, ID2].map((s) => s.toUpperCase()).sort());
});

test("ack removes claimed prompts so the next take is empty", async () => {
  await add(ID1);
  await add(ID2);
  await post({ mailbox: MAILBOX, action: "take" });
  const acked = await post({ mailbox: MAILBOX, action: "ack", ids: [ID1] });
  assert.equal(acked.status, 200);
  assert.deepEqual(acked.body, { ok: true });
  const out = await post({ mailbox: MAILBOX, action: "take" });
  assert.deepEqual(out.body.items.map((i) => i.id), [ID2.toUpperCase()]);
  await post({ mailbox: MAILBOX, action: "ack", ids: [ID2] });
  assert.deepEqual((await post({ mailbox: MAILBOX, action: "take" })).body.items, []);
});

test("ack of unknown ids is fine", async () => {
  assert.equal((await post({ mailbox: MAILBOX, action: "ack", ids: [ID1] })).status, 200);
  assert.equal((await post({ mailbox: MAILBOX, action: "ack", ids: [] })).status, 200);
});

test("ack with bad ids is 400", async () => {
  assert.equal((await post({ mailbox: MAILBOX, action: "ack", ids: ["bad"] })).status, 400);
  assert.equal((await post({ mailbox: MAILBOX, action: "ack", ids: "nope" })).status, 400);
  const many = Array.from({ length: 101 }, () => ID1);
  assert.equal((await post({ mailbox: MAILBOX, action: "ack", ids: many })).status, 400);
});

test("addAfterTakeIsRefused", async () => {
  await add(ID1);
  await post({ mailbox: MAILBOX, action: "take" });
  const out = await add(ID1);
  assert.equal(out.status, 409);
  assert.deepEqual(out.body, { taken: true });
});

test("list reports taken ids it was asked about, and only those", async () => {
  await add(ID1);
  await add(ID2);
  await post({ mailbox: MAILBOX, action: "take" });
  const out = await post({ mailbox: MAILBOX, action: "list", ids: [ID1] });
  assert.deepEqual(out.body.taken, [ID1.toUpperCase()]);
  const none = await post({ mailbox: MAILBOX, action: "list", ids: [] });
  assert.deepEqual(none.body.taken, []);
});

test("delete removes an entry", async () => {
  await add(ID1);
  assert.equal((await post({ mailbox: MAILBOX, action: "delete", id: ID1 })).status, 200);
  const out = await post({ mailbox: MAILBOX, action: "list", ids: [] });
  assert.deepEqual(out.body.items, []);
});

test("oversizeIsRefused", async () => {
  assert.equal((await add(ID1, "A".repeat(32768))).status, 200);
  assert.equal((await add(ID2, "A".repeat(32769))).status, 413);
});

test("26th add is refused, replacing an existing id is not", async () => {
  const ids = Array.from({ length: 25 }, (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`);
  for (const id of ids) assert.equal((await add(id)).status, 200);
  assert.equal((await add(ID1)).status, 429);
  assert.equal((await add(ids[0], "bmV3")).status, 200);
  const out = await post({ mailbox: MAILBOX, action: "list", ids: [] });
  assert.equal(out.body.items.length, 25);
});

test("mailboxes are separate", async () => {
  await add(ID1);
  const out = await post({ mailbox: OTHER, action: "take" });
  assert.deepEqual(out.body.items, []);
});

test("add and take set an expiry of 14 days", async () => {
  await add(ID1);
  assert.equal(store.ttl.get(`queue:${MAILBOX}`), 1209600);
  await post({ mailbox: MAILBOX, action: "take" });
  assert.equal(store.ttl.get(`queue:${MAILBOX}:taken`), 1209600);
  assert.equal(store.ttl.get(`queue:${MAILBOX}:claimed`), 86400);
});

test("bad input is 400", async () => {
  assert.equal((await post({ mailbox: "xyz", action: "take" })).status, 400);
  assert.equal((await post({ mailbox: MAILBOX.toUpperCase(), action: "take" })).status, 400);
  assert.equal((await post({ action: "take" })).status, 400);
  assert.equal((await post({ mailbox: MAILBOX, action: "nope" })).status, 400);
  assert.equal((await add("not-a-uuid")).status, 400);
  assert.equal((await add(ID1, "")).status, 400);
  assert.equal((await post({ mailbox: MAILBOX, action: "list", ids: ["bad"] })).status, 400);
  assert.equal((await post("not json")).status, 400);
  assert.equal((await post(undefined)).status, 400);
});

test("a string body is parsed", async () => {
  const out = await post(JSON.stringify({ mailbox: MAILBOX, action: "take" }));
  assert.equal(out.status, 200);
});

test("GET reports configured false without database vars", async () => {
  delete process.env.KV_REST_API_URL;
  delete process.env.KV_REST_API_TOKEN;
  const out = await call("GET");
  assert.equal(out.status, 200);
  assert.deepEqual(out.body, { ok: true, configured: false });
  assert.equal((await call("GET")).body.configured, false);
  process.env.UPSTASH_REDIS_REST_URL = "https://x";
  process.env.UPSTASH_REDIS_REST_TOKEN = "t";
  assert.equal((await call("GET")).body.configured, true);
});

test("POST without database vars is 503", async () => {
  delete process.env.KV_REST_API_URL;
  assert.equal((await post({ mailbox: MAILBOX, action: "take" })).status, 503);
});

test("other methods are 405", async () => {
  assert.equal((await call("PUT")).status, 405);
});

test("a database failure is 502", async () => {
  globalThis.fetch = async () => ({ ok: false, status: 500, json: async () => ({}) });
  assert.equal((await post({ mailbox: MAILBOX, action: "take" })).status, 502);
});

test("mailbox never appears in the URL the handler fetches", async () => {
  await add(ID1);
  await post({ mailbox: MAILBOX, action: "list", ids: [ID1] });
  await post({ mailbox: MAILBOX, action: "delete", id: ID1 });
  await post({ mailbox: MAILBOX, action: "take" });
  await post({ mailbox: MAILBOX, action: "ack", ids: [ID1] });
  assert.ok(fetched.length >= 5);
  for (const url of fetched) {
    assert.ok(!url.includes(MAILBOX));
    assert.equal(url, "https://db.example.com/pipeline");
  }
});
