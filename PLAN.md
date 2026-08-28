# Roxy Fed Tracker — Implementation Spec

**Handoff document.** Everything needed to build this is below: full SQL, frontend spec, deploy steps. Written to be handed to Claude Code and executed without further context.

## What it is

An NFC sticker on the dog food container. Tap it with any phone → a web page opens → it says whether Roxy has been fed today, and lets you record a feeding.

**The point is prevention, not logging.** The failure being designed against is *two people feeding the same dog*. The tap is meant to happen *before* the scoop, so the page's job is to answer a question, not just collect a record.

## Decisions (settled — do not re-litigate)

| Decision | Choice |
|---|---|
| Dog | Roxy |
| Database | New free Supabase project, separate from the existing `Monelo` project |
| Hosting | Vercel static page, single `index.html`, no build step, no framework |
| Access | Random token in the URL. No login, no accounts, works on any phone |
| Meals | One a day |
| Day rollover | 3am local |
| Timezone | `Europe/Berlin` — one string in one row, trivial to change |
| Attribution | None. Time only, no names |
| History | Today + last 7 days |
| Schema | Generic events table, so walks/meds can be added later without migration |
| Undo | 10-minute window, enforced server-side |
| Double feeding | **A real failure.** Recorded, flagged amber, and warned about before it happens |
| Stickers | One, on the food container lid |

## Architecture

```
NFC sticker (URL only — no phone-side setup, works for anyone)
    │  https://<project>.vercel.app/?d=<token>
    ▼
Vercel static index.html  ──HTTPS──►  Supabase RPC
   (anon key embedded)                get_status / record_feed / undo_feed
                                                │  security definer
                                                ▼
                                      households + events
                                      (zero direct client access)
```

### Why RPC functions and not table access with RLS

The browser is anonymous. The only thing identifying the household is the token in the URL — and to validate a token against `households`, the `anon` role would need `SELECT` on that table. That would let anyone read *every* token and mark any dog fed.

So `anon` gets **no table access at all**. It can execute exactly three `security definer` functions, each taking the token as an argument and touching only that household's rows. Tokens can't be enumerated because no query surface returns more than one row.

Do not "simplify" this into direct PostgREST table access. It's the one security-relevant decision in the build.

---

## Database

Run as a single migration on a fresh Supabase project.

