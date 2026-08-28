# Roxy Fed Tracker

An NFC sticker on the dog food container. Tap it with any phone → this page opens
→ it says whether Roxy has been fed today, and lets you record a feeding.

The point is **prevention, not logging**. The failure being designed against is
two people feeding the same dog. The tap is meant to happen *before* the scoop.

## How it works

```
NFC sticker (URL only — no app, no login, works on any phone)
    │  https://borisatan.github.io/roxy-fed/?d=<token>
    ▼
GitHub Pages static index.html  ──HTTPS──►  Supabase RPC
   (publishable key embedded)               get_status / record_feed / undo_feed
                                                   │  security definer
                                                   ▼
                                            households + events
```

## Security note

`anon` has **no table access at all** — `RLS` is on with zero policies and all
table grants are revoked. The browser can execute exactly three `security definer`
functions, each taking the household token as an argument and touching only that
household's rows. Tokens can't be enumerated because no query surface returns
more than one row.

The Supabase publishable key in `index.html` is public by design and grants
nothing on its own. **The household token is the only secret, and it is not in
this repository** — it lives in the sticker URL.

Do not "simplify" this into direct PostgREST table access.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole frontend. Vanilla JS, no build, no dependencies. |
| `schema.sql` | The database, for reference and disaster recovery. |

## Local development

It's a single static file — open `index.html` with a `?d=<token>` query string,
or serve it: `python3 -m http.server 8000`.

## Known rough edges

- The 7-day history steps in fixed 24h increments, so the week either side of a
  DST change can be an hour off at the boundary. Cosmetic.
- Anyone with the URL can mark her fed. That's the accepted price of "works on
  any phone with no login." The random token makes it unguessable.
- Supabase pauses free projects after ~7 days of no activity. Normal daily use
  keeps it awake.
