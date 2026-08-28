-- Roxy Fed Tracker — full schema.
-- Run as a single migration on a fresh Supabase project.

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
language sql stable set search_path = public as $$
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
    'timezone',         h.timezone,
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

-- Internal helper: not part of the client API surface.
revoke execute on function public.dog_day_start(text, smallint, timestamptz)
  from public, anon, authenticated;

revoke execute on function public.get_status(text)             from public;
revoke execute on function public.record_feed(text, boolean)   from public;
revoke execute on function public.undo_feed(text, bigint)      from public;

grant execute on function public.get_status(text)              to anon;
grant execute on function public.record_feed(text, boolean)    to anon;
grant execute on function public.undo_feed(text, bigint)       to anon;

-- ============================================================
-- Seed the household. Save the returned token — it goes in the
-- sticker URL and is the only secret in the system.
-- ============================================================

insert into public.households (token, dog_name, timezone, rollover_hour)
values (substr(replace(gen_random_uuid()::text, '-', ''), 1, 12), 'Рокси', 'Europe/Berlin', 3)
returning token;
