-- Smart Cube: online accounts, MMR, ranked matches, badges and leaderboard.
-- Run this once in your Supabase project: SQL Editor -> New query -> paste -> Run.
-- It is safe to run again (it only creates what is missing and replaces the functions).

-- ---------------------------------------------------------------------------
-- Profiles: one per account. Everyone can read them (leaderboard); you can
-- only change your own name / avatar / best time. MMR and wins/losses can
-- only change through report_match() below.
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    text not null unique
              check (char_length(username) between 3 and 16 and username ~ '^[A-Za-z0-9_-]+$'),
  avatar      text not null default '🧊' check (char_length(avatar) <= 8),
  mmr         integer not null default 1000,
  wins        integer not null default 0,
  losses      integer not null default 0,
  best_single integer check (best_single is null or best_single > 0),   -- milliseconds
  created_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists "profiles are public" on public.profiles;
create policy "profiles are public" on public.profiles for select using (true);
drop policy if exists "update own profile" on public.profiles;
create policy "update own profile" on public.profiles for update
  using (auth.uid() = id) with check (auth.uid() = id);

-- Only these columns may be changed by the player themselves.
revoke insert, update, delete on public.profiles from anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant update (username, avatar, best_single) on public.profiles to authenticated;

-- Usernames: block obvious abuse (checked on sign-up and on every rename).
create or replace function public.username_ok(n text) returns boolean
language sql immutable as $$
  select n !~* '(fuck|shit|cunt|nigg|faggot|hitler|nazi|porn|kanker|hoer|bitch|whore|slut)'
$$;
alter table public.profiles drop constraint if exists profiles_username_clean;
alter table public.profiles add constraint profiles_username_clean check (public.username_ok(username)) not valid;

-- Leaderboard: only players with at least 3 ranked rounds are listed (games = wins + losses).
alter table public.profiles add column if not exists games integer generated always as (wins + losses) stored;

-- A profile is created automatically when someone signs up.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  wanted text := coalesce(new.raw_user_meta_data ->> 'username', '');
begin
  if wanted !~ '^[A-Za-z0-9_-]{3,16}$' or not public.username_ok(wanted)
     or exists (select 1 from public.profiles where username = wanted) then
    wanted := 'cuber_' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;
  insert into public.profiles (id, username) values (new.id, wanted) on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Ranked matches. Both players report the same result; only when the two
-- reports agree does the server update MMR (Elo, K = 32), once per match.
-- ---------------------------------------------------------------------------
create table if not exists public.match_reports (
  match_id   text not null check (char_length(match_id) between 8 and 64),
  reporter   uuid not null references public.profiles (id) on delete cascade,
  opponent   uuid not null references public.profiles (id) on delete cascade,
  my_time    integer,          -- ms, null = DNF
  opp_time   integer,
  created_at timestamptz not null default now(),
  primary key (match_id, reporter)
);
alter table public.match_reports enable row level security;   -- no policies: only report_match() touches it
revoke all on public.match_reports from anon, authenticated;

create table if not exists public.matches (
  match_id   text primary key,
  player_a   uuid references public.profiles (id) on delete set null,
  player_b   uuid references public.profiles (id) on delete set null,
  time_a     integer,
  time_b     integer,
  winner     uuid,
  mmr_change integer not null,  -- added to player_a, subtracted from player_b
  created_at timestamptz not null default now()
);
alter table public.matches enable row level security;
drop policy if exists "matches are public" on public.matches;
create policy "matches are public" on public.matches for select using (true);
revoke insert, update, delete on public.matches from anon, authenticated;
grant select on public.matches to anon, authenticated;

