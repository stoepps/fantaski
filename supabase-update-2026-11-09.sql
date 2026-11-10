-- =====================================================================
-- Ski-Fantasy · Update 9.11.2026
-- Rücktritte und Verletzte markieren, Draft überspringt sie,
-- neue Athleten, Admin-Name. Einmal im SQL Editor ausführen.
-- =====================================================================

alter table athletes add column if not exists status text check (status in ('retired','out','doubt'));
alter table athletes add column if not exists status_note text;

update athletes set status = null, status_note = null;
update athletes a set status = v.s, status_note = v.n from (values
  ('lara-gut-behrami', 'retired', 'Rücktritt (Okt. 2026)'),
  ('michelle-gisin', 'retired', 'Rücktritt (Nov. 2026)'),
  ('ilka-stuhec', 'retired', 'Rücktritt (Apr. 2026)'),
  ('mirjam-puchner', 'retired', 'Rücktritt (Juni 2026)'),
  ('ana-bucik-jogan', 'retired', 'Rücktritt 2026'),
  ('christina-ager', 'retired', 'Rücktritt 2026'),
  ('joana-hahlen', 'retired', 'Rücktritt 2026'),
  ('clara-direz', 'retired', 'Rücktritt 2026'),
  ('asa-ando', 'retired', 'Rücktritt 2026 (laut FIS)'),
  ('alexis-pinturault', 'retired', 'Rücktritt (März 2026)'),
  ('adrien-theaux', 'retired', 'Rücktritt 2026'),
  ('dave-ryding', 'retired', 'Rücktritt (Feb. 2026)'),
  ('niels-hintermann', 'retired', 'Rücktritt 2026'),
  ('romed-baumann', 'retired', 'Rücktritt (März 2026)'),
  ('marc-rochat', 'retired', 'Rücktritt 2026'),
  ('jared-goldberg', 'retired', 'Rücktritt (Apr. 2026)'),
  ('riley-seger', 'retired', 'Rücktritt 2026'),
  ('sebastian-holzmann', 'retired', 'Rücktritt 2026 (laut FIS)'),
  ('wiley-maple', 'retired', 'Rücktritt – letztes Rennen 4.12. Beaver Creek'),
  ('aleksander-aamodt-kilde', 'out', 'Saison-Aus: Achillessehnenriss'),
  ('lindsey-vonn', 'out', 'Saison-Aus: Comeback frühestens 2027/28'),
  ('camille-cerutti', 'out', 'Saison-Aus: Kreuzbandriss (Sept. 2026)'),
  ('valerie-grenier', 'out', 'Saison-Aus: Kreuzbandriss (Okt. 2026)'),
  ('federica-brignone', 'doubt', 'Verletzt – Comeback frühestens Mitte Dez.'),
  ('sofia-goggia', 'doubt', 'Krank – Rückkehr offen'),
  ('kajsa-vickhoff-lie', 'doubt', 'Knorpel-OP im Sommer – Rückkehr offen'),
  ('cyprien-sarrazin', 'doubt', 'Comeback nach Sturz – Termin offen'),
  ('lauren-macuga', 'doubt', 'Kreuzbandriss – Comeback geplant Anfang Dez.')
) as v(id, s, n) where a.id = v.id;

-- neue bzw. zurückkehrende Athleten (0 Punkte letzte Saison, daher zuunterst)
insert into athletes (id, first, last, nat, g, prev) values
  ('marcel-hirscher', 'Marcel', 'Hirscher', 'NED', 'm', 0),
  ('ken-caillot', 'Ken', 'Caillot', 'FRA', 'm', 0)
on conflict (id) do nothing;
update athletes set status = 'doubt', status_note = 'Comeback – Termin offen' where id = 'marcel-hirscher';
update athletes set status_note = 'Europacup-Abfahrtssieger 25/26' where id = 'ken-caillot';

create or replace view v_athletes as
  select id, first, last, nat, g, prev, prev_rank, status, status_note from athletes;
grant select on v_athletes to anon, authenticated;

-- Zurückgetretene und Saison-Aus aus allen Draft-Wunschlisten entfernen
update draft_wish w set list = coalesce((select array_agg(x order by o) from unnest(w.list) with ordinality u(x, o)
  where not exists (select 1 from athletes where id = u.x and status in ('retired','out'))), '{}');

-- Draft: Wunschliste überspringt Rücktritte/Saison-Aus; Auto-Pick nimmt nur Gesunde
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
            and exists (select 1 from athletes where id = u.a and athletes.g = v_g
                        and coalesce(athletes.status, '') not in ('retired', 'out'))
            and not exists (select 1 from ownership where athlete_id = u.a and to_ts is null)
          order by u.o limit 1;
        if pick is null then
          isauto := true;
          select id into pick from athletes a
            where a.g = v_g and a.status is null and not exists (select 1 from ownership where athlete_id = a.id and to_ts is null)
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

revoke execute on function do_draft() from public;
do $$ begin revoke execute on function do_draft() from anon, authenticated; exception when undefined_object then null; end $$;

-- Admin-Name
update players set name = 'Stoeppso Tomba' where is_admin;

select coalesce(status, 'aktiv') as status, count(*) from athletes group by 1 order by 1;
