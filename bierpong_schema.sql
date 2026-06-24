-- ============================================================================
--  BIERPONG-TURNIER  ·  Supabase Schema + RLS
--  Im SQL-Editor von oben nach unten ausführen.
--  Kernidee: "freigeschaltet" = "hat mindestens eine Rolle". Kein eigenes
--  activated-Flag, das ein User selbst setzen könnte -> kein Schlupfloch.
-- ============================================================================

create extension if not exists pgcrypto;   -- für gen_random_uuid()

-- ----------------------------------------------------------------------------
-- 1) ROLLEN
-- ----------------------------------------------------------------------------
do $$ begin
  create type public.app_role as enum
    ('superadmin','admin','punkterichter','kassenwart','viewer');
exception when duplicate_object then null; end $$;
-- Später erweitern: alter type public.app_role add value 'neuerolle';

create table if not exists public.user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role    app_role not null,
  primary key (user_id, role)
);
create index if not exists idx_user_roles_user on public.user_roles(user_id);

-- ----------------------------------------------------------------------------
-- 2) HELPER-FUNKTIONEN  (SECURITY DEFINER -> umgehen RLS, kein Policy-Rekurs)
-- ----------------------------------------------------------------------------
create or replace function public.has_role(_uid uuid, _role app_role)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _uid and role = _role);
$$;

create or replace function public.is_admin(_uid uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select public.has_role(_uid,'admin') or public.has_role(_uid,'superadmin');
$$;

-- "freigeschaltet" = hat irgendeine Rolle
create or replace function public.is_activated(_uid uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = _uid);
$$;

-- ----------------------------------------------------------------------------
-- 3) PROFILE  (nur Anzeigename – nichts Sicherheitskritisches hier drin)
-- ----------------------------------------------------------------------------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at   timestamptz default now()
);

-- Profil automatisch bei Signup anlegen
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'display_name',
                           split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ----------------------------------------------------------------------------
-- 4) EINLADUNGEN  +  redeem_invite-RPC
-- ----------------------------------------------------------------------------
create table if not exists public.invites (
  code       text primary key,
  role       app_role not null default 'viewer',
  created_by uuid references auth.users(id),
  used_by    uuid references auth.users(id),
  used_at    timestamptz,
  expires_at timestamptz,
  created_at timestamptz default now()
);

-- Wird vom Client direkt nach dem Signup aufgerufen. SECURITY DEFINER ->
-- darf user_roles schreiben, ohne dass je ein service_role-Key im Frontend liegt.
create or replace function public.redeem_invite(_code text)
returns app_role language plpgsql security definer set search_path = public as $$
declare
  v_role app_role;
  v_uid  uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Nicht eingeloggt'; end if;

  select role into v_role
  from public.invites
  where code = _code
    and used_by is null
    and (expires_at is null or expires_at > now())
  for update;

  if v_role is null then
    raise exception 'Code ungültig, abgelaufen oder bereits benutzt';
  end if;

  update public.invites set used_by = v_uid, used_at = now() where code = _code;
  insert into public.user_roles (user_id, role)
    values (v_uid, v_role) on conflict do nothing;

  return v_role;
end; $$;
grant execute on function public.redeem_invite(text) to authenticated;

-- ----------------------------------------------------------------------------
-- 5) TURNIERE
-- ----------------------------------------------------------------------------
create table if not exists public.tournaments (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  format        text not null check (format in
                  ('single_elim','double_elim','group_ko','league')),
  status        text not null default 'setup' check (status in
                  ('setup','running','finished')),
  num_tables    int  not null default 1,
  third_place   boolean not null default false,   -- Spiel um Platz 3
  fifth_seventh boolean not null default false,   -- Trostrunde Platz 5 & 7 (Bundle)
  best_of       int  not null default 1,
  rules_text    text,                              -- Regelwerk -> Infos-Tab
  config        jsonb not null default '{}',       -- Hausregeln: rebuttal, re-rack, bounce...
  created_by    uuid references auth.users(id),
  created_at    timestamptz default now()
);

-- ----------------------------------------------------------------------------
-- 6) TEAMS
-- ----------------------------------------------------------------------------
create table if not exists public.teams (
  id            uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  name          text not null,
  seed          int,
  created_at    timestamptz default now()
);
create index if not exists idx_teams_tournament on public.teams(tournament_id);