create or replace function public.report_match(p_match text, p_opponent uuid, p_my_time integer, p_opp_time integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me      uuid := auth.uid();
  other   public.match_reports%rowtype;
  done    public.matches%rowtype;
  ra      integer;
  rb      integer;
  expect  double precision;
  score   double precision;
  delta   integer;
  win     uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  if me = p_opponent then raise exception 'you cannot play yourself'; end if;
  if (p_my_time is not null and p_my_time <= 0) or (p_opp_time is not null and p_opp_time <= 0) then
    raise exception 'invalid time';
  end if;

  perform pg_advisory_xact_lock(hashtext(p_match));     -- one report at a time per match

  select * into done from public.matches where match_id = p_match;
  if found then
    return jsonb_build_object('status', 'done',
      'delta', case when done.player_a = me then done.mmr_change else -done.mmr_change end);
  end if;

  insert into public.match_reports (match_id, reporter, opponent, my_time, opp_time)
  values (p_match, me, p_opponent, p_my_time, p_opp_time)
  on conflict (match_id, reporter) do nothing;

  select * into other from public.match_reports
   where match_id = p_match and reporter = p_opponent and opponent = me;
  if not found then
    return jsonb_build_object('status', 'waiting');
  end if;

  -- the two reports must describe the same race
  if coalesce(other.my_time, -1) <> coalesce(p_opp_time, -1)
     or coalesce(other.opp_time, -1) <> coalesce(p_my_time, -1) then
    return jsonb_build_object('status', 'mismatch');
  end if;

  if p_my_time is null and p_opp_time is null then score := 0.5; win := null;
  elsif p_opp_time is null or (p_my_time is not null and p_my_time < p_opp_time) then score := 1; win := me;
  elsif p_my_time is null or p_opp_time < p_my_time then score := 0; win := p_opponent;
  else score := 0.5; win := null;
  end if;

  select mmr into ra from public.profiles where id = me for update;
  select mmr into rb from public.profiles where id = p_opponent for update;
  expect := 1.0 / (1.0 + power(10.0, (rb - ra) / 400.0));
  delta  := round(32 * (score - expect));

  update public.profiles
     set mmr = mmr + delta, wins = wins + (score = 1)::int, losses = losses + (score = 0)::int
   where id = me;
  update public.profiles
     set mmr = mmr - delta, wins = wins + (score = 0)::int, losses = losses + (score = 1)::int
   where id = p_opponent;

  insert into public.matches (match_id, player_a, player_b, time_a, time_b, winner, mmr_change)
  values (p_match, me, p_opponent, p_my_time, p_opp_time, win, delta);

  return jsonb_build_object('status', 'done', 'delta', delta);
end $$;

revoke all on function public.report_match(text, uuid, integer, integer) from public, anon;
grant execute on function public.report_match(text, uuid, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Badges: everyone can see them; you can add your own.
-- ---------------------------------------------------------------------------
create table if not exists public.user_badges (
  user_id   uuid not null references public.profiles (id) on delete cascade,
  badge     text not null check (char_length(badge) <= 32),
  earned_at timestamptz not null default now(),
  primary key (user_id, badge)
);
alter table public.user_badges enable row level security;
drop policy if exists "badges are public" on public.user_badges;
create policy "badges are public" on public.user_badges for select using (true);
drop policy if exists "add own badges" on public.user_badges;
create policy "add own badges" on public.user_badges for insert with check (auth.uid() = user_id);
revoke update, delete on public.user_badges from anon, authenticated;
grant select on public.user_badges to anon, authenticated;
grant insert on public.user_badges to authenticated;

-- ---------------------------------------------------------------------------
-- Feature requests from the "Request a feature" button. Anyone can send one;
-- nobody can read them through the app — read them in Table Editor.
-- ---------------------------------------------------------------------------
create table if not exists public.feature_requests (
  id         bigint generated always as identity primary key,
  message    text not null check (char_length(message) between 5 and 2000),
  contact    text check (contact is null or char_length(contact) <= 120),
  page       text check (page is null or char_length(page) <= 20),
  user_id    uuid default auth.uid(),
  created_at timestamptz not null default now()
);
alter table public.feature_requests enable row level security;
drop policy if exists "anyone can send a request" on public.feature_requests;
create policy "anyone can send a request" on public.feature_requests for insert with check (true);
revoke all on public.feature_requests from anon, authenticated;
grant insert (message, contact, page) on public.feature_requests to anon, authenticated;

-- ---------------------------------------------------------------------------
-- "Delete my account" (GDPR): removes the signed-in user. Their profile, badges
-- and match reports go with it; finished matches keep the result without the name.
-- ---------------------------------------------------------------------------
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- ---------------------------------------------------------------------------
-- Fastest-solves leaderboard: best singles below 3 s (faster than the world
-- record) are refused, so obviously fake times can't top the list.
-- ---------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_best_single_sane;
alter table public.profiles add constraint profiles_best_single_sane
  check (best_single is null or best_single >= 3000) not valid;
create index if not exists profiles_best_single_idx on public.profiles (best_single) where best_single is not null;

-- ===========================================================================
-- Hardening (safe to re-run)
-- ===========================================================================

-- Helper used in a constraint: fixed search_path (Supabase security advisor).
create or replace function public.username_ok(n text) returns boolean
language sql immutable set search_path = '' as $$
  select n !~* '(fuck|shit|cunt|nigg|faggot|hitler|nazi|porn|kanker|hoer|bitch|whore|slut)'
$$;

-- Usernames are unique regardless of capital letters (no "explosiveowner" next to "ExplosiveOwner").
create unique index if not exists profiles_username_lower_idx on public.profiles (lower(username));

-- Avatars: only the emojis offered in the app.
alter table public.profiles drop constraint if exists profiles_avatar_allowed;
alter table public.profiles add constraint profiles_avatar_allowed check (avatar = any (array[
  '🧊','🟥','🟧','🟨','🟩','🟦','⬜','🐟','🦊','🐼','🐸','🐙','🦄','🐉','🚀','⚡','🔥','🌈','👑','🎯','🧠','🤖','👾','😎'
]::text[])) not valid;

-- Badges: only known badges, and the ones the server can check are verified.
create or replace function public.check_badge()
returns trigger language plpgsql security definer set search_path = public as $$
declare p public.profiles%rowtype;
begin
  -- only badges the server can check are stored online; practice badges stay on the player's own device
  if new.badge not in ('sub60','sub30','sub20','sub10','win1','mmr1200') then
    raise exception 'this badge is not stored online';
  end if;
  select * into p from public.profiles where id = new.user_id;
  if (new.badge = 'win1' and coalesce(p.wins, 0) < 1)
     or (new.badge = 'mmr1200' and coalesce(p.mmr, 0) < 1200)
     or (new.badge = 'sub60' and (p.best_single is null or p.best_single >= 60000))
     or (new.badge = 'sub30' and (p.best_single is null or p.best_single >= 30000))
     or (new.badge = 'sub20' and (p.best_single is null or p.best_single >= 20000))
     or (new.badge = 'sub10' and (p.best_single is null or p.best_single >= 10000)) then
    raise exception 'badge not earned';
  end if;
  new.earned_at := now();
  return new;
end $$;
drop trigger if exists user_badges_check on public.user_badges;
create trigger user_badges_check before insert on public.user_badges
  for each row execute function public.check_badge();

-- Feature requests: at most 20 per 10 minutes for the whole site (stops flooding).
create or replace function public.limit_feature_requests()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.feature_requests where created_at > now() - interval '10 minutes') >= 20 then
    raise exception 'too many requests right now, please try again later';
  end if;
  new.created_at := now();
  new.user_id := auth.uid();
  return new;
end $$;
drop trigger if exists feature_requests_limit on public.feature_requests;
create trigger feature_requests_limit before insert on public.feature_requests
  for each row execute function public.limit_feature_requests();
create index if not exists feature_requests_created_idx on public.feature_requests (created_at);
create index if not exists match_reports_created_idx on public.match_reports (reporter, created_at);
create index if not exists matches_pair_idx on public.matches (player_a, player_b, created_at);

-- Ranked matches with anti-farming limits:
--  * at most 100 reports per player per hour (spam),
--  * at most 60 ranked results per player per day,
--  * at most 5 ranked results per pair of players per day (two accounts can't farm MMR),
--  * unmatched reports older than 2 days are cleaned up.
create or replace function public.report_match(p_match text, p_opponent uuid, p_my_time integer, p_opp_time integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me      uuid := auth.uid();
  other   public.match_reports%rowtype;
  done    public.matches%rowtype;
  ra      integer;
  rb      integer;
  expect  double precision;
  score   double precision;
  delta   integer;
  win     uuid;
begin
  if me is null then raise exception 'not signed in'; end if;
  if me = p_opponent then raise exception 'you cannot play yourself'; end if;
  if p_match is null or char_length(p_match) not between 8 and 64 then raise exception 'invalid match id'; end if;
  if (p_my_time is not null and (p_my_time < 3000 or p_my_time > 3600000))
     or (p_opp_time is not null and (p_opp_time < 3000 or p_opp_time > 3600000)) then
    raise exception 'invalid time';
  end if;
  if not exists (select 1 from public.profiles where id = p_opponent) then raise exception 'unknown opponent'; end if;

  perform pg_advisory_xact_lock(hashtext(p_match));     -- one report at a time per match

  select * into done from public.matches where match_id = p_match;
  if found then
    if me not in (done.player_a, done.player_b) then raise exception 'not your match'; end if;
    return jsonb_build_object('status', 'done',
      'delta', case when done.player_a = me then done.mmr_change else -done.mmr_change end);
  end if;

  if (select count(*) from public.match_reports where reporter = me and created_at > now() - interval '1 hour') >= 100 then
    raise exception 'too many reports, slow down';
  end if;
  delete from public.match_reports where created_at < now() - interval '2 days';

  insert into public.match_reports (match_id, reporter, opponent, my_time, opp_time)
  values (p_match, me, p_opponent, p_my_time, p_opp_time)
  on conflict (match_id, reporter) do nothing;

  select * into other from public.match_reports
   where match_id = p_match and reporter = p_opponent and opponent = me;
  if not found then
    return jsonb_build_object('status', 'waiting');
  end if;

  if coalesce(other.my_time, -1) <> coalesce(p_opp_time, -1)
     or coalesce(other.opp_time, -1) <> coalesce(p_my_time, -1) then
    return jsonb_build_object('status', 'mismatch');
  end if;

  -- anti-farming: limits per day
  if (select count(*) from public.matches
       where created_at > now() - interval '1 day'
         and ((player_a = me and player_b = p_opponent) or (player_a = p_opponent and player_b = me))) >= 5
     or (select count(*) from public.matches
       where created_at > now() - interval '1 day' and (player_a in (me, p_opponent) or player_b in (me, p_opponent))) >= 60 then
    return jsonb_build_object('status', 'limit');
  end if;

  if p_my_time is null and p_opp_time is null then score := 0.5; win := null;
  elsif p_opp_time is null or (p_my_time is not null and p_my_time < p_opp_time) then score := 1; win := me;
  elsif p_my_time is null or p_opp_time < p_my_time then score := 0; win := p_opponent;
  else score := 0.5; win := null;
  end if;

  select mmr into ra from public.profiles where id = me for update;
  select mmr into rb from public.profiles where id = p_opponent for update;
  expect := 1.0 / (1.0 + power(10.0, (rb - ra) / 400.0));
  delta  := round(32 * (score - expect));

  update public.profiles
     set mmr = mmr + delta, wins = wins + (score = 1)::int, losses = losses + (score = 0)::int
   where id = me;
  update public.profiles
     set mmr = mmr - delta, wins = wins + (score = 0)::int, losses = losses + (score = 1)::int
   where id = p_opponent;

  insert into public.matches (match_id, player_a, player_b, time_a, time_b, winner, mmr_change)
  values (p_match, me, p_opponent, p_my_time, p_opp_time, win, delta);

  return jsonb_build_object('status', 'done', 'delta', delta);
end $$;
revoke all on function public.report_match(text, uuid, integer, integer) from public, anon;
grant execute on function public.report_match(text, uuid, integer, integer) to authenticated;

-- Internal functions are not callable through the API.
revoke all on function public.check_badge() from public, anon, authenticated;
revoke all on function public.limit_feature_requests() from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- Clean-up: keep only online badges that the profile backs up (practice badges live on the device only).
delete from public.user_badges b
 using public.profiles p
 where p.id = b.user_id
   and (b.badge not in ('sub60','sub30','sub20','sub10','win1','mmr1200')
        or (b.badge = 'win1' and coalesce(p.wins, 0) < 1)
        or (b.badge = 'mmr1200' and coalesce(p.mmr, 0) < 1200)
        or (b.badge = 'sub60' and (p.best_single is null or p.best_single >= 60000))
        or (b.badge = 'sub30' and (p.best_single is null or p.best_single >= 30000))
        or (b.badge = 'sub20' and (p.best_single is null or p.best_single >= 20000))
        or (b.badge = 'sub10' and (p.best_single is null or p.best_single >= 10000)));

-- ===========================================================================
-- Hardening, round 2 (found by testing attacks on a copy of this database)
-- ===========================================================================

-- Sign-up no longer fails when the wanted name only differs in capitals from an existing one.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  wanted text := coalesce(new.raw_user_meta_data ->> 'username', '');
begin
  if wanted !~ '^[A-Za-z0-9_-]{3,16}$' or not public.username_ok(wanted)
     or exists (select 1 from public.profiles where lower(username) = lower(wanted)) then
    wanted := 'cuber_' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;
  insert into public.profiles (id, username) values (new.id, wanted) on conflict (id) do nothing;
  return new;
end $$;
revoke all on function public.handle_new_user() from public, anon, authenticated;

-- Players can never wipe or alter table structure (Supabase grants these by default).
revoke truncate, references, trigger on public.profiles, public.user_badges, public.matches,
  public.match_reports, public.feature_requests from anon, authenticated;

-- Feature requests: separate limits, so anonymous spam can't block signed-in players.
--  * anonymous visitors together: at most 10 per 10 minutes
--  * each signed-in player: at most 5 per hour
--  * never more than 5000 stored (read and clear them now and then)
create or replace function public.limit_feature_requests()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.created_at := now();
  new.user_id := auth.uid();
  if new.user_id is null then
    if (select count(*) from public.feature_requests
         where user_id is null and created_at > now() - interval '10 minutes') >= 10 then
      raise exception 'too many requests right now, please try again later';
    end if;
  elsif (select count(*) from public.feature_requests
          where user_id = new.user_id and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'too many requests right now, please try again later';
  end if;
  if (select count(*) from public.feature_requests) >= 5000 then
    raise exception 'too many requests right now, please try again later';
  end if;
  return new;
end $$;
revoke all on function public.limit_feature_requests() from public, anon, authenticated;
create index if not exists feature_requests_user_idx on public.feature_requests (user_id, created_at);
