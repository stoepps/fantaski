-- =====================================================================
-- Ski-Fantasy · Datenbank-Setup für Supabase
-- Einmal komplett im SQL Editor ausführen. Mehrfaches Ausführen ist
-- unschädlich (bestehende Daten bleiben erhalten).
-- =====================================================================

-- ---------- Erweiterungen (Zeitsteuerung + Web-Abruf der Resultate) ----
do $$ begin
  begin create extension if not exists pg_cron with schema pg_catalog;
  exception when others then raise notice 'pg_cron: %', sqlerrm; end;
  begin create extension if not exists pg_net with schema extensions;
  exception when others then raise notice 'pg_net: %', sqlerrm; end;
end $$;

-- ---------- Hilfsfunktionen ----------
create or replace function fold(t text) returns text
language sql immutable as $$
  select trim(both '-' from regexp_replace(
    replace(replace(replace(
      translate(replace(lower(coalesce(t,'')),'ß','ss'),
        'áàâäãåāăąçćčďéèêëēěęíìîïīľĺłñńňóòôöõøōőŕřšśşťúùûüūůűýÿžźżđæ','aaaaaaaaacccdeeeeeeeiiiiilllnnnoooooooorrssstuuuuuuuyyzzzda'),
      'ae','a'),'oe','o'),'ue','u'),
    '[^a-z0-9]+','-','g'))
$$;

create or replace function pts_for(r int) returns int
language sql immutable as $$
  select case when r between 1 and 30 then
    (array[100,80,60,50,45,40,36,32,29,26,24,22,20,18,16,15,14,13,12,11,10,9,8,7,6,5,4,3,2,1])[r]
  else 0 end
$$;

create or replace function new_token() returns text
language sql volatile as $$ select replace(gen_random_uuid()::text,'-','') $$;

-- ---------- Tabellen ----------
create table if not exists settings (
  id int primary key default 1 check (id = 1),
  league_name text not null default 'Ski-Fantasy',
  invite_code text not null default substr(replace(gen_random_uuid()::text,'-',''),1,10),
  reg_deadline timestamptz not null default '2026-11-08 23:59:00 Europe/Zurich',
  order_draw_at timestamptz not null default '2026-11-09 08:00:00 Europe/Zurich',
  draft_at timestamptz not null default '2026-11-12 20:00:00 Europe/Zurich',
  season_start date not null default '2026-11-14',
  max_transfers int not null default 2,
  per_gender int not null default 5,
  results_url text not null default 'https://raw.githubusercontent.com/stoepps/fantaski/main/data/results.json',
  order_drawn boolean not null default false,
  draft_done boolean not null default false,
  last_transfer_run timestamptz,
  pending_req bigint,
  pending_since timestamptz,
  last_request_at timestamptz,
  last_ingest_at timestamptz,
  last_ingest_status text
);
insert into settings (id) values (1) on conflict do nothing;

create table if not exists players (
  id serial primary key,
  name text not null,
  token text not null unique default new_token(),
  is_admin boolean not null default false,
  active boolean not null default true,
  draft_pos int,
  joined_at timestamptz not null default now()
);
create unique index if not exists players_name_uq on players (lower(name)) where active;

create table if not exists athletes (
  id text primary key,
  first text not null,
  last text not null,
  nat text not null default '',
  g text not null check (g in ('m','w')),
  prev int not null default 0,
  prev_rank int,
  key text generated always as (fold(first || ' ' || last)) stored
);
create index if not exists athletes_key on athletes (key);

create table if not exists draft_wish (
  player_id int references players(id) on delete cascade,
  g text check (g in ('m','w')),
  list text[] not null default '{}',
  updated_at timestamptz not null default now(),
  primary key (player_id, g)
);

create table if not exists draft_picks (
  n int primary key,
  player_id int references players(id),
  athlete_id text references athletes(id),
  g text, round int, auto boolean, at timestamptz default now()
);

create table if not exists ownership (
  id serial primary key,
  athlete_id text not null references athletes(id),
  player_id int not null references players(id),
  from_ts timestamptz not null,
  to_ts timestamptz,
  how text not null
);
create unique index if not exists ownership_open on ownership (athlete_id) where to_ts is null;

create table if not exists transfer_wish (
  player_id int primary key references players(id) on delete cascade,
  wants text[] not null default '{}',
  drops_m text[] not null default '{}',
  drops_w text[] not null default '{}',
  updated_at timestamptz not null default now()
);

create table if not exists transfers (
  id serial primary key,
  run_at timestamptz not null,
  player_id int references players(id),
  out_id text references athletes(id),
  in_id text references athletes(id)
);

create table if not exists races (
  id text primary key,
  date date not null,
  place text not null,
  disc text not null,
  g text not null check (g in ('m','w')),
  source text,
  imported_at timestamptz not null default now()
);

create table if not exists race_results (
  race_id text references races(id) on delete cascade,
  athlete_id text references athletes(id),
  rank int not null,
  pts int not null,
  primary key (race_id, athlete_id)
);

-- Basistabellen sind nur über Views und Funktionen erreichbar
do $$ declare t text; begin
  foreach t in array array['settings','players','athletes','draft_wish','draft_picks','ownership','transfer_wish','transfers','races','race_results'] loop
    execute format('alter table %I enable row level security', t);
    begin execute format('revoke all on %I from anon, authenticated', t);
    exception when undefined_object then null; end;
  end loop;
end $$;

-- ---------- Öffentliche Sicht (nur lesen) ----------
create or replace view v_settings as
  select league_name, reg_deadline, order_draw_at, draft_at, season_start, max_transfers, per_gender,
         order_drawn, draft_done, last_transfer_run, last_ingest_at, last_ingest_status
  from settings where id = 1;

create or replace view v_players as
  select id, name, draft_pos, joined_at from players where active;

create or replace view v_athletes as
  select id, first, last, nat, g, prev, prev_rank from athletes;

create or replace view v_races as
  select r.id, r.date, r.place, r.disc, r.g, r.source,
         (r.date >= (select season_start from settings where id = 1)) as counts
  from races r;

create or replace view v_results as
  select race_id, athlete_id, rank, pts from race_results;

create or replace view v_ownership as
  select o.athlete_id, o.player_id, o.from_ts, o.to_ts, o.how from ownership o
  where (select draft_done from settings where id = 1);