```sql
-- ============================================================
-- Tables
-- ============================================================

create table public.households (
  token         text primary key,
  dog_name      text not null,
  timezone      text not null default 'Europe/Berlin',
  rollover_hour smallint not null default 3,
  created_at    timestamptz not null default now()
);

create table public.events (
  id          bigint generated always as identity primary key,
  token       text not null references public.households(token) on delete cascade,
  event_type  text not null default 'feed',
  occurred_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

create index events_token_time_idx
  on public.events (token, event_type, occurred_at desc);

-- RLS on with zero policies = deny all. Belt and braces alongside the revokes.
alter table public.households enable row level security;
alter table public.events     enable row level security;

revoke all on public.households from anon, authenticated;
revoke all on public.events     from anon, authenticated;

-- ============================================================
-- The day-window pivot: when did the current "dog day" begin?
-- ============================================================

create or replace function public.dog_day_start(
  p_tz       text,
  p_rollover smallint,
  p_at       timestamptz default now()
) returns timestamptz
language sql stable as $$
  select (date_trunc('day', (p_at at time zone p_tz) - make_interval(hours => p_rollover))
          + make_interval(hours => p_rollover)) at time zone p_tz;
$$;

-- ============================================================
-- get_status
-- ============================================================

create or replace function public.get_status(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  h         public.households%rowtype;
  v_start   timestamptz;
  v_feeds   jsonb;
  v_count   int;
  v_last_id bigint;
  v_last_at timestamptz;
  v_days    jsonb;
begin
  select * into h from public.households where token = p_token;
  if not found then
    -- Deliberately generic: this endpoint must not be a token oracle.
    return jsonb_build_object('ok', false, 'error', 'unknown');
  end if;

  v_start := public.dog_day_start(h.timezone, h.rollover_hour);

  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'at', t.occurred_at)
                            order by t.occurred_at), '[]'::jsonb),
         count(*)
    into v_feeds, v_count
  from (
    select id, occurred_at
    from public.events
    where token = p_token and event_type = 'feed' and occurred_at >= v_start
  ) t;

  select id, occurred_at into v_last_id, v_last_at
  from public.events
  where token = p_token and event_type = 'feed' and occurred_at >= v_start
  order by occurred_at desc
  limit 1;

  select coalesce(jsonb_agg(jsonb_build_object('day_start', d.gs, 'count', d.c)
                            order by d.gs), '[]'::jsonb)
    into v_days
  from (
    select gs,
           (select count(*) from public.events e
             where e.token = p_token and e.event_type = 'feed'
               and e.occurred_at >= gs
               and e.occurred_at <  gs + interval '1 day') as c
    from generate_series(v_start - interval '6 days', v_start, interval '1 day') as gs
  ) d;

  return jsonb_build_object(
    'ok',               true,
    'dog_name',         h.dog_name,
    'server_now',       now(),
    'day_start',        v_start,
    'feed_count_today', v_count,
    'fed_today',        v_count > 0,
    'feeds_today',      v_feeds,
    'last_feed_id',     v_last_id,
    'last_feed_at',     v_last_at,
    'days',             v_days
  );
end;
$$;

-- ============================================================
-- record_feed — the important one
-- ============================================================

create or replace function public.record_feed(
  p_token   text,
  p_confirm boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  h         public.households%rowtype;
  v_start   timestamptz;
  v_count   int;
  v_last_at timestamptz;
begin
  select * into h from public.households where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown');
  end if;

  v_start := public.dog_day_start(h.timezone, h.rollover_hour);

  select count(*), max(occurred_at) into v_count, v_last_at
  from public.events
  where token = p_token and event_type = 'feed' and occurred_at >= v_start;

  -- CASE 1: fumbled double-tap, or the phone read the tag twice in a pocket.
  -- Nobody intended anything. Swallow it. This is the ONLY case where
  -- silently doing nothing is correct.
  if v_last_at is not null and v_last_at > now() - interval '2 minutes' then
    return public.get_status(p_token) || jsonb_build_object('action', 'deduped');
  end if;

  -- CASE 2: already fed today and not confirmed. Record NOTHING.
  -- Hand the page what it needs to interrupt the human instead.
  if v_count > 0 and not p_confirm then
    return public.get_status(p_token)
           || jsonb_build_object('action', 'needs_confirm', 'needs_confirm', true);
  end if;

  -- CASE 3: deliberate. Record it.
  insert into public.events (token, event_type) values (p_token, 'feed');
  return public.get_status(p_token) || jsonb_build_object('action', 'recorded');
end;
$$;

-- ============================================================
-- undo_feed — window enforced here, not just hidden in the UI
-- ============================================================

create or replace function public.undo_feed(p_token text, p_event_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_deleted int;
begin
  if not exists (select 1 from public.households where token = p_token) then
    return jsonb_build_object('ok', false, 'error', 'unknown');
  end if;

  delete from public.events
  where id = p_event_id
    and token = p_token
    and created_at > now() - interval '10 minutes';
  get diagnostics v_deleted = row_count;

  return public.get_status(p_token)
         || jsonb_build_object('action',
              case when v_deleted > 0 then 'undone' else 'undo_expired' end);
end;
$$;

-- ============================================================
-- Grants. Postgres grants EXECUTE to PUBLIC by default,
-- so the revokes are load-bearing, not decoration.
-- ============================================================

revoke execute on function public.get_status(text)             from public;
revoke execute on function public.record_feed(text, boolean)   from public;
revoke execute on function public.undo_feed(text, bigint)      from public;

grant execute on function public.get_status(text)              to anon;
grant execute on function public.record_feed(text, boolean)    to anon;
grant execute on function public.undo_feed(text, bigint)       to anon;
```

### Seed the household

```sql
insert into public.households (token, dog_name, timezone, rollover_hour)
values (substr(replace(gen_random_uuid()::text, '-', ''), 1, 12), 'Roxy', 'Europe/Berlin', 3)
returning token;
```

**Save the returned token.** It goes in the sticker URL. If you're not in German time, change the timezone string — any IANA name works (`Europe/Amsterdam`, `Europe/Madrid`, `Europe/Stockholm`…).

---

## Frontend

One file: `index.html`. Vanilla JS, no framework, no build, no dependencies. Inline the CSS and JS.

### Calling the API

```js
const SUPABASE_URL = 'https://<ref>.supabase.co';
const ANON_KEY     = '<publishable anon key>';

async function rpc(fn, body) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: ANON_KEY,
      Authorization: `Bearer ${ANON_KEY}`,
    },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(await r.text());
  return r.json();
}
```

The anon key being public is normal and fine — it grants nothing without a valid token, because `anon` has no table access.

Token comes from `?d=` in the URL. Missing or unrecognised → a plain "This link isn't valid" page. Don't explain why.

### The four states

The differences between these states *are* the product. Get them right.

**1. Not fed** — large muted display, one big "Mark as fed" button. One tap, done.

**2. Fed once** — large green **FED**, the time, and how long ago. The primary action is now *nothing*: you have your answer, you walk away. "Feed again" sits below as small, muted, deliberately non-button-shaped text.

