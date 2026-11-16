// Wochenbericht für die News-Jobs.  Aufruf:
//   bash tools/fetch.sh /tmp/sfdata && node tools/report.mjs /tmp/sfdata [--final]
// --final: laufende Woche als abgeschlossen werten (Sonntagabend-Auswertung).
import fs from 'fs'; import path from 'path'; import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const S = require(path.join(path.dirname(new URL(import.meta.url).pathname), '..', 'stats.js'));
const dir = process.argv[2] || '/tmp/sfdata'; const final = process.argv.includes('--final');
const L = n => JSON.parse(fs.readFileSync(path.join(dir, n + '.json'), 'utf8'));
const D = { races: L('v_races'), results: L('v_results'), own: L('v_ownership'), prp: L('v_player_race_pts'), players: L('v_players'), transfers: L('v_transfers') };
const A = {}; L('v_athletes').forEach(a => A[a.id] = a);
const nm = id => { const p = D.players.find(p => p.id === id); return p ? p.name + (p.team_name ? ` («${p.team_name}»)` : '') : '?'; };
const an = id => A[id] ? `${A[id].first} ${A[id].last} (${A[id].nat})` : id;
const today = S.zDate(Date.now()); const cur = S.weekStart(today);
const B = S.build(D, { final: final ? cur : null });
const fmtW = w => w && {
  woche: `${w.start} bis ${w.end}`, abgeschlossen: w.complete, provisorisch_enthalten: w.provisional,
  rennen: w.races.map(r => `${r.date} ${r.place} ${r.disc} ${r.g === 'm' ? 'Männer' : 'Frauen'}${r.provisional ? ' (provisorisch*)' : ''}`),
  wochenrangliste: B.ids.slice().sort((a, b) => w.pts[b] - w.pts[a]).map(id => ({ rang: w.wRank[id], spieler: nm(id), punkte: w.pts[id] })),
  gesamt: B.ids.slice().sort((a, b) => w.rankAfter[a] - w.rankAfter[b]).map(id => ({ rang: w.rankAfter[id], vorher: w.rankBefore ? w.rankBefore[id] : null, spieler: nm(id), total: w.after[id] })),
  auszeichnungen: w.awards.map(a => ({ preis: S.AW[a.k][0] + ' ' + S.AW[a.k][1], spieler: nm(a.pid), wert: a.val, athlet: a.aid ? an(a.aid) : undefined }))
};
const w = B.weeks.find(x => x.start === cur) || null;
const out = {
  heute: today, diese_woche: fmtW(w), letzte_abgeschlossene_woche: fmtW(B.weeks.filter(x => x.complete && x.start !== cur).slice(-1)[0]),
  kugeln: { speed: { leader: B.speedLead.ids.map(nm), punkte: B.speedLead.v }, technik: { leader: B.techLead.ids.map(nm), punkte: B.techLead.v } },
  medaillenspiegel: B.ids.map(id => ({ spieler: nm(id), ...Object.fromEntries(S.WEEK_AWARDS.map(k => [S.AW[k][0], B.medals[id][k]])) })),
  provisorische_rennen: D.races.filter(r => r.provisional).map(r => r.id)
};
console.log(JSON.stringify(out, null, 1));