-- ----------------------------------------------------------------------------
-- 7) MATCHES  (Spielplan + Becher als Ergebnis)
-- ----------------------------------------------------------------------------
create table if not exists public.matches (
  id            uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  bracket       text,        -- 'winners' | 'losers' | 'group' | 'placement'
  round         text,        -- 'QF','SF','F','3rd','5th','7th','group_a',...
  table_no      int,
  scheduled_at  timestamptz,
  team_a        uuid references public.teams(id),
  team_b        uuid references public.teams(id),
  score_a       int,         -- Becher Team A
  score_b       int,         -- Becher Team B
  winner        uuid references public.teams(id),
  status        text not null default 'scheduled'
                  check (status in ('scheduled','live','done')),
  created_at    timestamptz default now()
);
create index if not exists idx_matches_tournament on public.matches(tournament_id);
create index if not exists idx_matches_table_time on public.matches(table_no, scheduled_at);

-- Ergebnis melden (Punkterichter + Admin). Verhindert, dass ein Punkterichter
-- über ein direktes UPDATE den Spielplan umbaut – er darf NUR Ergebnisse setzen.
create or replace function public.report_result(_match uuid, _a int, _b int)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if not (public.has_role(v_uid,'punkterichter') or public.is_admin(v_uid)) then
    raise exception 'Keine Berechtigung';
  end if;
  update public.matches
    set score_a = _a, score_b = _b,
        winner  = case when _a > _b then team_a
                       when _b > _a then team_b else null end,
        status  = 'done'
    where id = _match;
  if not found then raise exception 'Match nicht gefunden'; end if;
end; $$;
grant execute on function public.report_result(uuid,int,int) to authenticated;

-- ----------------------------------------------------------------------------
-- 8) KASSE  (manuell markieren – kein Automatik-Webhook nötig)
-- ----------------------------------------------------------------------------
create table if not exists public.payments (
  id            uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  team_id       uuid references public.teams(id) on delete cascade,
  amount        numeric(8,2),
  paid          boolean not null default false,
  method        text check (method in ('bar','paypal','sonstige')),
  marked_by     uuid references auth.users(id),
  marked_at     timestamptz,
  note          text
);
create index if not exists idx_payments_tournament on public.payments(tournament_id);

-- ----------------------------------------------------------------------------
-- 9) PINNWAND
-- ----------------------------------------------------------------------------
create table if not exists public.posts (
  id            uuid primary key default gen_random_uuid(),
  tournament_id uuid references public.tournaments(id) on delete cascade,
  author        uuid references auth.users(id),
  body          text not null,
  created_at    timestamptz default now()
);
create index if not exists idx_posts_tournament on public.posts(tournament_id, created_at desc);

-- ----------------------------------------------------------------------------
-- 10) APP-CONFIG  (z.B. PayPal-Link – nur für eingeloggte/freigeschaltete User)
-- ----------------------------------------------------------------------------
create table if not exists public.app_config (
  key   text primary key,
  value text
);
-- Beispiel später:
-- insert into public.app_config(key,value) values ('paypal_link','https://paypal.me/dein-handle');

-- ----------------------------------------------------------------------------
-- 11) STANDINGS-VIEW  (inkl. Becherdifferenz als Tiebreaker)
--     security_invoker -> RLS der Basistabellen greift weiterhin
-- ----------------------------------------------------------------------------
create or replace view public.team_stats with (security_invoker = true) as
with games as (
  select tournament_id, team_a team, score_a cf, score_b ca, winner
    from public.matches where status='done' and team_a is not null
  union all
  select tournament_id, team_b team, score_b cf, score_a ca, winner
    from public.matches where status='done' and team_b is not null
)
select
  g.tournament_id,
  g.team                                                   as team_id,
  t.name,
  count(*)                                                 as games,
  count(*) filter (where g.winner = g.team)                as wins,
  count(*) filter (where g.winner is not null and g.winner <> g.team) as losses,
  coalesce(sum(g.cf),0)                                    as cups_for,
  coalesce(sum(g.ca),0)                                    as cups_against,
  coalesce(sum(g.cf - g.ca),0)                             as cup_diff
from games g join public.teams t on t.id = g.team
group by g.tournament_id, g.team, t.name;
-- Abfrage: ... order by wins desc, cup_diff desc, cups_for desc