create or replace view v_player_race_pts as
  select o.player_id, rr.race_id, sum(rr.pts)::int as pts
  from race_results rr
  join races r on r.id = rr.race_id
  join ownership o on o.athlete_id = rr.athlete_id
    and o.from_ts <= (r.date::timestamp at time zone 'Europe/Zurich')
    and (o.to_ts is null or o.to_ts > (r.date::timestamp at time zone 'Europe/Zurich'))
  where r.date >= (select season_start from settings where id = 1)
  group by o.player_id, rr.race_id;

create or replace view v_owned_pts as
  select o.player_id, rr.athlete_id, sum(rr.pts)::int as pts
  from race_results rr
  join races r on r.id = rr.race_id
  join ownership o on o.athlete_id = rr.athlete_id
    and o.from_ts <= (r.date::timestamp at time zone 'Europe/Zurich')
    and (o.to_ts is null or o.to_ts > (r.date::timestamp at time zone 'Europe/Zurich'))
  where r.date >= (select season_start from settings where id = 1)
  group by o.player_id, rr.athlete_id;

create or replace view v_standings as
  select p.id as player_id, p.name, p.draft_pos,
         coalesce((select sum(x.pts) from v_player_race_pts x where x.player_id = p.id), 0)::int as total
  from players p where p.active;

create or replace view v_draft_picks as
  select n, player_id, athlete_id, g, round, auto from draft_picks
  where (select draft_done from settings where id = 1);

create or replace view v_transfers as
  select id, run_at, player_id, out_id, in_id from transfers;

grant select on v_settings, v_players, v_athletes, v_races, v_results, v_ownership,
  v_player_race_pts, v_owned_pts, v_standings, v_draft_picks, v_transfers to anon, authenticated;

-- ---------- interne Hilfen ----------
create or replace function player_by_token(p_token text) returns players
language plpgsql security definer set search_path = public as $$
declare p players;
begin
  select * into p from players where token = p_token and active;
  if p.id is null then raise exception 'Unbekannter Link. Bitte den persönlichen Link verwenden.'; end if;
  return p;
end $$;

create or replace function roster(p_player int) returns setof text
language sql stable security definer set search_path = public as $$
  select athlete_id from ownership where player_id = p_player and to_ts is null
$$;

