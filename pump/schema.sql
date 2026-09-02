-- Водна помпа — maintenance check tracker.
-- Runs on the SAME Supabase project as the Roxy fed tracker (`roxy`), on
-- purpose: a project touched four times a year would be paused by the free
-- tier's inactivity timer exactly when you need it. The daily dog taps keep
-- it awake. These objects are additive and share nothing with the dog's.
--
-- Note on the shape: the dog's `events` table has a foreign key to
-- `households`, so it cannot be reused as-is for a maintenance item. This is
-- its own pair of tables rather than a strained reuse of that one.

-- ============================================================
-- Tables
-- ============================================================

create table public.maint_items (
  token           text primary key,
  name            text not null,
  interval_months smallint not null default 3,
  -- How long before the due date the page turns amber.
  due_soon_days   smallint not null default 14,
  timezone        text not null default 'Europe/Berlin',
  created_at      timestamptz not null default now()
);

-- The unit here is the DAY, not the instant: "checked on Sunday" is the fact
-- worth keeping, and storing a `date` sidesteps every timezone and DST
-- question the dog tracker had to reason about. `created_at` stays a
-- timestamptz because the undo window is about the tap, not the check.
create table public.maint_checks (
  id          bigint generated always as identity primary key,
  token       text not null references public.maint_items(token) on delete cascade,
  checked_on  date not null,
  note        text,
  created_at  timestamptz not null default now()
);

-- One check per item per day. Makes a second tap on the same day a no-op at
-- the database level rather than something the UI has to police.
create unique index maint_checks_token_day_idx
  on public.maint_checks (token, checked_on);

-- RLS on with zero policies = deny all. Belt and braces alongside the revokes.
alter table public.maint_items  enable row level security;
alter table public.maint_checks enable row level security;

revoke all on public.maint_items  from anon, authenticated;
revoke all on public.maint_checks from anon, authenticated;

-- ============================================================
-- get_item_status
--
-- Every date the page displays is computed here, so the page never consults
-- the phone's clock. A phone with the wrong date cannot produce a wrong
-- answer, and there is no clock-skew correction to get wrong.
-- ============================================================

create or replace function public.get_item_status(p_token text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  it        public.maint_items%rowtype;
  v_today   date;
  v_last    public.maint_checks%rowtype;
  v_recent  public.maint_checks%rowtype;
  v_due     date;
  v_status  text;
  v_undo    int := 0;
  v_undo_id bigint;
  v_hist    jsonb;
begin
  select * into it from public.maint_items where token = p_token;
  if not found then
    -- Deliberately generic: this endpoint must not be a token oracle.
    return jsonb_build_object('ok', false, 'error', 'unknown');
  end if;

  v_today := (now() at time zone it.timezone)::date;

  select * into v_last
  from public.maint_checks
  where token = p_token
  order by checked_on desc, created_at desc
  limit 1;

  if v_last.id is null then
    -- Never checked. Not the same as "checked long ago", and the page says so.
    v_status := 'never';
  else
    v_due := (v_last.checked_on + make_interval(months => it.interval_months))::date;
    v_status := case
      when v_due <  v_today                        then 'overdue'
      when v_due -  v_today <= it.due_soon_days     then 'soon'
      else 'ok'
    end;

    if v_last.created_at > now() - interval '10 minutes' then
      v_undo := ceil(extract(epoch from
                  (v_last.created_at + interval '10 minutes' - now())))::int;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'on', h.checked_on, 'note', h.note)
                            order by h.checked_on desc), '[]'::jsonb)
    into v_hist
  from (
    select id, checked_on, note
    from public.maint_checks
    where token = p_token
    order by checked_on desc
    limit 8
  ) h;

  return jsonb_build_object(
    'ok',              true,
    'name',            it.name,
    'interval_months', it.interval_months,
    'today',           v_today,
    'status',          v_status,
    'last_checked_on', v_last.checked_on,
    'last_check_id',   v_last.id,
    'last_note',       v_last.note,
    'due_on',          v_due,
    'days_left',       case when v_due is null then null else v_due - v_today end,
    'cycle_days',      case when v_due is null then null else v_due - v_last.checked_on end,
    'days_elapsed',    case when v_due is null then null else v_today - v_last.checked_on end,
    'can_undo',        v_undo > 0,
    'undo_seconds',    v_undo,
    'undo_check_id',   v_undo_id,
    'undo_on',         case when v_undo > 0 then v_recent.checked_on else null end,
    'history',         v_hist
  );
