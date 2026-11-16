/* Ski-Fantasy · Auswertungen (Wochen, Auszeichnungen, Kugeln, Verlauf, Form).
   Läuft im Browser (window.SFStats) und in Node (require/import), damit App und
   Wochen-News dieselben Regeln verwenden. */
(function (root) {
'use strict';
const TZ = 'Europe/Zurich';
const SPEED = ['Abfahrt', 'Super-G'];
const TECH = ['Riesenslalom', 'Slalom'];
const AW = {
  win: ['🏆', 'Wochensieger', 'Meiste Punkte der Woche'],
  lantern: ['🐌', 'Rote Laterne', 'Wenigste Punkte der Woche'],
  riser: ['🚀', 'Aufsteiger der Woche', 'Meiste Ränge in der Gesamtwertung gutgemacht'],
  transfer: ['🎯', 'Transfer der Woche', 'Neuzugang mit den meisten Punkten in seiner ersten Woche'],
  flop: ['🤡', 'Fehlgriff der Woche', 'Abgegebener Athlet, der danach am meisten Punkte holt'],
  streak: ['🔥', 'Serie', 'Drei Wochen oder mehr in Folge in den Top 3 der Wochenwertung'],
  speed: ['⛷️', 'Speed-Kugel', 'Meiste Punkte aus Abfahrt und Super-G'],
  tech: ['🌀', 'Technik-Kugel', 'Meiste Punkte aus Riesenslalom und Slalom']
};
const WEEK_AWARDS = ['win', 'riser', 'transfer', 'streak', 'flop', 'lantern'];

const day = d => String(d || '').slice(0, 10);
const zDate = ts => new Intl.DateTimeFormat('en-CA', { timeZone: TZ }).format(new Date(ts));
function weekStart(d) { const t = new Date(day(d) + 'T12:00:00Z'); t.setUTCDate(t.getUTCDate() - (t.getUTCDay() + 6) % 7); return t.toISOString().slice(0, 10); }
function addDays(d, n) { const t = new Date(day(d) + 'T12:00:00Z'); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); }
/* Punkte gehören dem, dem der Athlet am Ende des Renntags gehört (Transfer Mo 12:00 zählt für ein Rennen am Montagabend). */
const dayEnd = d => new Date(day(d) + 'T23:59:59+01:00').getTime();
function ownerAt(own, aid, date) {
  const t = dayEnd(date);
  const o = own.find(o => o.athlete_id === aid && new Date(o.from_ts).getTime() <= t && (!o.to_ts || new Date(o.to_ts).getTime() > t));
  return o ? o.player_id : null;
}
function best(map, ids, dir) {
  let v = null; ids.forEach(id => { const x = map[id] || 0; if (v === null || (dir > 0 ? x > v : x < v)) v = x; });
  return { v, ids: ids.filter(id => (map[id] || 0) === v) };
}
function ranks(map, ids, tieKey) {
  const s = ids.slice().sort((a, b) => (map[b] || 0) - (map[a] || 0) || (tieKey ? tieKey(a) - tieKey(b) : 0));
  const r = {}; s.forEach((id, i) => { r[id] = i > 0 && (map[id] || 0) === (map[s[i - 1]] || 0) ? r[s[i - 1]] : i + 1; });
  return r;
}

/* D = { races, results, own, prp, players, transfers }  (Rohdaten der Views) */
function build(D, opts) {
  opts = opts || {};
  const today = opts.today || zDate(Date.now());
  const ids = D.players.map(p => p.id);
  const dpos = id => { const p = D.players.find(x => x.id === id); return (p && p.draft_pos) || 99; };
  const hasRes = new Set(D.results.map(r => r.race_id));
  const races = D.races.filter(r => r.counts && hasRes.has(r.id)).map(r => Object.assign({}, r, { date: day(r.date) }))
    .sort((a, b) => a.date.localeCompare(b.date) || a.id.localeCompare(b.id));
  const P = {}; D.prp.forEach(x => { (P[x.race_id] = P[x.race_id] || {})[x.player_id] = x.pts; });
  const rByRace = {}; D.results.forEach(r => { (rByRace[r.race_id] = rByRace[r.race_id] || []).push(r); });

  // Verlauf (kumuliert pro Rennen)
  const run = {}; ids.forEach(id => run[id] = 0);
  const cum = races.map(r => { ids.forEach(id => run[id] += (P[r.id] || {})[id] || 0); return { race: r, tot: Object.assign({}, run) }; });

  // Wochen
  const wkMap = {}; races.forEach(r => { const w = weekStart(r.date); (wkMap[w] = wkMap[w] || []).push(r); });
  const total = {}; ids.forEach(id => total[id] = 0);
  const weeks = []; let prevRank = null; const topHist = {}; ids.forEach(id => topHist[id] = 0);
  Object.keys(wkMap).sort().forEach((ws, wi) => {
    const wr = wkMap[ws]; const end = addDays(ws, 6);
    const before = Object.assign({}, total);
    const pts = {}; ids.forEach(id => pts[id] = 0);
    wr.forEach(r => ids.forEach(id => pts[id] += (P[r.id] || {})[id] || 0));
    ids.forEach(id => total[id] += pts[id]);
    const after = Object.assign({}, total);
    const rankAfter = ranks(after, ids, dpos); const rankBefore = prevRank;
    const wRank = ranks(pts, ids);
    const complete = opts.final === ws || today > end;
    const aw = [];
    const sum = ids.reduce((s, id) => s + pts[id], 0);
    if (sum > 0) {
      const w = best(pts, ids, 1); w.ids.forEach(id => aw.push({ k: 'win', pid: id, val: w.v }));
      const l = best(pts, ids, -1); if (l.ids.length < ids.length) l.ids.forEach(id => aw.push({ k: 'lantern', pid: id, val: l.v }));
    }
    if (rankBefore) {
      const gain = {}; ids.forEach(id => gain[id] = (rankBefore[id] || ids.length) - rankAfter[id]);
      const g = best(gain, ids, 1); if (g.v > 0) g.ids.forEach(id => aw.push({ k: 'riser', pid: id, val: g.v, from: rankBefore[id], to: rankAfter[id] }));
    }
    const wTr = (D.transfers || []).filter(t => weekStart(zDate(t.run_at)) === ws);
    if (wTr.length) {
      const inP = wTr.map(t => ({ t, v: wr.reduce((s, r) => s + (rByRace[r.id] || []).filter(x => x.athlete_id === t.in_id && ownerAt(D.own, t.in_id, r.date) === t.player_id).reduce((a, x) => a + x.pts, 0), 0) }));
      const mi = Math.max(...inP.map(x => x.v)); if (mi > 0) inP.filter(x => x.v === mi).forEach(x => aw.push({ k: 'transfer', pid: x.t.player_id, val: mi, aid: x.t.in_id }));
      const outP = wTr.map(t => ({ t, v: wr.reduce((s, r) => s + (rByRace[r.id] || []).filter(x => x.athlete_id === t.out_id).reduce((a, x) => a + x.pts, 0), 0) }));
      const mo = Math.max(...outP.map(x => x.v)); if (mo > 0) outP.filter(x => x.v === mo).forEach(x => aw.push({ k: 'flop', pid: x.t.player_id, val: mo, aid: x.t.out_id, owner: ownerNowAt(D.own, x.t.out_id, end) }));
    }
    ids.forEach(id => { topHist[id] = (sum > 0 && wRank[id] <= 3) ? topHist[id] + 1 : 0; if (topHist[id] >= 3) aw.push({ k: 'streak', pid: id, val: topHist[id] }); });
    aw.sort((a, b) => WEEK_AWARDS.indexOf(a.k) - WEEK_AWARDS.indexOf(b.k));
    weeks.push({ start: ws, end, races: wr, pts, wRank, before, after, rankBefore, rankAfter, complete, provisional: wr.some(r => r.provisional), awards: aw, n: wi + 1 });
    prevRank = rankAfter;
  });

  // Kugeln
  const speed = {}, tech = {}; ids.forEach(id => { speed[id] = 0; tech[id] = 0; });
  races.forEach(r => { const t = SPEED.includes(r.disc) ? speed : TECH.includes(r.disc) ? tech : null; if (t) ids.forEach(id => t[id] += (P[r.id] || {})[id] || 0); });
  const lead = m => { const b = best(m, ids, 1); return b.v > 0 ? b : { v: 0, ids: [] }; };

  // Medaillenspiegel (nur abgeschlossene Wochen)
  const medals = {}; ids.forEach(id => { medals[id] = {}; WEEK_AWARDS.forEach(k => medals[id][k] = 0); });
  weeks.filter(w => w.complete).forEach(w => w.awards.forEach(a => medals[a.pid][a.k]++));

  return { races, cum, weeks, speed, tech, speedLead: lead(speed), techLead: lead(tech), medals, ids, today };
}
function ownerNowAt(own, aid, date) { return ownerAt(own, aid, date); }

/* Form: Punkte aus den letzten n zählenden Rennen des Geschlechts */
function formMap(D, n) {
  n = n || 3; const hasRes = new Set(D.results.map(r => r.race_id)); const out = {};
  ['m', 'w'].forEach(g => {
    const last = D.races.filter(r => r.counts && r.g === g && hasRes.has(r.id)).sort((a, b) => day(b.date).localeCompare(day(a.date))).slice(0, n).map(r => r.id);
    D.results.filter(x => last.includes(x.race_id)).forEach(x => out[x.athlete_id] = (out[x.athlete_id] || 0) + x.pts);
  });
  return out;
}

/* Besitz-Historie eines Athleten mit Punkten pro Besitzer */
function history(D, aid) {
  const rc = D.races.filter(r => r.counts);
  return D.own.filter(o => o.athlete_id === aid).sort((a, b) => new Date(a.from_ts) - new Date(b.from_ts)).map(o => {
    const f = new Date(o.from_ts).getTime(), t = o.to_ts ? new Date(o.to_ts).getTime() : Infinity;
    const pts = D.results.filter(x => x.athlete_id === aid).reduce((s, x) => { const r = rc.find(r => r.id === x.race_id); if (!r) return s; const e = dayEnd(r.date); return e >= f && e < t ? s + x.pts : s; }, 0);
    return { player_id: o.player_id, from: o.from_ts, to: o.to_ts, how: o.how, pts };
  });
}

const api = { AW, WEEK_AWARDS, SPEED, TECH, build, formMap, history, weekStart, addDays, ownerAt, zDate };
if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.SFStats = api;
})(typeof window !== 'undefined' ? window : globalThis);
