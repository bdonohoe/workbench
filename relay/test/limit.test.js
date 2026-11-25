import { test } from "node:test";
import assert from "node:assert/strict";
import { limiter, callerOf } from "../api/_limit.js";

const from = (ip) => ({ headers: { "x-forwarded-for": `${ip}, 10.0.0.1` } });

test("lets each caller through up to the limit, then stops them", () => {
  const tooMany = limiter({ windowMs: 60_000, perWindow: 3 });
  assert.deepEqual([1, 2, 3, 4].map(() => tooMany(from("1.1.1.1"))), [false, false, false, true]);
  // Another caller has their own count.
  assert.equal(tooMany(from("2.2.2.2")), false);
});

test("lets a caller back in once the window passes", (t) => {
  t.mock.timers.enable({ apis: ["Date"], now: 0 });
  const tooMany = limiter({ windowMs: 1000, perWindow: 1 });
  assert.equal(tooMany(from("1.1.1.1")), false);
  assert.equal(tooMany(from("1.1.1.1")), true);
  t.mock.timers.tick(1001);
  assert.equal(tooMany(from("1.1.1.1")), false);
});

test("reads the first forwarded address", () => {
  assert.equal(callerOf(from("3.3.3.3")), "3.3.3.3");
  assert.equal(callerOf({ headers: {} }), "unknown");
});