-- ============================================================================
--  RLS  ·  hier wird durchgesetzt, NICHT im Frontend.
-- ============================================================================
alter table public.user_roles  enable row level security;
alter table public.profiles    enable row level security;
alter table public.invites     enable row level security;
alter table public.tournaments enable row level security;
alter table public.teams       enable row level security;
alter table public.matches     enable row level security;
alter table public.payments    enable row level security;
alter table public.posts       enable row level security;
alter table public.app_config  enable row level security;

-- ---- USER_ROLES : superadmin alles · admin nur Nicht-Admin-Rollen vergeben --
create policy ur_superadmin_all on public.user_roles for all to authenticated
  using  (public.has_role(auth.uid(),'superadmin'))
  with check (public.has_role(auth.uid(),'superadmin'));

create policy ur_admin_grant on public.user_roles for insert to authenticated
  with check (public.has_role(auth.uid(),'admin')
              and role in ('punkterichter','kassenwart','viewer'));

create policy ur_admin_revoke on public.user_roles for delete to authenticated
  using (public.has_role(auth.uid(),'admin')
         and role in ('punkterichter','kassenwart','viewer'));

create policy ur_select_own on public.user_roles for select to authenticated
  using (user_id = auth.uid() or public.is_admin(auth.uid()));

-- ---- PROFILES : eigenes lesen/ändern · Admin sieht alle -------------------
create policy pr_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin(auth.uid()));
create policy pr_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ---- INVITES : Admin/Superadmin verwalten (redeem läuft via RPC) ----------
create policy inv_superadmin_all on public.invites for all to authenticated
  using  (public.has_role(auth.uid(),'superadmin'))
  with check (public.has_role(auth.uid(),'superadmin'));
create policy inv_admin_select on public.invites for select to authenticated
  using (public.is_admin(auth.uid()));
create policy inv_admin_insert on public.invites for insert to authenticated
  with check (public.has_role(auth.uid(),'admin')
              and role in ('punkterichter','kassenwart','viewer'));

-- ---- TOURNAMENTS / TEAMS : alle Freigeschalteten lesen · Admin schreiben --
create policy t_select  on public.tournaments for select to authenticated
  using (public.is_activated(auth.uid()));
create policy t_write   on public.tournaments for all to authenticated
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

create policy tm_select on public.teams for select to authenticated
  using (public.is_activated(auth.uid()));
create policy tm_write  on public.teams for all to authenticated
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---- MATCHES : alle lesen · Schreiben Admin · Ergebnisse via report_result -
create policy m_select on public.matches for select to authenticated
  using (public.is_activated(auth.uid()));
create policy m_write  on public.matches for all to authenticated
  using (public.is_admin(auth.uid())) with check (public.is_admin(auth.uid()));

-- ---- PAYMENTS : nur Kassenwart + Admin ------------------------------------
create policy pay_rw on public.payments for all to authenticated
  using  (public.has_role(auth.uid(),'kassenwart') or public.is_admin(auth.uid()))
  with check (public.has_role(auth.uid(),'kassenwart') or public.is_admin(auth.uid()));

-- ---- POSTS : alle lesen · selbst posten · eigenes/Admin löschen -----------
create policy po_select on public.posts for select to authenticated
  using (public.is_activated(auth.uid()));
create policy po_insert on public.posts for insert to authenticated
  with check (author = auth.uid() and public.is_activated(auth.uid()));
create policy po_delete on public.posts for delete to authenticated
  using (author = auth.uid() or public.is_admin(auth.uid()));

-- ---- APP_CONFIG : nur Freigeschaltete lesen · nur Superadmin schreiben -----
create policy cfg_select on public.app_config for select to authenticated
  using (public.is_activated(auth.uid()));
create policy cfg_write  on public.app_config for all to authenticated
  using (public.has_role(auth.uid(),'superadmin'))
  with check (public.has_role(auth.uid(),'superadmin'));

-- ============================================================================
--  BOOTSTRAP  ·  EINMALIG nach deinem eigenen Signup ausführen
--  (Henne-Ei: der erste superadmin kann nicht per Invite kommen)
-- ============================================================================
-- insert into public.user_roles (user_id, role)
-- select id, 'superadmin' from auth.users where email = 'DEINE@email.de';