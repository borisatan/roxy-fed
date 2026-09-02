// Serves a maintenance item as a subscribable iCalendar feed.
//
// The point: iOS can subscribe to `webcal://.../calendar?d=<token>` in one
// tap, and from then on the phone re-fetches this on its own. Recording a
// check moves the due date here, and the event in the user's calendar moves
// with it. No per-check "remember to add the reminder" step to forget.
//
// verify_jwt is off by design: iOS Calendar cannot send an Authorization
// header. Authentication is the unguessable token in the query string --
// the same posture as the RPCs, and this function is a strict subset of what
// get_item_status already exposes to anyone holding that token.
//
// Deployed to the `roxy` Supabase project as the function `calendar`.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "https://dckgfwievtugvllxseue.supabase.co";
// Publishable key: public by design, grants nothing without a valid token.
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ??
  "sb_publishable_2h5zLJJhtaLGCrSvgyNAcQ_QLf_gOm8";

const enc = new TextEncoder();

/** RFC 5545 line folding at 75 octets, without splitting a UTF-8 sequence. */
function fold(line: string): string {
  const bytes = enc.encode(line);
  if (bytes.length <= 75) return line;
  const dec = new TextDecoder();
  const out: string[] = [];
  let i = 0;
  let limit = 75;
  while (i < bytes.length) {
    let end = Math.min(i + limit, bytes.length);
    // Back up off a continuation byte so a character never straddles a fold.
    while (end > i && end < bytes.length && (bytes[end] & 0xc0) === 0x80) end--;
    out.push(dec.decode(bytes.slice(i, end)));
    i = end;
    limit = 74; // continuation lines carry a leading space
  }
  return out.join("\r\n ");
}

function esc(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;")
          .replace(/,/g, "\\,").replace(/\n/g, "\\n");
}

const compact = (isoDay: string) => isoDay.replace(/-/g, "");

function addDays(isoDay: string, n: number): string {
  const d = new Date(isoDay + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** Days since epoch — a SEQUENCE that rises whenever the due date moves. */
function seq(isoDay: string): number {
  return Math.floor(Date.parse(isoDay + "T00:00:00Z") / 86400000);
}

async function uidFor(token: string): Promise<string> {
  // Hash, not the token: the UID travels into the calendar database, and a
  // shared or exported calendar should never carry the secret itself.
  const digest = await crypto.subtle.digest("SHA-256", enc.encode("cal:" + token));
  return Array.from(new Uint8Array(digest).slice(0, 10))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return new Response("method not allowed", { status: 405 });
  }

  const token = new URL(req.url).searchParams.get("d");
  if (!token) return new Response("not found", { status: 404 });

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_item_status`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: ANON_KEY,
      Authorization: `Bearer ${ANON_KEY}`,
    },
    body: JSON.stringify({ p_token: token }),
  });
  if (!r.ok) return new Response("upstream error", { status: 502 });

  const s = await r.json();
  // Same generic answer as the RPC: this must not be a token oracle either.
  if (!s || s.ok !== true) return new Response("not found", { status: 404 });

  // A never-checked item is due now, not undated.
  const due: string = s.due_on ?? s.today;
  const title = `Проверка: ${s.name}`;
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
  const uid = await uidFor(token);

  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//maint//calendar//BG",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    `X-WR-CALNAME:${esc(s.name)}`,
    `X-WR-CALDESC:${esc(`Проверка на всеки ${s.interval_months} месеца.`)}`,
    // Hints to the client; iOS ultimately refreshes on its own schedule.
    "REFRESH-INTERVAL;VALUE=DURATION:PT12H",
    "X-PUBLISHED-TTL:PT12H",
    "BEGIN:VEVENT",
    `UID:${uid}@maint.local`,
    `DTSTAMP:${stamp}`,
    `SEQUENCE:${seq(due)}`,
    `DTSTART;VALUE=DATE:${compact(due)}`,
    `DTEND;VALUE=DATE:${compact(addDays(due, 1))}`,
    `SUMMARY:${esc(title)}`,
    `DESCRIPTION:${esc(
      s.last_checked_on
        ? `Последна проверка: ${s.last_checked_on}.`
        : "Няма записана проверка.",
    )}`,
    "TRANSP:TRANSPARENT",
    // An all-day event with no alarm is a note in a month view nobody opens.
    // 09:00 a week ahead, then 09:00 on the day.
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    `DESCRIPTION:${esc(`${title} — след 7 дни`)}`,
    "TRIGGER:-P6DT15H",
    "END:VALARM",
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    `DESCRIPTION:${esc(title)}`,
    "TRIGGER;RELATED=START:PT9H",
    "END:VALARM",
    "END:VEVENT",
    "END:VCALENDAR",
  ];

  const body = lines.map(fold).join("\r\n") + "\r\n";

  return new Response(req.method === "HEAD" ? null : body, {
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": 'inline; filename="maint.ics"',
      // Short cache: the due date changes the moment a check is recorded.
      "Cache-Control": "public, max-age=3600",
      "X-Robots-Tag": "noindex, nofollow",
    },
  });
});
