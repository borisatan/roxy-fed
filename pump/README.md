# Водна помпа — Maintenance Check Tracker

An NFC sticker on the water pump. Tap it with any phone → this page opens →
it says whether the three-month check is still good, when the next one is due,
and lets you record one.

The failure being designed against is **forgetting for nine months**, which is
the opposite of the Roxy tracker's problem (there, the danger is doing it
twice). Two consequences run through the whole build:

- **Doing it twice is harmless.** A second tap on the same day is absorbed
  silently — there is no "are you sure", no amber double-check warning
  anywhere. A unique index makes that true at the database level.
- **A tag alone cannot solve forgetting.** You only see this page when you are
  already standing at the pump, and a quarterly task fails precisely because
  you never go stand at the pump. So the page's real job is to get a reminder
  into your calendar. See below.

## The calendar subscription is the actual product

One tap on **Добави в календара** opens `webcal://…` and iOS subscribes to a
feed served by a Supabase Edge Function. From then on the phone re-fetches it
by itself, so **recording a check moves the existing reminder** rather than
requiring you to add a new one.

That matters more than it sounds. The first version handed you a downloaded
`.ics` per check, which meant the entire reminder chain depended on you
remembering to tap it every quarter — skip once and it breaks silently, with
no cron and no email to catch you. A subscription has no such step to forget.

Two alarms per event, at 09:00 a week ahead and 09:00 on the day, because an
all-day event with no alarm is a note in a month view nobody opens.

The feed carries no token in its contents — the event is plain text, so a
shared or exported calendar never leaks the secret. The token is in the
subscription URL, which lives in the phone's calendar settings.

## How it works

```
NFC sticker (URL only — no app, no login, works on any phone)
    │  https://borisatan.github.io/roxy-fed/pump/?d=<token>
    ▼
GitHub Pages static index.html  ──HTTPS──►  Supabase RPC
   (publishable key embedded)               get_item_status / record_check / undo_check
                                                   │  security definer
                                                   ▼
iOS Calendar ──webcal://──► Edge Function     maint_items + maint_checks
                            /functions/v1/calendar?d=<token>
```

## Why it lives in the `roxy` Supabase project

Supabase pauses free projects after ~7 days of no activity. A project touched
**four times a year** would be paused at the exact moment you tap the tag. The
daily dog taps keep this one permanently awake, so the pump page cannot be
dead on arrival in month three.

The objects are additive and share nothing with the dog's: `maint_items` /
`maint_checks` and three new functions. The dog's `events` table has a foreign
key to `households`, so reusing it here would have been a strained fit.

## Security note

Same posture as the dog tracker. `anon` has **no table access at all** — RLS is
on with zero policies and table grants are revoked. The browser can execute
exactly three `security definer` functions, each taking the token as an
argument and touching only that item's rows. Tokens can't be enumerated
because no query surface returns more than one row.

The Edge Function runs with `verify_jwt` off, which is deliberate: iOS Calendar
cannot send an `Authorization` header. It authenticates on the same
unguessable token and exposes a strict subset of what `get_item_status`
already gives anyone holding it.

**The token is not in this repository** — it lives in the sticker URL.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole frontend. Vanilla JS, no build, no dependencies. |
| `schema.sql` | Tables and RPCs, for reference and disaster recovery. |
| `calendar.ts` | The Edge Function serving the iCalendar feed. |

## The four states

The differences between them are the product:

| State | Headline | Button |
|---|---|---|
| `ok` | **Наред** — още 89 дни | quiet ghost outline |
| `soon` | **Наближава** — след 8 дни (last 14 days) | amber, solid |
| `overdue` | **Просрочена** — с 12 дни | red, dominant |
| `never` | **Не е проверявана** | red, dominant |

The button's weight tracks urgency. Roxy's page always had one big green
button because feeding is always the point; here most taps land on "nothing to
do", so recording a check gets out of the way until it matters.

A progress bar spans last-check → due date, because three months is too long
an interval to feel from a number alone.

## Deliberate differences from the Roxy tracker

- **No optimistic UI.** There you tap and walk away, so the answer must flip
  instantly. Here the whole point of the tap is confirmation that it was
  written down, so the button says *Записва се…* and waits. Showing a check
  that never reached the server would be the one unforgivable bug.
- **No polling.** The answer changes once a day at most. It refetches on
  `visibilitychange`, `pageshow` and `online`, and otherwise sits still.
- **No clock skew handling.** Every displayed date is computed server-side, so
  a phone with the wrong date cannot produce a wrong answer.
- **Dates, not timestamps.** `checked_on` is a `date`, which sidesteps every
  timezone and DST question the dog tracker had to reason about.

## Local development

Single static file: `python3 -m http.server 8000`, then open with `?d=<token>`.

## Known rough edges

- **The `.ics` fallback link is clumsy on iPhone** — Safari downloads the file,
  you open it from Downloads, then Calendar asks "Add All". That's iOS's
  handling of `.ics`, not a build choice. It exists only for phones that don't
  speak `webcal://`; on iOS use the subscribe button.
- **iOS decides how often to refresh a subscribed calendar** — as infrequently
  as weekly. The feed asks for 12 hours and gets what it's given. Harmless at
  a three-month interval.
- Anyone with the URL can record a check. Accepted price of "works on any
  phone with no login"; the random token makes it unguessable.
- The Edge Function's URL carries the token, so it appears in Supabase's
  function logs. Same exposure as the page URL itself.
- Recording a check for a day that already has one silently keeps the existing
  row and only fills in a note if that row had none.