end;
$$;

-- ============================================================
-- record_check
--
-- Unlike the dog's record_feed there is no "are you sure" path: doing this
-- twice is harmless, forgetting it for nine months is the failure. So a
-- repeat on the same day is silently absorbed, never flagged.
-- ============================================================

create or replace function public.record_check(
  p_token text,
  p_on    date default null,
  p_note  text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  it     public.maint_items%rowtype;
  v_today date;
  v_on   date;
  v_note text;
  v_id   bigint;
begin
  select * into it from public.maint_items where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'unknown');
  end if;

  v_today := (now() at time zone it.timezone)::date;
  v_on    := coalesce(p_on, v_today);
  v_note  := nullif(btrim(coalesce(p_note, '')), '');
  if v_note is not null then v_note := left(v_note, 200); end if;

  -- A check in the future is always a mistake, and one from before the item
  -- existed is a fat-fingered year in the date picker.
  if v_on > v_today or v_on < v_today - 3650 then
    return public.get_item_status(p_token) || jsonb_build_object('action', 'invalid_date');
  end if;

  select id into v_id from public.maint_checks
  where token = p_token and checked_on = v_on;

  if v_id is not null then
    -- Already recorded for that day. Absorb it, but don't throw away a note
    -- the user just typed onto a row that hasn't got one.
    if v_note is not null then
      update public.maint_checks set note = v_note
      where id = v_id and note is null;
    end if;
    return public.get_item_status(p_token) || jsonb_build_object('action', 'deduped');
  end if;

  insert into public.maint_checks (token, checked_on, note)
  values (p_token, v_on, v_note);

  return public.get_item_status(p_token) || jsonb_build_object('action', 'recorded');
end;
$$;

-- ============================================================
-- undo_check — window enforced here, not just hidden in the UI
-- ============================================================

create or replace function public.undo_check(p_token text, p_check_id bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_deleted int;
begin
  if not exists (select 1 from public.maint_items where token = p_token) then
    return jsonb_build_object('ok', false, 'error', 'unknown');
  end if;

  delete from public.maint_checks
  where id = p_check_id
    and token = p_token
    and created_at > now() - interval '10 minutes';
  get diagnostics v_deleted = row_count;

  return public.get_item_status(p_token)
         || jsonb_build_object('action',
              case when v_deleted > 0 then 'undone' else 'undo_expired' end);
end;
$$;

-- ============================================================
-- Grants. Postgres grants EXECUTE to PUBLIC by default,
-- so the revokes are load-bearing, not decoration.
-- ============================================================

revoke execute on function public.get_item_status(text)             from public;
revoke execute on function public.record_check(text, date, text)    from public;
revoke execute on function public.undo_check(text, bigint)          from public;

grant execute on function public.get_item_status(text)              to anon;
grant execute on function public.record_check(text, date, text)     to anon;
grant execute on function public.undo_check(text, bigint)           to anon;

-- ============================================================
-- Seed the item. Save the returned token — it goes in the sticker URL
-- and is the only secret in the system. It is not in this repository.
-- ============================================================

-- insert into public.maint_items (token, name, interval_months)
-- values (substr(replace(gen_random_uuid()::text, '-', ''), 1, 12), 'Водна помпа', 3)
-- returning token;

-- The pump was last checked two days before setup, so the first cycle is
-- anchored to reality rather than to the day the software was installed:
-- insert into public.maint_checks (token, checked_on) values ('<token>', '2026-08-31');