**3. "Feed again" tapped** — a confirm step that states the situation in words rather than asking a bare yes/no:

> *"Roxy was fed at 7:42am, 20 minutes ago. Record a second feeding?"*

The time and the elapsed gap are what actually stop the mistake. A generic "Are you sure?" would not.

**4. Fed twice or more** — amber banner at the top:

> **⚠️ Fed 2× today — 7:42am and 8:04am**

Loud, because something went wrong today and whoever is looking needs to know before they add a third.

### History strip

Seven dots, oldest to newest. Grey = missed, green = fed once, **amber = fed more than once**. A row of green with one amber dot communicates more at a glance than any log.

### Behaviour details that matter more than they look

- **Optimistic UI** on the primary tap — flip immediately, reconcile with the server response. Standing at the bowl on bad wifi shouldn't feel broken.
- **Never show a stale "not fed."** If the fetch fails, say *"Couldn't reach the server"* explicitly. A confidently wrong "not fed" causes the exact double-feeding this exists to prevent. This is the single most important error-handling rule in the build.
- **Re-fetch on `visibilitychange`** — phone wakes from sleep, page refreshes. Nobody should ever read a cached answer.
- **No `localStorage` for truth.** The server is the record. Local state only tracks the undo affordance.
- **Handle `action: 'deduped'`** silently — the UI should look identical to a normal successful tap. The user tapped twice by accident; telling them so is noise.

### Sizing

Thumb-sized targets, readable at arm's length, one-handed. This gets used while holding a dog bowl.

---

## Deploy — step by step

### A. Supabase

1. [supabase.com/dashboard](https://supabase.com/dashboard) → **New project**
2. Name `roxy`, region **Frankfurt (eu-central-1)**, generate a DB password (you won't need it again — save it anyway)
3. Wait ~2 min for provisioning
4. **SQL Editor** → paste the full migration above → **Run**
5. New query → paste the seed insert → **Run** → **copy the returned token**
6. **Project Settings → API** → copy the **Project URL** and the **anon / publishable key**

### B. GitHub

7. [github.com/new](https://github.com/new) → name it `roxy-fed` → **Private** → Create
8. On the new repo page, **uploading an existing file** → drag in `index.html` and `vercel.json` → Commit

*(Or if you'd rather use the command line: `git init && git add . && git commit -m "init" && git remote add origin <url> && git push -u origin main`)*

### C. Vercel

9. [vercel.com/new](https://vercel.com/new) → **Continue with GitHub** → authorise
10. Find `roxy-fed` → **Import**
11. Change **nothing**. Framework preset "Other", no build command, no output directory — it's a static file
12. **Deploy**, wait ~30s
13. Copy the URL, e.g. `https://roxy-fed.vercel.app`

### D. Test before touching the sticker

14. Open `https://roxy-fed.vercel.app/?d=<token>` on your phone
15. Confirm: shows NOT FED → tap → shows FED with the time → undo appears → tap "feed again" → confirm dialog names the time → confirming produces the amber 2× banner
16. Clean up test rows: `delete from events;` in the SQL editor

### E. The sticker

17. Install **NFC Tools** (free, iOS + Android)
18. **Write** → **Add a record** → **URL/URI** → paste the full URL including `?d=<token>`
19. **Write** → hold the sticker to the back of your phone
20. Stick it on **the lid of the food container** — so tapping happens before scooping, not after. This placement is doing as much work as the software.
21. Tap with a different phone to confirm it opens with no app and no login

---

## Cost

Free, permanently, at this volume — ~400 rows a year and a handful of requests a day. Vercel Hobby and Supabase Free both cover this with enormous headroom.

**One real caveat:** Supabase pauses free projects after ~7 days of low database activity. Normal daily use keeps it awake. But board Roxy for a fortnight and the project may pause — data is safe, one click to resume from the dashboard, but the sticker is dead until you do. If that becomes annoying, a free uptime pinger hitting `get_status` once a day fixes it permanently.

## Deliberately not in v1

- **Who fed her** — not wanted, and the `events` table has room to add it later
- **"Nobody's fed her by 8pm" nudges** — needs a cron and a push channel. Revisit once you know you actually use this
- **Multiple *scheduled* meals** — the schema supports it; the UI treats anything past the first as an anomaly. Moving Roxy to twice-daily properly would need a real change, not a tweak

## Known rough edges

- The 7-day history steps in fixed 24h increments, so the week either side of a DST change can be an hour off at the boundary. Cosmetic on a daily tracker; not worth the complexity.
- Anyone with the URL can mark her fed. That's the accepted price of "works on any phone with no login." The random token makes it unguessable, which is the realistic protection.
- `dog_day_start` is called several times per request. At this scale that is irrelevant; don't optimise it.