-- ---------- Funktionen für die App ----------
create or replace function me(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare p players; s settings;
begin
  select * into p from players where token = p_token and active;
  if p.id is null then return null; end if;
  select * into s from settings where id = 1;
  return json_build_object(
    'id', p.id, 'name', p.name, 'is_admin', p.is_admin, 'draft_pos', p.draft_pos,
    'draft_wish', json_build_object(
      'm', coalesce((select list from draft_wish where player_id = p.id and g = 'm'), '{}'),
      'w', coalesce((select list from draft_wish where player_id = p.id and g = 'w'), '{}')),
    'transfer_wish', (select json_build_object('wants', wants, 'drops_m', drops_m, 'drops_w', drops_w)
                      from transfer_wish where player_id = p.id),
    'invite_code', case when p.is_admin then s.invite_code end
  );
end $$;

create or replace function register(p_invite text, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare s settings; n text := btrim(coalesce(p_name,'')); t text;
begin
  select * into s from settings where id = 1;
  if p_invite is distinct from s.invite_code then raise exception 'Der Einladungslink ist ungültig.'; end if;
  if now() > s.reg_deadline or s.order_drawn then raise exception 'Die Anmeldung ist geschlossen.'; end if;
  if length(n) < 2 or length(n) > 24 then raise exception 'Der Name muss 2 bis 24 Zeichen lang sein.'; end if;
  if exists (select 1 from players where active and lower(name) = lower(n)) then
    raise exception 'Diesen Namen gibt es schon. Bitte einen anderen wählen.'; end if;
  if (select count(*) from players where active) >= 30 then raise exception 'Die Liga ist voll.'; end if;
  insert into players (name) values (n) returning token into t;
  return t;
end $$;

create or replace function set_draft_wish(p_token text, p_g text, p_list text[]) returns void
language plpgsql security definer set search_path = public as $$
declare p players := player_by_token(p_token); clean text[];
begin
  if (select draft_done from settings where id = 1) then raise exception 'Der Draft ist bereits gelaufen.'; end if;
  if p_g not in ('m','w') then raise exception 'Ungültiges Geschlecht.'; end if;
  select coalesce(array_agg(x.a order by x.o), '{}') into clean from (
    select a, min(o) o from unnest(coalesce(p_list,'{}')) with ordinality as u(a, o)
    where exists (select 1 from athletes where id = u.a and g = p_g)
    group by a) x;
  if array_length(clean, 1) > 80 then clean := clean[1:80]; end if;
  insert into draft_wish (player_id, g, list, updated_at) values (p.id, p_g, clean, now())
  on conflict (player_id, g) do update set list = excluded.list, updated_at = now();
end $$;

create or replace function set_transfer_wish(p_token text, p_wants text[], p_drops_m text[], p_drops_w text[]) returns void
language plpgsql security definer set search_path = public as $$
declare p players := player_by_token(p_token); w text[]; dm text[]; dw text[];
begin
  if not (select draft_done from settings where id = 1) then raise exception 'Transfers sind erst nach dem Draft möglich.'; end if;
  select coalesce(array_agg(a order by o), '{}') into w from (
    select a, min(o) o from unnest(coalesce(p_wants,'{}')) with ordinality u(a, o)
    where exists (select 1 from athletes where id = u.a) and u.a not in (select roster(p.id))
    group by a) x;
  if array_length(w, 1) > 15 then w := w[1:15]; end if;
  select coalesce(array_agg(a order by o), '{}') into dm from (
    select a, min(o) o from unnest(coalesce(p_drops_m,'{}')) with ordinality u(a, o)
    where u.a in (select roster(p.id)) and exists (select 1 from athletes where id = u.a and g = 'm')
    group by a) x;
  select coalesce(array_agg(a order by o), '{}') into dw from (
    select a, min(o) o from unnest(coalesce(p_drops_w,'{}')) with ordinality u(a, o)
    where u.a in (select roster(p.id)) and exists (select 1 from athletes where id = u.a and g = 'w')
    group by a) x;
  insert into transfer_wish (player_id, wants, drops_m, drops_w, updated_at) values (p.id, w, dm, dw, now())
  on conflict (player_id) do update set wants = excluded.wants, drops_m = excluded.drops_m,
    drops_w = excluded.drops_w, updated_at = now();
end $$;

-- ---------- Spielablauf ----------
create or replace function do_draw_order() returns void
language plpgsql security definer set search_path = public as $$
begin
  if (select order_drawn from settings where id = 1) then return; end if;
  update players p set draft_pos = x.pos
  from (select id, row_number() over (order by random()) pos from players where active) x
  where p.id = x.id;
  update settings set order_drawn = true where id = 1;
end $$;

create or replace function do_draft() returns void
language plpgsql security definer set search_path = public as $$
declare
  s settings; ord int[]; base int[]; seq int[]; v_g text; r int; pid int; pick text; isauto boolean; n int := 0; ts timestamptz := now();
begin
  select * into s from settings where id = 1 for update;
  if s.draft_done then return; end if;
  if not s.order_drawn then perform do_draw_order(); end if;
  select array_agg(id order by draft_pos) into ord from players where active;
  if ord is null then raise exception 'Keine Mitspieler.'; end if;
  foreach v_g in array array['m','w'] loop
    if v_g = 'm' then base := ord; else select array_agg(v order by o desc) into base from unnest(ord) with ordinality u(v, o); end if;
    for r in 1..s.per_gender loop
      if r % 2 = 1 then seq := base; else select array_agg(v order by o desc) into seq from unnest(base) with ordinality u(v, o); end if;
      foreach pid in array seq loop
        isauto := false;
        select u.a into pick
          from draft_wish dw, unnest(dw.list) with ordinality u(a, o)
          where dw.player_id = pid and dw.g = v_g
            and exists (select 1 from athletes where id = u.a and athletes.g = v_g)
            and not exists (select 1 from ownership where athlete_id = u.a and to_ts is null)
          order by u.o limit 1;
        if pick is null then
          isauto := true;
          select id into pick from athletes a
            where a.g = v_g and not exists (select 1 from ownership where athlete_id = a.id and to_ts is null)
            order by a.prev desc, a.prev_rank asc nulls last, a.last limit 1;
        end if;
        if pick is null then raise exception 'Zu wenige Athleten im Pool.'; end if;
        insert into ownership (athlete_id, player_id, from_ts, how) values (pick, pid, ts, 'draft');
        insert into draft_picks (n, player_id, athlete_id, g, round, auto, at) values (n + 1, pid, pick, v_g, r, isauto, ts);
        n := n + 1;
      end loop;
    end loop;
  end loop;
  update settings set draft_done = true where id = 1;
end $$;

create or replace function do_transfers() returns int
language plpgsql security definer set search_path = public as $$
declare
  s settings; ts timestamptz := now(); ord int[]; rnd int; pid int; tw transfer_wish; a text; ag text; drop_id text; cnt int := 0; done boolean;
begin
  select * into s from settings where id = 1 for update;
  if not s.draft_done then return 0; end if;
  select array_agg(player_id order by total asc, draft_pos desc) into ord from v_standings;
  for rnd in 1..s.max_transfers loop
    foreach pid in array coalesce(ord, '{}') loop
      select * into tw from transfer_wish where player_id = pid;
      continue when tw.player_id is null;
      done := false;
      foreach a in array tw.wants loop
        exit when done;
        continue when exists (select 1 from ownership where athlete_id = a and to_ts is null);
        select g into ag from athletes where id = a;
        drop_id := null;
        select d into drop_id from unnest(case when ag = 'm' then tw.drops_m else tw.drops_w end) with ordinality u(d, o)
          where exists (select 1 from ownership where athlete_id = u.d and player_id = pid and to_ts is null)
          order by o limit 1;
        continue when drop_id is null;
        update ownership set to_ts = ts where athlete_id = drop_id and to_ts is null;
        insert into ownership (athlete_id, player_id, from_ts, how) values (a, pid, ts, 'transfer');
        insert into transfers (run_at, player_id, out_id, in_id) values (ts, pid, drop_id, a);
        update transfer_wish set wants = array_remove(wants, a),
          drops_m = array_remove(drops_m, drop_id), drops_w = array_remove(drops_w, drop_id)
          where player_id = pid;
        cnt := cnt + 1; done := true;
      end loop;
    end loop;
  end loop;
  -- aufräumen: erfüllte oder ungültige Einträge entfernen
  update transfer_wish t set
    wants = coalesce((select array_agg(x order by o) from unnest(t.wants) with ordinality u(x, o)
             where not exists (select 1 from ownership where athlete_id = u.x and player_id = t.player_id and to_ts is null)), '{}'),
    drops_m = coalesce((select array_agg(x order by o) from unnest(t.drops_m) with ordinality u(x, o)
             where exists (select 1 from ownership where athlete_id = u.x and player_id = t.player_id and to_ts is null)), '{}'),
    drops_w = coalesce((select array_agg(x order by o) from unnest(t.drops_w) with ordinality u(x, o)
             where exists (select 1 from ownership where athlete_id = u.x and player_id = t.player_id and to_ts is null)), '{}');
  update settings set last_transfer_run = ts where id = 1;
  return cnt;
end $$;

-- ---------- Resultate importieren ----------
create or replace function ingest_json(j jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare rc jsonb; x jsonb; aid text; k text; rg text; n int := 0; nid text;
begin
  for rc in select * from jsonb_array_elements(coalesce(j->'races', '[]'::jsonb)) loop
    rg := rc->>'g';
    continue when rc->>'id' is null or rg not in ('m','w') or rc->>'date' is null;
    insert into races (id, date, place, disc, g, source, imported_at)
      values (rc->>'id', (rc->>'date')::date, coalesce(rc->>'place',''), coalesce(rc->>'disc',''), rg, rc->>'source', now())
      on conflict (id) do update set date = excluded.date, place = excluded.place, disc = excluded.disc,
        g = excluded.g, source = excluded.source;
    delete from race_results where race_id = rc->>'id';
    for x in select * from jsonb_array_elements(coalesce(rc->'results', '[]'::jsonb)) loop
      continue when (x->>'rank') is null;
      k := fold(coalesce(x->>'first','') || ' ' || coalesce(x->>'last',''));
      aid := null;
      select id into aid from athletes where key = k and g = rg limit 1;
      if aid is null then
        select id into aid from athletes where g = rg and nat = coalesce(x->>'nat','')
          and (key like '%-' || fold(x->>'last') or key like fold(x->>'last') || '-%')
          and (select count(*) from athletes b where b.g = rg and b.nat = coalesce(x->>'nat','')
               and (b.key like '%-' || fold(x->>'last') or b.key like fold(x->>'last') || '-%')) = 1;
      end if;
      if aid is null then
        nid := k;
        while exists (select 1 from athletes where id = nid) loop nid := nid || '-' || rg; end loop;
        insert into athletes (id, first, last, nat, g, prev) values
          (nid, coalesce(x->>'first',''), coalesce(x->>'last',''), coalesce(x->>'nat',''), rg, 0) returning id into aid;
      end if;
      insert into race_results (race_id, athlete_id, rank, pts)
        values (rc->>'id', aid, (x->>'rank')::int, pts_for((x->>'rank')::int))
        on conflict do nothing;
    end loop;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function ingest_poll() returns void
language plpgsql security definer set search_path = public as $$
declare s settings; resp record; n int; rid bigint; rc int;
begin
  select * into s from settings where id = 1;
  if s.pending_req is not null then
    execute 'select status_code, content from net._http_response where id = $1' into resp using s.pending_req;
    get diagnostics rc = row_count;
    if rc > 0 then
      begin
        if resp.status_code = 200 then
          n := ingest_json(resp.content::jsonb);
          update settings set last_ingest_at = now(), last_ingest_status = 'ok · ' || n || ' Rennen' where id = 1;
        else
          update settings set last_ingest_status = 'HTTP ' || coalesce(resp.status_code::text, '?') where id = 1;
        end if;
      exception when others then
        update settings set last_ingest_status = 'Fehler: ' || left(sqlerrm, 200) where id = 1;
      end;
      update settings set pending_req = null where id = 1;
    elsif s.pending_since < now() - interval '15 minutes' then
      update settings set pending_req = null where id = 1;
    end if;
  end if;
  select * into s from settings where id = 1;
  if s.pending_req is null and (s.last_request_at is null or s.last_request_at < now() - interval '25 minutes') then
    execute 'select net.http_get($1)' into rid using s.results_url || '?t=' || extract(epoch from now())::bigint;
    update settings set pending_req = rid, pending_since = now(), last_request_at = now() where id = 1;
  end if;
end $$;

create or replace function tick() returns void
language plpgsql security definer set search_path = public as $$
declare s settings; wk timestamptz;
begin
  select * into s from settings where id = 1;
  if not s.order_drawn and now() >= s.order_draw_at then perform do_draw_order(); end if;
  select * into s from settings where id = 1;
  if s.order_drawn and not s.draft_done and now() >= s.draft_at then perform do_draft(); end if;
  select * into s from settings where id = 1;
  wk := (date_trunc('week', now() at time zone 'Europe/Zurich') + interval '12 hours') at time zone 'Europe/Zurich';
  if s.draft_done and now() >= wk and wk > s.draft_at and (s.last_transfer_run is null or s.last_transfer_run < wk) then
    perform do_transfers();
  end if;
  begin perform ingest_poll();
  exception when others then
    update settings set last_ingest_status = 'Fehler: ' || left(sqlerrm, 200) where id = 1;
  end;
end $$;

-- ---------- Admin ----------
create or replace function admin_check(p_token text) returns players
language plpgsql security definer set search_path = public as $$
declare p players := player_by_token(p_token);
begin
  if not p.is_admin then raise exception 'Nur für den Admin.'; end if;
  return p;
end $$;

create or replace function admin_state(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare p players := admin_check(p_token);
begin
  return json_build_object(
    'settings', (select row_to_json(s) from settings s where id = 1),
    'players', (select coalesce(json_agg(json_build_object('id', id, 'name', name, 'token', token, 'is_admin', is_admin,
                 'draft_pos', draft_pos, 'joined_at', joined_at,
                 'wish_m', coalesce(array_length((select list from draft_wish where player_id = pl.id and g = 'm'), 1), 0),
                 'wish_w', coalesce(array_length((select list from draft_wish where player_id = pl.id and g = 'w'), 1), 0))
                 order by joined_at), '[]') from players pl where active)
  );
end $$;

create or replace function admin_settings(p_token text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a players := admin_check(p_token);
begin
  update settings set
    league_name = coalesce(p->>'league_name', league_name),
    reg_deadline = coalesce((p->>'reg_deadline')::timestamptz, reg_deadline),
    order_draw_at = coalesce((p->>'order_draw_at')::timestamptz, order_draw_at),
    draft_at = coalesce((p->>'draft_at')::timestamptz, draft_at),
    season_start = coalesce((p->>'season_start')::date, season_start),
    max_transfers = coalesce((p->>'max_transfers')::int, max_transfers)
  where id = 1;
end $$;

create or replace function admin_add_player(p_token text, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare a players := admin_check(p_token); n text := btrim(coalesce(p_name,'')); t text;
begin
  if (select order_drawn from settings where id = 1) then raise exception 'Die Reihenfolge ist schon ausgelost.'; end if;
  if length(n) < 2 or length(n) > 24 then raise exception 'Der Name muss 2 bis 24 Zeichen lang sein.'; end if;
  if exists (select 1 from players where active and lower(name) = lower(n)) then raise exception 'Diesen Namen gibt es schon.'; end if;
  insert into players (name) values (n) returning token into t;
  return t;
end $$;

create or replace function admin_remove_player(p_token text, p_id int) returns void
language plpgsql security definer set search_path = public as $$
declare a players := admin_check(p_token);
begin
  if (select order_drawn from settings where id = 1) then raise exception 'Nach der Auslosung kann niemand mehr entfernt werden.'; end if;
  if p_id = a.id then raise exception 'Du kannst dich nicht selbst entfernen.'; end if;
  update players set active = false where id = p_id;
  delete from draft_wish where player_id = p_id;
end $$;

create or replace function admin_rename_player(p_token text, p_id int, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare a players := admin_check(p_token); n text := btrim(coalesce(p_name,''));
begin
  if length(n) < 2 or length(n) > 24 then raise exception 'Der Name muss 2 bis 24 Zeichen lang sein.'; end if;
  update players set name = n where id = p_id and active;
end $$;

create or replace function admin_action(p_token text, p_action text) returns text
language plpgsql security definer set search_path = public as $$
declare a players := admin_check(p_token); n int;
begin
  if p_action = 'draw' then perform do_draw_order(); return 'Reihenfolge ausgelost';
  elsif p_action = 'draft' then perform do_draft(); return 'Draft ausgeführt';
  elsif p_action = 'transfers' then n := do_transfers(); return n || ' Transfers ausgeführt';
  elsif p_action = 'ingest' then
    update settings set last_request_at = null, pending_req = null where id = 1;
    perform ingest_poll(); return 'Resultate werden geladen (Ergebnis in ca. 1 Minute)';
  elsif p_action = 'new_invite' then
    update settings set invite_code = substr(replace(gen_random_uuid()::text,'-',''),1,10) where id = 1;
    return 'Neuer Einladungslink erstellt';
  end if;
  raise exception 'Unbekannte Aktion.';
end $$;

-- interne Funktionen nicht über die App aufrufbar
do $$ declare f text; begin
  foreach f in array array['do_draw_order()','do_draft()','do_transfers()','ingest_json(jsonb)','ingest_poll()','tick()',
                           'player_by_token(text)','admin_check(text)','roster(integer)','new_token()'] loop
    execute format('revoke execute on function %s from public', f);
    begin execute format('revoke execute on function %s from anon, authenticated', f);
    exception when undefined_object then null; end;
  end loop;
end $$;
grant execute on function me(text), register(text,text), set_draft_wish(text,text,text[]),
  set_transfer_wish(text,text[],text[],text[]), admin_state(text), admin_settings(text,jsonb),
  admin_add_player(text,text), admin_remove_player(text,int), admin_rename_player(text,int,text),
  admin_action(text,text) to anon, authenticated;

-- ---------- Athleten (Weltcup-Gesamtwertung 2025/26 + Ergänzungen) ----------
insert into athletes (id,first,last,nat,g,prev,prev_rank) values
('marco-odermatt','Marco','Odermatt','SUI','m',1626,1),
('lucas-pinheiro-braathen','Lucas','Pinheiro Braathen','BRA','m',1058,2),
('atle-lie-mcgrath','Atle','Lie McGrath','NOR','m',936,3),
('loic-meillard','Loïc','Meillard','SUI','m',923,4),
('henrik-kristoffersen','Henrik','Kristoffersen','NOR','m',821,5),
('timon-haugan','Timon','Haugan','NOR','m',776,6),
('franjo-von-allmen','Franjo','von Allmen','SUI','m',770,7),
('vincent-kriechmayr','Vincent','Kriechmayr','AUT','m',731,8),
('dominik-paris','Dominik','Paris','ITA','m',698,9),
('giovanni-franzoni','Giovanni','Franzoni','ITA','m',663,10),
('marco-schwarz','Marco','Schwarz','AUT','m',613,11),
('raphael-haaser','Raphael','Haaser','AUT','m',531,12),
('clement-noel','Clément','Noël','FRA','m',520,13),
('alexis-monney','Alexis','Monney','SUI','m',448,14),
('stefan-rogentin','Stefan','Rogentin','SUI','m',447,15),
('stefan-brennsteiner','Stefan','Brennsteiner','AUT','m',431,16),
('paco-rassat','Paco','Rassat','FRA','m',387,17),
('alex-vinatzer','Alex','Vinatzer','ITA','m',385,18),
('nils-allegre','Nils','Allegre','FRA','m',375,19),
('ryan-cochran-siegle','Ryan','Cochran-Siegle','USA','m',342,20),
('eduard-hallberg','Eduard','Hallberg','FIN','m',339,21),
('mattia-casse','Mattia','Casse','ITA','m',302,22),
('stefan-babinsky','Stefan','Babinsky','AUT','m',300,23),
('florian-schieder','Florian','Schieder','ITA','m',299,24),
('tanguy-nef','Tanguy','Nef','SUI','m',280,25),
('daniel-hemetsberger','Daniel','Hemetsberger','AUT','m',274,26),
('adrian-smiseth-sejersted','Adrian Smiseth','Sejersted','NOR','m',264,27),
('river-radamus','River','Radamus','USA','m',261,28),
('manuel-feller','Manuel','Feller','AUT','m',247,29),
('eirik-hystad-solberg','Eirik Hystad','Solberg','NOR','m',247,29),
('linus-strasser','Linus','Strasser','GER','m',238,31),
('sam-maes','Sam','Maes','BEL','m',227,32),
('michael-matt','Michael','Matt','AUT','m',224,33),
('armand-marchant','Armand','Marchant','BEL','m',207,34),
('cameron-alexander','Cameron','Alexander','CAN','m',205,35),
('fabio-gstrein','Fabio','Gstrein','AUT','m',201,36),
('fabian-gratz','Fabian','Gratz','GER','m',194,37),
('victor-muffat-jeandet','Victor','Muffat-Jeandet','FRA','m',194,37),
('filip-zubcic','Filip','Zubčić','CRO','m',191,39),
('miha-hrobat','Miha','Hrobat','SLO','m',182,40),
('joshua-sturm','Joshua','Sturm','AUT','m',179,41),
('luca-aerni','Luca','Aerni','SUI','m',177,42),
('steven-amiez','Steven','Amiez','FRA','m',174,43),
('leo-anguenot','Leo','Anguenot','FRA','m',172,44),
('christof-innerhofer','Christof','Innerhofer','ITA','m',170,45),
('fredrik-moller','Fredrik','Møller','NOR','m',169,46),
('zan-kranjec','Žan','Kranjec','SLO','m',169,46),
('jan-zabystran','Jan','Zabystřan','CZE','m',168,48),
('alban-elezi-cannaferina','Alban','Elezi Cannaferina','FRA','m',164,49),
('benjamin-jacques-alliod','Benjamin Jacques','Alliod','ITA','m',162,50),
('maxence-muzaton','Maxence','Muzaton','FRA','m',156,51),
('alexis-pinturault','Alexis','Pinturault','FRA','m',148,52),
('justin-murisier','Justin','Murisier','SUI','m',142,53),
('anton-grammel','Anton','Grammel','GER','m',139,54),
('tommaso-sala','Tommaso','Sala','ITA','m',139,54),
('lukas-feurstein','Lukas','Feurstein','AUT','m',128,56),
('daniel-yule','Daniel','Yule','SUI','m',126,57),
('thomas-tumler','Thomas','Tumler','SUI','m',125,58),
('niels-hintermann','Niels','Hintermann','SUI','m',123,59),
('alessio-miggiano','Alessio','Miggiano','SUI','m',120,60),
('simon-jocher','Simon','Jocher','GER','m',118,61),
('nils-alphand','Nils','Alphand','FRA','m',115,62),
('laurie-taylor','Laurie','Taylor','GBR','m',112,63),
('guglielmo-bosca','Guglielmo','Bosca','ITA','m',112,63),
('oscar-andreas-sandvik','Oscar Andreas','Sandvik','NOR','m',111,65),
('albert-popov','Albert','Popov','BUL','m',106,66),
('james-crawford','James','Crawford','CAN','m',104,67),
('fabian-ax-swartz','Fabian','Ax Swartz','SWE','m',103,68),
('thibaut-favrot','Thibaut','Favrot','FRA','m',101,69),
('dominik-raschner','Dominik','Raschner','AUT','m',94,70),
('samuel-kolega','Samuel','Kolega','CRO','m',94,70),
('kyle-negomir','Kyle','Negomir','USA','m',91,72),
('patrick-feurstein','Patrick','Feurstein','AUT','m',90,73),
('dave-ryding','Dave','Ryding','GBR','m',89,74),
('elian-lehto','Elian','Lehto','FIN','m',89,74),
('marco-kohler','Marco','Kohler','SUI','m',88,76),
('matthieu-bailet','Matthieu','Bailet','FRA','m',87,77),
('jonas-stockinger','Jonas','Stockinger','GER','m',86,78),
('stefan-eichberger','Stefan','Eichberger','AUT','m',76,79),
('hans-grahl-madsen','Hans','Grahl-Madsen','NOR','m',72,80),
('matthias-iten','Matthias','Iten','SUI','m',70,81),
('martin-cater','Martin','Cater','SLO','m',70,81),
('joan-verdu','Joan','Verdu','AND','m',60,83),
('lars-rosti','Lars','Rösti','SUI','m',59,84),
('alexander-schmid','Alexander','Schmid','GER','m',59,84),
('luis-vogt','Luis','Vogt','GER','m',57,86),
('blaise-giezendanner','Blaise','Giezendanner','FRA','m',57,86),
('johannes-strolz','Johannes','Strolz','AUT','m',55,88),
('felix-monsen','Felix','Monsen','SWE','m',54,89),
('brodie-seger','Brodie','Seger','CAN','m',51,90),
('giovanni-borsotti','Giovanni','Borsotti','ITA','m',49,91),
('benjamin-ritchie','Benjamin','Ritchie','USA','m',48,92),
('andreas-ploier','Andreas','Ploier','AUT','m',45,93),
('erik-arvidsson','Erik','Arvidsson','USA','m',44,94),
('billy-major','Billy','Major','GBR','m',44,94),
('flavio-vitale','Flavio','Vitale','FRA','m',43,96),
('auguste-aulnette','Auguste','Aulnette','FRA','m',40,97),
('ramon-zenhausern','Ramon','Zenhäusern','SUI','m',40,97),
('sam-alphand','Sam','Alphand','FRA','m',39,99),
('ryder-sarchett','Ryder','Sarchett','USA','m',37,100),
('sam-morse','Sam','Morse','USA','m',37,100),
('bryce-bennett','Bryce','Bennett','USA','m',37,100),
('filippo-della-vite','Filippo','Della Vite','ITA','m',36,103),
('loevan-parand','Loevan','Parand','FRA','m',36,103),
('adrien-theaux','Adrien','Theaux','FRA','m',35,105),
('aleksander-aamodt-kilde','Aleksander','Aamodt Kilde','NOR','m',35,105),
('romed-baumann','Romed','Baumann','GER','m',35,105),
('tobias-kastlunger','Tobias','Kastlunger','ITA','m',32,108),
('luca-de-aliprandini','Luca','De Aliprandini','ITA','m',32,108),
('vincent-wieser','Vincent','Wieser','AUT','m',32,108),
('antoine-azzolin','Antoine','Azzolin','FRA','m',30,111),
('wiley-maple','Wiley','Maple','USA','m',30,111),
('riley-seger','Riley','Seger','CAN','m',29,113),
('jeffrey-read','Jeffrey','Read','CAN','m',24,114),
('livio-hiltbrand','Livio','Hiltbrand','SUI','m',23,115),
('stefan-rieser','Stefan','Rieser','AUT','m',23,115),
('hugo-desgrippes','Hugo','Desgrippes','FRA','m',22,117),
('simon-rueland','Simon','Rueland','AUT','m',22,117),
('henrik-von-appen','Henrik','Von Appen','CHI','m',21,119),
('arnaud-boisset','Arnaud','Boisset','SUI','m',20,120),
('kristoffer-jakobsen','Kristoffer','Jakobsen','SWE','m',20,120),
('joaquim-salarich-baucells','Joaquim','Salarich Baucells','ESP','m',20,120),
('adrian-pertl','Adrian','Pertl','AUT','m',18,123),
('charles-gamel-seigneur','Charles','Gamel Seigneur','FRA','m',16,124),
('rasmus-bakkevig','Rasmus','Bakkevig','NOR','m',16,124),
('erik-read','Erik','Read','CAN','m',15,126),
('albert-ortega-fornesa','Albert','Ortega Fornesa','ESP','m',14,127),
('sebastian-holzmann','Sebastian','Holzmann','GER','m',14,127),
('jett-seymour','Jett','Seymour','USA','m',13,129),
('lenz-hachler','Lenz','Hächler','SUI','m',12,130),
('istok-rodes','Istok','Rodes','CRO','m',12,130),
('luke-winters','Luke','Winters','USA','m',12,130),
('yohei-koyama','Yohei','Koyama','JPN','m',12,130),
('jesper-pohjolainen','Jesper','Pohjolainen','FIN','m',12,130),
('raphael-lessard','Raphael','Lessard','CAN','m',11,135),
('tormis-laine','Tormis','Laine','EST','m',11,135),
('theodor-braekken','Theodor','Braekken','NOR','m',10,137),
('matteo-canins','Matteo','Canins','ITA','m',10,137),
('andreas-zampa','Andreas','Zampa','SVK','m',10,137),
('nicolo-molteni','Nicolo','Molteni','ITA','m',8,140),
('william-hansson','William','Hansson','SWE','m',8,140),
('manuel-traninger','Manuel','Traninger','AUT','m',7,142),
('aleix-aubert-serracanta','Aleix','Aubert Serracanta','ESP','m',7,142),
('fadri-janutin','Fadri','Janutin','SUI','m',7,142),
('marc-rochat','Marc','Rochat','SUI','m',7,142),
('jared-goldberg','Jared','Goldberg','USA','m',6,146),
('shiro-aihara','Shiro','Aihara','JPN','m',6,146),
('guerlain-favre','Guerlain','Favre','FRA','m',5,148),
('cooper-puckett','Cooper','Puckett','USA','m',5,148),
('max-perathoner','Max','Perathoner','ITA','m',5,148),
('nejc-naralocnik','Nejc','Naralocnik','SLO','m',4,151),
('juan-del-campo-hernandez','Juan','Del Campo Hernandez','ESP','m',4,151),
('bridger-gile','Bridger','Gile','USA','m',4,151),
('tommaso-saccardi','Tommaso','Saccardi','ITA','m',4,151),
('george-steffey','George','Steffey','USA','m',4,151),
('simon-talacci','Simon','Talacci','ITA','m',4,151),
('gustav-wissting','Gustav','Wissting','SWE','m',4,151),
('corrado-barbera','Corrado','Barbera','ITA','m',3,158),
('mikaela-shiffrin','Mikaela','Shiffrin','USA','w',1410,1),
('emma-aicher','Emma','Aicher','GER','w',1323,2),
('camille-rast','Camille','Rast','SUI','w',1049,3),
('sofia-goggia','Sofia','Goggia','ITA','w',982,4),
('alice-robinson','Alice','Robinson','NZL','w',815,5),
('paula-moltzan','Paula','Moltzan','USA','w',784,6),
('laura-pirovano','Laura','Pirovano','ITA','w',745,7),
('julia-scheib','Julia','Scheib','AUT','w',732,8),
('sara-hector','Sara','Hector','SWE','w',692,9),
('kira-weidle-winkelmann','Kira','Weidle-Winkelmann','GER','w',640,10),
('cornelia-hutter','Cornelia','Hütter','AUT','w',620,11),
('lindsey-vonn','Lindsey','Vonn','USA','w',590,12),
('wendy-holdener','Wendy','Holdener','SUI','w',580,13),
('kajsa-vickhoff-lie','Kajsa','Vickhoff Lie','NOR','w',577,14),
('lara-colturi','Lara','Colturi','ALB','w',535,15),
('breezy-johnson','Breezy','Johnson','USA','w',505,16),
('ester-ledecka','Ester','Ledecká','CZE','w',493,17),
('corinne-suter','Corinne','Suter','SUI','w',482,18),
('katharina-truppe','Katharina','Truppe','AUT','w',441,19),
('romane-miradoli','Romane','Miradoli','FRA','w',433,20),
('lena-durr','Lena','Dürr','GER','w',403,21),
('valerie-grenier','Valérie','Grenier','CAN','w',384,22),
('ariane-raedler','Ariane','Raedler','AUT','w',376,23),
('elena-curtoni','Elena','Curtoni','ITA','w',360,24),
('nina-ortlieb','Nina','Ortlieb','AUT','w',360,24),
('malorie-blanc','Malorie','Blanc','SUI','w',347,26),
('zrinka-ljutic','Zrinka','Ljutić','CRO','w',346,27),
('lara-della-mea','Lara','Della Mea','ITA','w',335,28),
('mirjam-puchner','Mirjam','Puchner','AUT','w',307,29),
('anna-swenn-larsson','Anna','Swenn Larsson','SWE','w',304,30),
('thea-louise-stjernesund','Thea Louise','Stjernesund','NOR','w',297,31),
('ilka-stuhec','Ilka','Štuhec','SLO','w',293,32),
('nicol-delago','Nicol','Delago','ITA','w',287,33),
('nina-o-brien','Nina','O''Brien','USA','w',252,34),
('jacqueline-wiles','Jacqueline','Wiles','USA','w',236,35),
('keely-cashman','Keely','Cashman','USA','w',219,36),
('mina-furst-holtmann','Mina','Fürst Holtmann','NOR','w',204,37),
('maryna-gasienica-daniel','Maryna','Gąsienica-Daniel','POL','w',191,38),
('asja-zenere','Asja','Zenere','ITA','w',189,39),
('katharina-liensberger','Katharina','Liensberger','AUT','w',189,39),
('marion-chevrier','Marion','Chevrier','FRA','w',187,41),
('laura-gauche','Laura','Gauche','FRA','w',186,42),
('cornelia-ohlund','Cornelia','Öhlund','SWE','w',185,43),
('roberta-melesi','Roberta','Melesi','ITA','w',174,44),
('dzenifera-germane','Dzenifera','Germane','LAT','w',172,45),
('stephanie-brunner','Stephanie','Brunner','AUT','w',167,46),
('britt-richardson','Britt','Richardson','CAN','w',163,47),
('camille-cerutti','Camille','Cerutti','FRA','w',158,48),
('magdalena-egger','Magdalena','Egger','AUT','w',152,49),
('hanna-aronsson-elfman','Hanna','Aronsson Elfman','SWE','w',144,50),
('aj-hurt','AJ','Hurt','USA','w',135,51),
('katharina-huber','Katharina','Huber','AUT','w',134,52),
('marte-monsen','Marte','Monsen','NOR','w',132,53),
('estelle-alphand','Estelle','Alphand','SWE','w',127,54),
('melanie-meillard','Melanie','Meillard','SUI','w',126,55),
('eliane-christen','Eliane','Christen','SUI','w',115,56),
('caitlin-mcfarlane','Caitlin','McFarlane','FRA','w',114,57),
('katharina-gallhuber','Katharina','Gallhuber','AUT','w',114,57),
('vanessa-kasper','Vanessa','Kasper','SUI','w',111,59),
('nadia-delago','Nadia','Delago','ITA','w',108,60),
('allison-mollin','Allison','Mollin','USA','w',104,61),
('federica-brignone','Federica','Brignone','ITA','w',101,62),
('laurence-st-germain','Laurence','St-Germain','CAN','w',91,63),
('janine-schmitt','Janine','Schmitt','SUI','w',89,64),
('nadine-fest','Nadine','Fest','AUT','w',89,64),
('ana-bucik-jogan','Ana','Bucik Jogan','SLO','w',86,66),
('nina-astner','Nina','Astner','AUT','w',85,67),
('mary-bocock','Mary','Bocock','USA','w',81,68),
('jasmine-flury','Jasmine','Flury','SUI','w',80,69),
('clara-direz','Clara','Direz','FRA','w',74,70),
('stefanie-grob','Stefanie','Grob','SUI','w',74,70),
('sue-piller','Sue','Piller','SUI','w',73,72),
('marie-lamure','Marie','Lamure','FRA','w',73,72),
('ricarda-haaser','Ricarda','Haaser','AUT','w',73,72),
('martina-peterlini','Martina','Peterlini','ITA','w',72,75),
('lisa-horhager','Lisa','Hörhager','AUT','w',72,75),
('anna-trocker','Anna','Trocker','ITA','w',61,77),
('jasmina-suter','Jasmina','Suter','SUI','w',61,77),
('franziska-gritsch','Franziska','Gritsch','AUT','w',61,77),
('lara-gut-behrami','Lara','Gut-Behrami','SUI','w',60,80),
('madeleine-sylvester-davik','Madeleine','Sylvester-Davik','NOR','w',60,80),
('natalie-falch','Natalie','Falch','AUT','w',56,82),
('elisabeth-bocock','Elisabeth','Bocock','USA','w',53,83),
('isabella-wright','Isabella','Wright','USA','w',53,83),
('joana-hahlen','Joana','Hählen','SUI','w',50,85),
('asa-ando','Asa','Ando','JPN','w',49,86),
('hilma-lovblom','Hilma','Lövblom','SWE','w',45,87),
('tricia-mangan','Tricia','Mangan','USA','w',43,88),
('neja-dvornik','Neja','Dvornik','SLO','w',41,89),
('haley-cutler','Haley','Cutler','USA','w',41,89),
('ilaria-ghisalberti','Ilaria','Ghisalberti','ITA','w',38,91),
('cassidy-gray','Cassidy','Gray','CAN','w',37,92),
('delia-durrer','Delia','Durrer','SUI','w',36,93),
('martina-dubovska','Martina','Dubovská','CZE','w',34,94),
('emilia-mondinelli','Emilia','Mondinelli','ITA','w',33,95),
('anuk-brandli','Anuk','Brändli','SUI','w',32,96),
('bianca-bakke-westhoff','Bianca Bakke','Westhoff','NOR','w',31,97),
('doriane-escane','Doriane','Escane','FRA','w',29,98),
('fabiana-dorigo','Fabiana','Dorigo','GER','w',28,99),
('amelia-smart','Amelia','Smart','CAN','w',25,100),
('aline-hopli','Aline','Höpli','SUI','w',24,101),
('katie-hensien','Katie','Hensien','USA','w',22,102),
('priska-ming-nufer','Priska','Ming-Nufer','SUI','w',22,102),
('aline-danioth','Aline','Danioth','SUI','w',21,104),
('erika-pykalainen','Erika','Pykäläinen','FIN','w',21,104),
('sara-allemand','Sara','Allemand','ITA','w',21,104),
('liv-moritz','Liv','Moritz','USA','w',20,107),
('dania-allenbach','Dania','Allenbach','SUI','w',20,107),
('sophie-nyberg','Sophie','Nyberg','SWE','w',18,109),
('giulia-valleriani','Giulia','Valleriani','ITA','w',18,109),
('sara-thaler','Sara','Thaler','ITA','w',18,109),
('lena-wechner','Lena','Wechner','AUT','w',16,112),
('elvedina-muzaferija','Elvedina','Muzaferija','BIH','w',16,112),
('carla-mijares-ruf','Carla','Mijares Ruf','AND','w',13,114),
('alice-pazzaglia','Alice','Pazzaglia','ITA','w',12,115),
('christina-ager','Christina','Ager','AUT','w',11,116),
('nicole-good','Nicole','Good','SUI','w',10,117),
('ali-nullmeyer','Ali','Nullmeyer','CAN','w',10,117),
('justine-lamontagne','Justine','Lamontagne','CAN','w',10,117),
('victoria-olivier','Victoria','Olivier','AUT','w',9,120),
('jessica-hilzinger','Jessica','Hilzinger','GER','w',9,120),
('chisaki-maeda','Chisaki','Maeda','JPN','w',9,120),
('leona-popovic','Leona','Popovic','CRO','w',9,120),
('jasmin-mathis','Jasmin','Mathis','SUI','w',8,124),
('giorgia-collomb','Giorgia','Collomb','ITA','w',8,124),
('nika-tomsic','Nika','Tomsic','SLO','w',8,124),
('cande-moreno','Cande','Moreno','AND','w',8,124),
('garance-meyer','Garance','Meyer','FRA','w',7,128),
('jana-fritz','Jana','Fritz','GER','w',7,128),
('simone-wild','Simone','Wild','SUI','w',7,128),
('emily-schopf','Emily','Schöpf','AUT','w',6,131),
('viktoria-burgler','Viktoria','Bürgler','AUT','w',6,131),
('moa-landstrom','Moa','Landström','SWE','w',6,131),
('zita-toth','Zita','Toth','HUN','w',6,131),
('beatrice-sola','Beatrice','Sola','ITA','w',5,135),
('inni-holm-wembstad','Inni Holm','Wembstad','NOR','w',4,136),
('rosa-pohjolainen','Rosa','Pohjolainen','FIN','w',3,137),
('carmen-spielberger','Carmen','Spielberger','AUT','w',3,137),
('noa-szollos','Noa','Szollos','ISR','w',3,137),
('leonie-raich','Leonie','Raich','AUT','w',2,140),
('lisa-grill','Lisa','Grill','AUT','w',1,141),
('leonie-zegg','Leonie','Zegg','AUT','w',1,141),
('cyprien-sarrazin','Cyprien','Sarrazin','FRA','m',0,null),
('michelle-gisin','Michelle','Gisin','SUI','w',0,null),
('marta-bassino','Marta','Bassino','ITA','w',0,null),
('petra-vlhova','Petra','Vlhová','SVK','w',0,null),
('stephanie-venier','Stephanie','Venier','AUT','w',0,null),
('lauren-macuga','Lauren','Macuga','USA','w',0,null),
('freddy-carrick-smith','Freddy','Carrick-Smith','GBR','m',0,null),
('gino-caviezel','Gino','Caviezel','SUI','m',0,null),
('alexander-steen-olsen','Alexander','Steen Olsen','NOR','m',0,null)
on conflict (id) do nothing;


-- ---------- Admin anlegen (nur beim ersten Mal) ----------
insert into players (name, is_admin)
select 'Stefan', true where not exists (select 1 from players where is_admin);

-- ---------- Zeitsteuerung: alle 5 Minuten ----------
do $$ begin
  begin perform cron.unschedule('skifantasy-tick'); exception when others then null; end;
  perform cron.schedule('skifantasy-tick', '*/5 * * * *', 'select public.tick()');
exception when others then raise notice 'cron: %', sqlerrm;
end $$;

-- erste Resultate gleich anstossen
do $$ begin perform ingest_poll(); exception when others then raise notice 'ingest: %', sqlerrm; end $$;

-- ---------- Deine Links ----------
select 'Dein Admin-Link' as was, 'https://stoepps.github.io/fantaski/?p=' || token as link from players where is_admin
union all
select 'Einladungslink für die Gruppe', 'https://stoepps.github.io/fantaski/?join=' || invite_code from settings where id = 1;
