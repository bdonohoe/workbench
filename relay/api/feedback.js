// Emails feedback sent from Workbench's Send Feedback sheet.
//
// The address it goes to lives here, as FEEDBACK_TO, so it never ships in
// the app. When the sender leaves an email address it becomes the
// message's Reply-To, so answering is just hitting Reply. Mail goes out
// through Resend; nothing is stored or logged here. Screenshots, when there
// are any, go along as attachments.
//
// Environment:
//   RESEND_API_KEY  a Resend API key with sending access
//   FEEDBACK_TO     where feedback is delivered
//   FEEDBACK_FROM   optional sender, e.g. "Workbench <feedback@example.com>"
//                   on a domain verified in Resend. Without one it sends
//                   from Resend's test address, which only delivers to the
//                   Resend account's own email.
//
// With a queue set up (see feedback-queue.js), each message is also kept
// for a Mac to pick up and look into. It's held only until picked up.

const MAX_MESSAGE = 10_000;
const MAX_FIELD = 200;
import { enqueue } from "./_queue.js";
import { limiter } from "./_limit.js";

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
// The app shrinks screenshots to JPEGs of at most 800 KB. Vercel allows a
// request of about 4.5 MB, so four fit, in base64, with room for the rest.
const MAX_SCREENSHOTS = 4;
const MAX_SCREENSHOT_BYTES = 850_000;

// A light brake on a script hammering the endpoint (see _limit.js): it
// keeps a runaway loop from filling the inbox.
const tooMany = limiter({ windowMs: 60 * 60 * 1000, perWindow: 10 });

function refuse(res, status, reason) {
  res.status(status).json({ reason });
}

// JPEGs only, so this can't be used to mail arbitrary files. Returns the
// attachments, or null if any of them is wrong.
function screenshots(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > MAX_SCREENSHOTS) return null;
  const files = [];
  for (const [index, item] of value.entries()) {
    if (typeof item !== "string") return null;
    const bytes = Buffer.from(item, "base64");
    if (bytes.length === 0 || bytes.length > MAX_SCREENSHOT_BYTES) return null;
    if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) return null;
    files.push({ filename: `screenshot-${index + 1}.jpg`, content: bytes.toString("base64") });
  }
  return files;
}

function field(value) {
  return typeof value === "string" ? value.trim().slice(0, MAX_FIELD) : "";
}

export default async function handler(req, res) {
  const configured = Boolean(process.env.RESEND_API_KEY && process.env.FEEDBACK_TO);
  if (req.method === "GET") return res.status(200).json({ ok: true, configured });
  if (req.method !== "POST") return refuse(res, 405, "Use POST.");
  if (!configured) return refuse(res, 503, "Feedback isn't set up yet.");

  if (tooMany(req)) return refuse(res, 429, "That's a lot of feedback at once. Try again in a while.");

  const body = req.body ?? {};
  const message = typeof body.message === "string" ? body.message.trim() : "";
  if (!message) return refuse(res, 400, "Write something first.");
  if (message.length > MAX_MESSAGE) return refuse(res, 413, "That's too long to send. Try trimming it down.");

  const email = field(body.email);
  if (email && !EMAIL.test(email)) return refuse(res, 400, "That email address doesn't look right.");

  const attachments = screenshots(body.screenshots);
  if (!attachments) return refuse(res, 400, "Those screenshots couldn't be read. Remove them and try again.");

  const app = field(body.app) || "Workbench";
  const version = field(body.version);
  const os = field(body.os);

  const firstLine = message.split("\n")[0];
  const topic = firstLine.length > 60 ? `${firstLine.slice(0, 60)}…` : firstLine;
  const details = [
    `From: ${email || "(no email left)"}`,
    `App: ${[app, version].filter(Boolean).join(" ")}`,
    os && `System: ${os}`,
  ].filter(Boolean);

  const mail = {
    from: process.env.FEEDBACK_FROM || "Workbench Feedback <onboarding@resend.dev>",
    to: [process.env.FEEDBACK_TO],
    subject: `${app} feedback: ${topic}`,
    text: `${message}\n\n---\n${details.join("\n")}\n`,
  };
  if (email) mail.reply_to = email;
  if (attachments.length) mail.attachments = attachments;

  try {
    const answer = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { authorization: `Bearer ${process.env.RESEND_API_KEY}`, "content-type": "application/json" },
      body: JSON.stringify(mail),
      signal: AbortSignal.timeout(attachments.length ? 30_000 : 10_000),
    });
    if (!answer.ok) return refuse(res, 502, "The feedback couldn't be delivered. Try again in a bit.");
    // The email is what counts. A queue that's down only means no Mac
    // looks into this one.
    await enqueue({
      message,
      app,
      version,
      os,
      screenshots: attachments.map((file) => file.content),
    }).catch(() => {});
    return res.status(200).json({ ok: true });
  } catch {
    return refuse(res, 502, "The feedback couldn't be delivered. Try again in a bit.");
  }
}
