// A light brake on a script hammering an endpoint: each caller (by IP
// address) gets so many requests per window. The counts live in memory,
// per function instance, so this isn't a guarantee, but it keeps a runaway
// loop or a casual abuser from running up the bill or filling an inbox.
// Vercel doesn't serve files in api/ whose names start with "_".

export function limiter({ windowMs, perWindow }) {
  const recent = new Map();
  let lastSweep = Date.now();

  return function tooMany(req) {
    const now = Date.now();
    // Forget callers who've gone quiet, so the map can't grow forever.
    if (now - lastSweep > windowMs) {
      for (const [key, times] of recent) {
        if (now - times[times.length - 1] >= windowMs) recent.delete(key);
      }
      lastSweep = now;
    }
    const key = callerOf(req);
    const times = (recent.get(key) ?? []).filter((time) => now - time < windowMs);
    times.push(now);
    recent.set(key, times);
    return times.length > perWindow;
  };
}

export function callerOf(req) {
  return String(req.headers?.["x-forwarded-for"] ?? "").split(",")[0].trim() || "unknown";
}
