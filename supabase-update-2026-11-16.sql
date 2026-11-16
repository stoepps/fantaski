-- =====================================================================
-- Ski-Fantasy · Update 16.11.2026
-- Provisorische Resultate (*), Teamnamen. Einmal im SQL Editor ausführen.
-- Kann gefahrlos mehrfach ausgeführt werden.
-- =====================================================================

-- ---------- Provisorische Resultate ----------
alter table races add column if not exists provisional boolean not null default false;

create or replace view v_races as
  select r.id, r.date, r.place, r.disc, r.g, r.source,
         (r.date >= (select season_start from settings where id = 1)) as counts,
         r.provisional
  from races r;

create or replace function ingest_json(j jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare rc jsonb; x jsonb; aid text; k text; rg text; n int := 0; nid text;
begin
  for rc in select * from jsonb_array_elements(coalesce(j->'races', '[]'::jsonb)) loop
    rg := rc->>'g';
    continue when rc->>'id' is null or rg not in ('m','w') or rc->>'date' is null;
    insert into races (id, date, place, disc, g, source, imported_at, provisional)
      values (rc->>'id', (rc->>'date')::date, coalesce(rc->>'place',''), coalesce(rc->>'disc',''), rg, rc->>'source', now(),
              coalesce((rc->>'provisional')::boolean, false))
      on conflict (id) do update set date = excluded.date, place = excluded.place, disc = excluded.disc,
        g = excluded.g, source = excluded.source, provisional = excluded.provisional;
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
revoke execute on function ingest_json(jsonb) from public;
do $$ begin revoke execute on function ingest_json(jsonb) from anon, authenticated;
exception when undefined_object then null; end $$;

-- ---------- Punkte gehören dem Besitzer am Ende des Renntags ----------
-- (Transfer Mo 12:00 zählt bereits für ein Rennen am Montagabend, z.B. Schladming)
create or replace view v_player_race_pts as
  select o.player_id, rr.race_id, sum(rr.pts)::int as pts
  from race_results rr
  join races r on r.id = rr.race_id
  join ownership o on o.athlete_id = rr.athlete_id
    and o.from_ts <= (((r.date + 1)::timestamp at time zone 'Europe/Zurich') - interval '1 second')
    and (o.to_ts is null or o.to_ts > (((r.date + 1)::timestamp at time zone 'Europe/Zurich') - interval '1 second'))
  where r.date >= (select season_start from settings where id = 1)
  group by o.player_id, rr.race_id;

create or replace view v_owned_pts as
  select o.player_id, rr.athlete_id, sum(rr.pts)::int as pts
  from race_results rr
  join races r on r.id = rr.race_id
  join ownership o on o.athlete_id = rr.athlete_id
    and o.from_ts <= (((r.date + 1)::timestamp at time zone 'Europe/Zurich') - interval '1 second')
    and (o.to_ts is null or o.to_ts > (((r.date + 1)::timestamp at time zone 'Europe/Zurich') - interval '1 second'))
  where r.date >= (select season_start from settings where id = 1)
  group by o.player_id, rr.athlete_id;

-- ---------- Teamnamen ----------
alter table players add column if not exists team_name text;

create or replace view v_players as
  select id, name, draft_pos, joined_at, team_name from players where active;

create or replace view v_standings as
  select p.id as player_id, p.name, p.draft_pos,
         coalesce((select sum(x.pts) from v_player_race_pts x where x.player_id = p.id), 0)::int as total,
         p.team_name
  from players p where p.active;

create or replace function me(p_token text) returns json
language plpgsql security definer set search_path = public as $$
declare p players; s settings;
begin
  select * into p from players where token = p_token and active;
  if p.id is null then return null; end if;
  select * into s from settings where id = 1;
  return json_build_object(
    'id', p.id, 'name', p.name, 'is_admin', p.is_admin, 'draft_pos', p.draft_pos, 'team_name', p.team_name,
    'draft_wish', json_build_object(
      'm', coalesce((select list from draft_wish where player_id = p.id and g = 'm'), '{}'),
      'w', coalesce((select list from draft_wish where player_id = p.id and g = 'w'), '{}')),
    'transfer_wish', (select json_build_object('wants', wants, 'drops_m', drops_m, 'drops_w', drops_w)
                      from transfer_wish where player_id = p.id),
    'invite_code', case when p.is_admin then s.invite_code end
  );
end $$;

create or replace function set_team_name(p_token text, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare p players := player_by_token(p_token); n text := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g'));
begin
  if length(n) > 24 then raise exception 'Der Teamname darf höchstens 24 Zeichen lang sein.'; end if;
  update players set team_name = nullif(n, '') where id = p.id;
  return nullif(n, '');
end $$;

create or replace function admin_set_team_name(p_token text, p_id int, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare a players := admin_check(p_token); n text := btrim(regexp_replace(coalesce(p_name,''), '\s+', ' ', 'g'));
begin
  if length(n) > 24 then raise exception 'Der Teamname darf höchstens 24 Zeichen lang sein.'; end if;
  update players set team_name = nullif(n, '') where id = p_id and active;
end $$;

revoke execute on function set_team_name(text,text), admin_set_team_name(text,int,text) from public;
grant execute on function set_team_name(text,text), admin_set_team_name(text,int,text), me(text) to anon, authenticated;
grant select on v_races, v_players, v_standings to anon, authenticated;

select 'Update 16.11. ok' as status,
  (select count(*) from races) as rennen,
  (select count(*) from players where active) as spieler;
