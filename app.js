/* Ski-Fantasy · App */
(function () {
'use strict';
const SB = window.SF_SB || 'https://iapkocqgclfjcxrlkghw.supabase.co';
const KEY = 'sb_publishable_bCwTOeE2vb4kQtRtag4rUQ_jIKtESZb';
const BASE = location.origin + location.pathname;
const TZ = 'Europe/Zurich';

/* ---------------- helpers ---------------- */
const $ = s => document.querySelector(s);
const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const norm = s => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
const fmtN = n => String(n || 0).replace(/\B(?=(\d{3})+(?!\d))/g, "'");
function store(k, v) { try { if (v === undefined) return localStorage.getItem(k); if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v); } catch (e) { return null; } }
function toast(t) { const el = $('#toast'); el.textContent = t; el.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => el.hidden = true, 2600); }
const dtf = new Intl.DateTimeFormat('de-CH', { timeZone: TZ, weekday: 'short', day: 'numeric', month: 'numeric', hour: '2-digit', minute: '2-digit' });
const df = new Intl.DateTimeFormat('de-CH', { timeZone: TZ, weekday: 'short', day: 'numeric', month: 'numeric' });
const fmtDT = d => d ? dtf.format(new Date(d)).replace(',', ',') : '';
const day = d => String(d || '').slice(0, 10);
const fmtD = d => d ? df.format(new Date(day(d) + 'T12:00:00Z')) : '';
function zParts(d) {
  const p = {}; new Intl.DateTimeFormat('en-GB', { timeZone: TZ, weekday: 'short', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hour12: false }).formatToParts(d).forEach(x => p[x.type] = x.value);
  return p;
}
function nextTransferRun() {
  const now = Date.now();
  for (let h = 0; h < 8 * 24 + 2; h++) {
    const d = new Date(Math.ceil(now / 3600e3) * 3600e3 + h * 3600e3);
    const p = zParts(d);
    if (p.weekday === 'Mon' && +p.hour === 12) return d;
  }
  return null;
}
const raceStart = date => new Date(String(date).slice(0, 10) + 'T00:00:00+01:00').getTime();

async function api(path) {
  const r = await fetch(SB + '/rest/v1/' + path, { headers: { apikey: KEY } });
  if (!r.ok) throw new Error('Daten konnten nicht geladen werden (' + r.status + ')');
  return r.json();
}
async function rpc(fn, args) {
  const r = await fetch(SB + '/rest/v1/rpc/' + fn, { method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(args || {}) });
  const txt = await r.text(); let j = null; try { j = txt ? JSON.parse(txt) : null; } catch (e) { }
  if (!r.ok) throw new Error((j && j.message) || 'Fehler ' + r.status);
  return j;
}

/* ---------------- state ---------------- */
const S = {
  token: null, me: null, tab: 'tabelle', loaded: false, err: null,
  set: {}, players: [], A: {}, races: [], results: [], own: [], prp: [], owned: [], standings: [], picks: [], transfers: [], admin: null,
  ui: { tab: 'tabelle', dg: 'm', dq: '', tg: 'm', tq: '', open: null, race: null, confirm: null }
};
const params = new URLSearchParams(location.search);
const joinCode = params.get('join');
S.token = params.get('p') || store('sf_token');
if (S.token && !params.get('p') && !joinCode) history.replaceState(null, '', BASE + '?p=' + encodeURIComponent(S.token));
if (params.get('p')) store('sf_token', params.get('p'));
try { const t = sessionStorage.getItem('sf_tab'); if (t) S.ui.tab = t; } catch (e) { }

async function load() {
  try {
    const [set, players, ath, races, results, own, prp, owned, standings, picks, transfers] = await Promise.all([
      api('v_settings?select=*'), api('v_players?select=*'), api('v_athletes?select=*'), api('v_races?select=*&order=date.desc'),
      api('v_results?select=*'), api('v_ownership?select=*'), api('v_player_race_pts?select=*'), api('v_owned_pts?select=*'),
      api('v_standings?select=*'), api('v_draft_picks?select=*&order=n'), api('v_transfers?select=*&order=id.desc')]);
    S.set = set[0] || {}; S.players = players; S.A = {}; ath.forEach(a => S.A[a.id] = a);
    races.forEach(r => r.date = String(r.date).slice(0, 10)); if (S.set.season_start) S.set.season_start = String(S.set.season_start).slice(0, 10);
    S.races = races; S.results = results; S.own = own; S.prp = prp; S.owned = owned; S.standings = standings; S.picks = picks; S.transfers = transfers;
    if (S.token) {
      S.me = await rpc('me', { p_token: S.token });
      if (!S.me) { store('sf_token', null); S.token = null; }
      else if (S.me.is_admin) S.admin = await rpc('admin_state', { p_token: S.token });
    }
    S.err = null; S.loaded = true;
  } catch (e) { S.err = e.message; S.loaded = true; }
  render();
}
document.addEventListener('visibilitychange', () => { if (!document.hidden && S.loaded) load(); });

/* ---------------- derived ---------------- */
const pName = id => { const p = S.players.find(x => x.id === id); return p ? p.name : '?'; };
const A = id => S.A[id] || { first: '', last: id, nat: '', g: 'm', prev: 0 };
const aHtml = (id, opts) => { const a = A(id); return `<span class="name">${esc(a.first)} <b>${esc(a.last)}</b>${opts === 'nonat' ? '' : `<span class="nat">${esc(a.nat)}</span>`}</span>`; };
const phase = () => S.set.draft_done ? 'season' : S.set.order_drawn ? 'drawn' : (Date.now() > new Date(S.set.reg_deadline).getTime() ? 'closed' : 'reg');
const currentRoster = pid => S.own.filter(o => o.player_id === pid && !o.to_ts).map(o => o.athlete_id);
const ownerNow = aid => { const o = S.own.find(o => o.athlete_id === aid && !o.to_ts); return o ? o.player_id : null; };
function ownerAt(aid, date) { const t = raceStart(date); const o = S.own.find(o => o.athlete_id === aid && new Date(o.from_ts).getTime() <= t && (!o.to_ts || new Date(o.to_ts).getTime() > t)); return o ? o.player_id : null; }
const ownedPts = (pid, aid) => { const x = S.owned.find(o => o.player_id === pid && o.athlete_id === aid); return x ? x.pts : 0; };
const seasonPts = aid => S.results.filter(r => { const rc = S.races.find(x => x.id === r.race_id); return rc && rc.counts && r.athlete_id === aid; }).reduce((s, r) => s + r.pts, 0);
function lastDelta() {
  const counted = S.races.filter(r => r.counts && S.results.some(x => x.race_id === r.id));
  if (!counted.length) return { date: null, d: {} };
  const date = counted[0].date; const ids = counted.filter(r => r.date === date).map(r => r.id);
  const d = {}; S.prp.filter(x => ids.includes(x.race_id)).forEach(x => d[x.player_id] = (d[x.player_id] || 0) + x.pts);
  return { date, d };
}
const sortedStandings = () => S.standings.slice().sort((a, b) => b.total - a.total || (a.draft_pos || 99) - (b.draft_pos || 99));
const transferOrder = () => S.standings.slice().sort((a, b) => a.total - b.total || (b.draft_pos || 0) - (a.draft_pos || 0)).map(x => x.player_id);

/* ---------------- icons ---------------- */
const I = {
  tabelle: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0zM17 5h3v2a3 3 0 0 1-3 3M7 5H4v2a3 3 0 0 0 3 3"/></svg>',
  draft: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M12 3l2.6 5.6 6 .7-4.5 4.1 1.2 6L12 16.5 6.7 19.4l1.2-6L3.4 9.3l6-.7z"/></svg>',
  kader: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6.5 6.5 0 0 1 3.5 6"/></svg>',
  rennen: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M3 20l6-12 4 6 3-4 5 10z"/></svg>',
  admin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/></svg>',
  star: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M12 3l2.6 5.6 6 .7-4.5 4.1 1.2 6L12 16.5 6.7 19.4l1.2-6L3.4 9.3l6-.7z"/></svg>',
  starOn: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M12 3l2.6 5.6 6 .7-4.5 4.1 1.2 6L12 16.5 6.7 19.4l1.2-6L3.4 9.3l6-.7z"/></svg>',
  up: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M6 15l6-6 6 6"/></svg>',
  x: '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  plus: '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>'
};

/* ---------------- render ---------------- */
function render() {
  const app = $('#app');
  if (!S.loaded) return;
  if (joinCode && !S.me) { app.innerHTML = vJoin(); return; }
  const tabs = [['tabelle', 'Tabelle'], ['draft', 'Draft'], ['kader', 'Kader'], ['rennen', 'Rennen']];
  if (S.me && S.me.is_admin) tabs.push(['admin', 'Admin']);
  if (!tabs.some(t => t[0] === S.ui.tab)) S.ui.tab = 'tabelle';
  const views = { tabelle: vTable, draft: vDraft, kader: vKader, rennen: vRaces, admin: vAdmin };
  app.innerHTML = `<div class="wrap">${vHeader()}${S.err ? `<div class="notice err">${esc(S.err)}</div>` : ''}<main class="stack">${views[S.ui.tab]()}</main></div>
  <nav class="tabs" aria-label="Bereiche"><div class="in">${tabs.map(([k, l]) => `<button data-tab="${k}" ${S.ui.tab === k ? 'aria-current="page"' : ''}>${I[k]}${l}</button>`).join('')}</div></nav>`;
}

function vHeader() {
  const ph = phase(); const n = S.players.length; let st = '';
  if (ph === 'reg') st = `Anmeldung offen bis <b>${fmtDT(S.set.reg_deadline)}</b> · ${n} Mitspieler`;
  else if (ph === 'closed') st = `Anmeldung geschlossen · Auslosung <b>${fmtDT(S.set.order_draw_at)}</b>`;
  else if (ph === 'drawn') st = `Draft läuft automatisch am <b>${fmtDT(S.set.draft_at)}</b>`;
  else { const nt = nextTransferRun(); st = `Saison läuft · nächster Transfer <b>${nt ? fmtDT(nt) : 'Mo 12:00'}</b>`; }
  const titles = { tabelle: ph === 'season' ? 'Tabelle' : 'Mitspieler', draft: 'Draft', kader: 'Mein Kader', rennen: 'Rennen', admin: 'Admin' };
  return `<header class="top"><img src="img/logo.jpg" alt="Ski-Fantasy" width="92" height="85"><div class="grow"><div class="eyebrow">Weltcup 2026/27</div><h1 class="gl">${titles[S.ui.tab]}</h1></div>
    ${S.me ? `<div class="who"><div class="eyebrow">Du bist</div><div class="d" style="font-size:18px;font-weight:700">${esc(S.me.name)}</div></div>` : ''}</header>
    <div class="gates" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div><div class="status">${st}</div>`;
}

function installHint() {
  let standalone = false; try { standalone = matchMedia('(display-mode: standalone)').matches || navigator.standalone; } catch (e) { }
  if (standalone || !S.me || store('sf_hint') === '1') return '';
  const ios = /iPhone|iPad|iPod/.test(navigator.userAgent);
  return `<div class="notice"><b>Tipp:</b> Leg dir Ski-Fantasy als App auf den Home-Bildschirm. ${ios ? 'In Safari unten auf «Teilen» und dann «Zum Home-Bildschirm».' : 'Im Browser-Menü (⋮) auf «Zum Startbildschirm hinzufügen» oder «App installieren».'} Du bleibst dann automatisch angemeldet.
    <div style="margin-top:8px"><button class="btn small ghost" data-act="hideHint">Verstanden</button></div></div>`;
}

/* ----- Tabelle ----- */
function vTable() {
  let out = installHint();
  if (!S.me && !S.token) out += `<div class="notice">Du siehst die Liga als Gast. Zum Mitspielen brauchst du deinen persönlichen Link.</div>`;
  if (phase() !== 'season') {
    const ps = S.players.slice().sort((a, b) => (a.draft_pos || 999) - (b.draft_pos || 999) || new Date(a.joined_at) - new Date(b.joined_at));
    out += `<section class="card"><div class="between"><h3>${S.set.order_drawn ? 'Draft-Reihenfolge Männer' : 'Angemeldet'}</h3><span class="chip">${ps.length} Mitspieler</span></div>
      <div class="list">${ps.map((p, i) => `<div class="item ${S.me && p.id === S.me.id ? 'me-row' : ''}"><span class="badge">${p.draft_pos || i + 1}</span><div class="grow" style="font-weight:600">${esc(p.name)}</div>${S.set.order_drawn ? `<span class="tiny muted">Frauen: ${ps.length - p.draft_pos + 1}.</span>` : ''}</div>`).join('') || '<div class="item muted">Noch niemand angemeldet.</div>'}</div></section>`;
    out += vTimeline();
    return out + vRulesCard();
  }
  const st = sortedStandings(); const { date, d } = lastDelta();
  const top = st.slice(0, 3);
  const pod = i => top[i] ? `<div class="p${i + 1}"><div class="nm">${esc(top[i].name)}</div><div class="num pts">${fmtN(top[i].total)}</div><div class="blk">${i + 1}</div></div>` : '<div></div>';
  out += `<section class="card"><div class="podium">${pod(1)}${pod(0)}${pod(2)}</div>
    <div class="list">${st.map((x, i) => {
      const open = S.ui.open === x.player_id;
      return `<div class="item ${S.me && x.player_id === S.me.id ? 'me-row' : ''}" data-act="openP" data-id="${x.player_id}" style="cursor:pointer">
        <span class="badge ${i < 3 ? 'g' + (i + 1) : ''}">${i + 1}</span><div class="grow" style="font-weight:600">${esc(x.name)}</div>
        <span class="small" style="color:var(--ok)">${date ? '+' + (d[x.player_id] || 0) : ''}</span><span class="num" style="font-size:20px;width:70px;text-align:right">${fmtN(x.total)}</span></div>
        ${open ? `<div style="padding:4px 0 12px">${rosterGrid(x.player_id)}</div>` : ''}`;
    }).join('')}</div>
    <div class="tiny muted">${date ? 'Grüne Zahl: Punkte vom letzten Renntag (' + fmtD(date) + '). ' : ''}Tippe auf einen Namen für den Kader.</div></section>`;
  if (S.transfers.length) {
    const lastRun = S.transfers[0].run_at; const tr = S.transfers.filter(t => t.run_at === lastRun);
    out += `<section class="card"><div class="between"><h3>Letzte Transfers</h3><span class="tiny muted">${fmtDT(lastRun)}</span></div>
      <div class="list">${tr.map(t => `<div class="item small"><div class="grow"><b>${esc(pName(t.player_id))}</b><br><span style="color:var(--ok)">+</span> ${aHtml(t.in_id)} &nbsp; <span style="color:var(--women)">−</span> ${aHtml(t.out_id)}</div></div>`).join('')}</div></section>`;
  }
  return out + vRulesCard();
}
function rosterGrid(pid) {
  const ids = currentRoster(pid);
  const col = g => ids.filter(a => A(a).g === g).sort((a, b) => ownedPts(pid, b) - ownedPts(pid, a)).map(a => `<div class="item small"><div class="grow">${aHtml(a)}</div><span class="num" style="font-size:16px">${ownedPts(pid, a)}</span></div>`).join('');
  return `<div class="grid2"><div class="card" style="border-top:4px solid var(--men);padding:10px 12px"><h3>Männer</h3><div class="list">${col('m')}</div></div><div class="card" style="border-top:4px solid var(--women);padding:10px 12px"><h3>Frauen</h3><div class="list">${col('w')}</div></div></div>`;
}
function vTimeline() {
  const rows = [['Anmeldeschluss', S.set.reg_deadline], ['Auslosung Reihenfolge', S.set.order_draw_at], ['Draft (automatisch)', S.set.draft_at]];
  return `<section class="card"><h3>Ablauf</h3><div class="list">${rows.map(([l, t]) => `<div class="item"><div class="grow">${l}</div><span class="d" style="font-weight:700">${fmtDT(t)}</span></div>`).join('')}
    <div class="item"><div class="grow">Erstes zählendes Rennen</div><span class="d" style="font-weight:700">${fmtD(S.set.season_start)}</span></div>
    <div class="item"><div class="grow">Transfers</div><span class="d" style="font-weight:700">jeden Mo, 12:00</span></div></div></section>`;
}
function vRulesCard() {
  return `<details class="card"><summary><div class="between"><h3>Regeln</h3><span class="tiny muted">anzeigen</span></div></summary>
  <div class="small" style="color:var(--soft)">
  <p><b>Kader:</b> Jeder hat immer genau 5 Männer und 5 Frauen. Ein Athlet gehört höchstens einem Mitspieler.</p>
  <p><b>Draft:</b> Die Reihenfolge wird ausgelost. Zuerst werden 5 Runden Männer gezogen, dann 5 Runden Frauen, jeweils als Snake (die Reihenfolge dreht jede Runde). Bei den Frauen gilt die Reihenfolge umgekehrt: Wer bei den Männern zuerst wählt, ist bei den Frauen zuletzt dran. Gewählt wird automatisch nach deiner Wunschliste. Ist sie leer oder sind alle weg, nimmt das System den besten freien Athleten nach den Punkten der letzten Saison.</p>
  <p><b>Punkte:</b> Weltcup-Skala, 100 Punkte für Rang 1 bis 1 Punkt für Rang 30. Alle 10 Athleten zählen. Die Punkte gehen an den, dem der Athlet am Renntag gehört. Es zählen Weltcuprennen ab ${fmtD(S.set.season_start)}, Sölden zählt nicht. Die WM zählt nicht.</p>
  <p><b>Transfers:</b> Jeden Montag um 12:00 automatisch, höchstens ${S.set.max_transfers || 2} pro Mitspieler. Der Tabellenletzte kommt zuerst zum Zug. Du gibst immer einen Mann für einen Mann bzw. eine Frau für eine Frau ab.</p></div></details>`;
}

/* ----- Draft ----- */
function vDraft() {
  if (S.set.draft_done) {
    const byRound = {};
    S.picks.forEach(p => { const k = p.g + p.round; (byRound[k] = byRound[k] || []).push(p); });
    return `<section class="card"><h3>Draft-Resultat</h3><div class="list">${S.picks.map(p => `<div class="item ${S.me && p.player_id === S.me.id ? 'me-row' : ''}"><span class="badge ${p.g}">${p.n}</span><div class="grow">${aHtml(p.athlete_id)}<div class="tiny muted">${esc(pName(p.player_id))} · ${p.g === 'm' ? 'Männer' : 'Frauen'} Runde ${p.round}${p.auto ? ' · automatisch gewählt' : ''}</div></div></div>`).join('')}</div></section>`;
  }
  if (!S.me) return `<div class="notice">Mit deinem persönlichen Link kannst du hier deine Draft-Wunschliste anlegen.</div>`;
  const g = S.ui.dg; const list = (S.me.draft_wish && S.me.draft_wish[g]) || [];
  const T = S.players.length; const pos = S.me.draft_pos; const gpos = pos ? (g === 'm' ? pos : T - pos + 1) : null;
  const rec = Math.min(25, 5 + (gpos || T));
  let info = gpos ? `Du wählst bei den ${g === 'm' ? 'Männern' : 'Frauen'} an <b>${gpos}. Stelle</b> von ${T}.` : `Die Reihenfolge wird am ${fmtDT(S.set.order_draw_at)} ausgelost.`;
  info += ` Der Draft läuft am <b>${fmtDT(S.set.draft_at)}</b> automatisch. Liste mindestens <b>${rec}</b> ${g === 'm' ? 'Männer' : 'Frauen'}, je länger, desto sicherer.`;
  return `<div class="seg" role="group" aria-label="Geschlecht">
      <button class="m" data-act="dg" data-g="m" aria-pressed="${g === 'm'}">Männer · ${((S.me.draft_wish || {}).m || []).length}</button>
      <button class="w" data-act="dg" data-g="w" aria-pressed="${g === 'w'}">Frauen · ${((S.me.draft_wish || {}).w || []).length}</button></div>
    <div class="notice">${info}</div>
    <section class="card"><div class="between"><h3>Meine Wunschliste</h3><span class="tiny muted" id="saveState"></span></div>
      <div class="list">${list.map((a, i) => `<div class="item"><span class="badge ${g}">${i + 1}</span><div class="grow">${aHtml(a)}<div class="tiny muted">${fmtN(A(a).prev)} Pkt. letzte Saison</div></div>
        <button class="icon-btn" data-act="dUp" data-i="${i}" aria-label="Nach oben" ${i === 0 ? 'disabled' : ''}>${I.up}</button>
        <button class="icon-btn" data-act="dDel" data-i="${i}" aria-label="Entfernen">${I.x}</button></div>`).join('') || '<div class="item muted small">Noch leer. Tippe unten auf den Stern, um Athleten hinzuzufügen.</div>'}</div></section>
    <section class="card"><div class="between"><h3>Alle ${g === 'm' ? 'Männer' : 'Frauen'}</h3><span class="tiny muted">nach Punkten 2025/26</span></div>
      <label for="dq" class="sr">Suchen<input id="dq" type="search" placeholder="Name oder Nation, z.B. SUI" value="${esc(S.ui.dq)}" autocomplete="off"></label>
      <div class="list" id="dpool">${draftPool()}</div></section>`;
}
function draftPool() {
  const g = S.ui.dg; const list = (S.me.draft_wish && S.me.draft_wish[g]) || []; const q = norm(S.ui.dq).trim();
  const all = Object.values(S.A).filter(a => a.g === g && (!q || norm(a.first + ' ' + a.last + ' ' + a.nat).includes(q)))
    .sort((a, b) => b.prev - a.prev || (a.prev_rank || 999) - (b.prev_rank || 999) || a.last.localeCompare(b.last)).slice(0, q ? 80 : 120);
  return all.map(a => { const on = list.includes(a.id); return `<div class="item"><span class="num muted" style="width:28px">${a.prev_rank || '–'}</span><div class="grow">${aHtml(a.id)}</div><span class="num" style="font-size:16px;color:var(--soft)">${fmtN(a.prev)}</span>
    <button class="icon-btn ${on ? 'on' : ''}" data-act="dStar" data-id="${esc(a.id)}" aria-label="${on ? 'Von Wunschliste entfernen' : 'Auf Wunschliste'}" aria-pressed="${on}">${on ? I.starOn : I.star}</button></div>`; }).join('') || '<div class="item muted small">Keine Treffer.</div>';
}

/* ----- Kader ----- */
function vKader() {
  if (!S.me) return `<div class="notice">Mit deinem persönlichen Link siehst du hier deinen Kader und deine Transferwünsche.</div>`;
  if (!S.set.draft_done) return `<div class="notice">Dein Kader entsteht am <b>${fmtDT(S.set.draft_at)}</b> beim Draft. Bis dahin: Wunschliste im Bereich «Draft» pflegen.</div>`;
  const me = S.me.id; const ros = currentRoster(me); const tot = (S.standings.find(s => s.player_id === me) || {}).total || 0;
  const rank = sortedStandings().findIndex(s => s.player_id === me) + 1; const tOrd = transferOrder().indexOf(me) + 1;
  const tw = S.me.transfer_wish || { wants: [], drops_m: [], drops_w: [] };
  const nt = nextTransferRun();
  const wantsG = g => tw.wants.some(a => A(a).g === g); const dropsOf = g => g === 'm' ? tw.drops_m : tw.drops_w;
  const warn = ['m', 'w'].filter(g => wantsG(g) && !dropsOf(g).length).map(g => `<div class="notice">Du willst ${g === 'm' ? 'einen Mann' : 'eine Frau'} holen, hast aber niemanden zum Abgeben markiert. Markiere unten bei «Abgeben» mindestens ${g === 'm' ? 'einen Mann' : 'eine Frau'}.</div>`).join('');
  const dropCol = g => ros.filter(a => A(a).g === g).map(a => { const i = dropsOf(g).indexOf(a); return `<button class="item" data-act="tDrop" data-id="${esc(a)}" data-g="${g}" style="appearance:none;background:none;border:0;border-bottom:1px solid var(--line);width:100%;text-align:left;cursor:pointer;color:inherit" aria-pressed="${i >= 0}">
      <span class="badge ${i >= 0 ? g : ''}">${i >= 0 ? i + 1 : '·'}</span><span class="grow small">${aHtml(a, 'nonat')}</span><span class="num small muted">${ownedPts(me, a)}</span></button>`; }).join('');
  const myTr = S.transfers.filter(t => t.player_id === me);
  return `<section class="card"><div class="between"><div><h3>Rang ${rank} von ${S.standings.length}</h3></div><div style="text-align:right"><div class="eyebrow">Punkte</div><div class="num" style="font-size:30px;line-height:1">${fmtN(tot)}</div></div></div>${rosterGrid(me)}</section>
  <section class="card"><div class="between"><h2>Transfers</h2><span class="tiny muted">${nt ? fmtDT(nt) : ''}</span></div>
    <div class="small muted">Max. ${S.set.max_transfers} pro Woche. Du bist aktuell als <b style="color:var(--fg)">${tOrd}.</b> am Zug (der Letzte der Tabelle zuerst).</div>
    ${warn}
    <h3 style="color:var(--ok)">Holen · nach Priorität</h3>
    <div class="list">${tw.wants.map((a, i) => { const o = ownerNow(a); return `<div class="item"><span class="badge">${i + 1}</span><span class="dot ${A(a).g}"></span><div class="grow small">${aHtml(a)}${o ? `<div class="tiny" style="color:var(--warn)">gehört zurzeit ${esc(pName(o))}</div>` : ''}</div>
      <button class="icon-btn" data-act="tUp" data-i="${i}" aria-label="Nach oben" ${i === 0 ? 'disabled' : ''}>${I.up}</button><button class="icon-btn" data-act="tDel" data-i="${i}" aria-label="Entfernen">${I.x}</button></div>`; }).join('') || '<div class="item muted small">Keine Wünsche. Unten freie Athleten suchen und mit + hinzufügen.</div>'}</div>
    <h3 style="color:var(--women)">Abgeben · Reihenfolge antippen</h3>
    <div class="grid2"><div><div class="tiny muted" style="margin-bottom:4px">Männer</div><div class="list">${dropCol('m')}</div></div><div><div class="tiny muted" style="margin-bottom:4px">Frauen</div><div class="list">${dropCol('w')}</div></div></div>
    <div class="tiny muted">Wird ein Mann geholt, geht der Mann mit der tiefsten Nummer. Bei Frauen gleich.</div></section>
  <section class="card"><h3>Freie Athleten</h3>
    <div class="seg" role="group" aria-label="Geschlecht"><button class="m" data-act="tg" data-g="m" aria-pressed="${S.ui.tg === 'm'}">Männer</button><button class="w" data-act="tg" data-g="w" aria-pressed="${S.ui.tg === 'w'}">Frauen</button></div>
    <label>Suchen<input id="tq" type="search" placeholder="Name oder Nation" value="${esc(S.ui.tq)}" autocomplete="off"></label>
    <div class="list" id="tpool">${freePool()}</div></section>
  ${myTr.length ? `<section class="card"><h3>Meine Transfers</h3><div class="list">${myTr.map(t => `<div class="item small"><div class="grow"><span style="color:var(--ok)">+</span> ${aHtml(t.in_id)}<br><span style="color:var(--women)">−</span> ${aHtml(t.out_id)}</div><span class="tiny muted">${fmtDT(t.run_at)}</span></div>`).join('')}</div></section>` : ''}`;
}
function freePool() {
  const g = S.ui.tg; const q = norm(S.ui.tq).trim(); const owned = new Set(S.own.filter(o => !o.to_ts).map(o => o.athlete_id));
  const wants = (S.me.transfer_wish || {}).wants || [];
  const list = Object.values(S.A).filter(a => a.g === g && !owned.has(a.id) && (!q || norm(a.first + ' ' + a.last + ' ' + a.nat).includes(q)))
    .map(a => ({ a, sp: seasonPts(a.id) })).sort((x, y) => y.sp - x.sp || y.a.prev - x.a.prev).slice(0, 60);
  return list.map(({ a, sp }) => { const on = wants.includes(a.id); return `<div class="item"><div class="grow">${aHtml(a.id)}<div class="tiny muted">${sp} Pkt. diese Saison · ${fmtN(a.prev)} letzte</div></div>
    <button class="icon-btn ${on ? 'on' : ''}" data-act="tAdd" data-id="${esc(a.id)}" aria-label="${on ? 'Gewünscht' : 'Auf Transferliste'}" ${on ? 'disabled' : ''}>${on ? I.starOn : I.plus}</button></div>`; }).join('') || '<div class="item muted small">Keine freien Athleten gefunden.</div>';
}

/* ----- Rennen ----- */
function vRaces() {
  if (!S.races.length) return `<div class="notice">Noch keine Rennen erfasst. Die Ranglisten werden nach jedem Rennen automatisch geholt.</div>`;
  return S.races.map(r => {
    const res = S.results.filter(x => x.race_id === r.id).sort((a, b) => a.rank - b.rank);
    const open = S.ui.race === r.id; const win = res[0];
    const chips = r.counts ? S.prp.filter(x => x.race_id === r.id && x.pts > 0).sort((a, b) => b.pts - a.pts) : [];
    return `<section class="card" style="${open ? '' : 'gap:6px'}">
      <button data-act="race" data-id="${esc(r.id)}" style="appearance:none;background:none;border:0;padding:0;text-align:left;color:inherit;cursor:pointer" aria-expanded="${open}">
        <div class="row"><span class="dot ${r.g}" style="width:10px;height:10px"></span><div class="grow"><div class="d" style="font-size:20px;font-weight:800;text-transform:uppercase">${esc(r.place)} · ${esc(r.disc)} ${r.g === 'm' ? 'Männer' : 'Frauen'}</div>
        <div class="tiny muted">${fmtD(r.date)}${win ? ' · Sieg: ' + esc(A(win.athlete_id).first + ' ' + A(win.athlete_id).last) : ''}</div></div>${r.counts ? '' : '<span class="chip no">zählt nicht</span>'}</div></button>
      ${chips.length ? `<div class="row" style="flex-wrap:wrap;gap:6px">${chips.map(c => `<span class="chip" style="color:var(--fg);text-transform:none;letter-spacing:0;font-family:var(--f-b);font-size:13px">${esc(pName(c.player_id))} <b style="color:var(--ok)">+${c.pts}</b></span>`).join('')}</div>` : ''}
      ${open ? `<div class="list">${res.map(x => { const o = r.counts ? ownerAt(x.athlete_id, r.date) : null; const mine = S.me && o === S.me.id; return `<div class="item small"><span class="badge ${x.rank <= 3 ? 'g' + x.rank : ''}">${x.rank}</span><div class="grow">${aHtml(x.athlete_id)}</div>
        <span class="tiny" style="color:${mine ? 'var(--men)' : o ? 'var(--soft)' : 'var(--dim)'}">${o ? esc(pName(o)) : (r.counts ? 'frei' : '')}</span><span class="num" style="width:34px;text-align:right">${x.pts}</span></div>`; }).join('')}</div>
        ${r.source ? `<div class="tiny muted">Quelle: <a href="${esc(r.source)}" target="_blank" rel="noopener">${esc(r.source.replace(/^https?:\/\//, '').slice(0, 50))}</a></div>` : ''}` : ''}
    </section>`;
  }).join('');
}

/* ----- Admin ----- */
const toLocalInput = ts => { if (!ts) return ''; const d = new Date(ts); const p = zParts(d); const m = new Intl.DateTimeFormat('en-GB', { timeZone: TZ, minute: '2-digit' }).format(d).padStart(2, '0'); return `${p.year}-${p.month}-${p.day}T${p.hour}:${m}`; };
function vAdmin() {
  const ad = S.admin; if (!ad) return '<div class="notice">Lade …</div>';
  const s = ad.settings; const inv = BASE + '?join=' + s.invite_code; const c = S.ui.confirm;
  const act = (k, label, warn) => c === k ? `<div class="row"><button class="btn danger" data-act="adm" data-k="${k}">${label} bestätigen</button><button class="btn ghost" data-act="cancel">Abbrechen</button></div><div class="tiny muted">${warn}</div>` : `<button class="btn ghost" data-act="ask" data-k="${k}">${label}</button>`;
  return `<section class="card"><h3>Einladungslink für die Gruppe</h3><div class="linkbox">${esc(inv)}</div>
    <div class="row"><button class="btn" data-act="copy" data-v="${esc(inv)}">Link kopieren</button>${act('new_invite', 'Neuen Link erstellen', 'Der alte Einladungslink funktioniert danach nicht mehr.')}</div>
    <div class="tiny muted">Diesen Link in den Gruppenchat schicken. Jeder trägt seinen Namen ein und bekommt automatisch seinen persönlichen Link.</div></section>
  <section class="card"><div class="between"><h3>Mitspieler</h3><span class="chip">${ad.players.length}</span></div>
    <div class="list">${ad.players.map(p => `<div class="item"><span class="badge">${p.draft_pos || '·'}</span><div class="grow"><div style="font-weight:600">${esc(p.name)}${p.is_admin ? ' <span class="chip">Admin</span>' : ''}</div><div class="tiny muted">Wunschliste: ${p.wish_m} M / ${p.wish_w} F</div></div>
      <button class="btn small ghost" data-act="copy" data-v="${esc(BASE + '?p=' + p.token)}">Link</button>
      ${!s.order_drawn && !p.is_admin ? (c === 'rm' + p.id ? `<button class="btn small danger" data-act="rm" data-id="${p.id}">Entfernen</button>` : `<button class="icon-btn" data-act="ask" data-k="rm${p.id}" aria-label="${esc(p.name)} entfernen">${I.x}</button>`) : ''}</div>`).join('')}</div>
    ${!s.order_drawn ? `<div class="row"><label class="grow">Mitspieler von Hand hinzufügen<input id="addName" type="text" maxlength="24" placeholder="Name"></label><button class="btn" data-act="addP" style="align-self:flex-end">${I.plus}</button></div>` : ''}
    <div class="tiny muted">«Link» kopiert den persönlichen Link eines Mitspielers, falls jemand seinen verloren hat.</div></section>
  <section class="card"><h3>Termine</h3>
    <label>Anmeldeschluss<input id="s_reg" type="datetime-local" value="${toLocalInput(s.reg_deadline)}"></label>
    <label>Auslosung der Reihenfolge<input id="s_draw" type="datetime-local" value="${toLocalInput(s.order_draw_at)}"></label>
    <label>Draft<input id="s_draft" type="datetime-local" value="${toLocalInput(s.draft_at)}"></label>
    <label>Erstes zählendes Rennen<input id="s_start" type="date" value="${esc(s.season_start)}"></label>
    <label>Transfers pro Woche<select id="s_max">${[1, 2, 3].map(n => `<option ${n === s.max_transfers ? 'selected' : ''}>${n}</option>`).join('')}</select></label>
    <button class="btn" data-act="saveSet">Speichern</button></section>
  <section class="card"><h3>Von Hand auslösen</h3><div class="tiny muted">Normalerweise läuft alles automatisch. Nur bei Bedarf.</div>
    ${!s.order_drawn ? act('draw', 'Reihenfolge jetzt auslosen', 'Danach kann sich niemand mehr anmelden.') : ''}
    ${!s.draft_done ? act('draft', 'Draft jetzt ausführen', 'Der Draft läuft sofort und kann nicht rückgängig gemacht werden.') : ''}
    ${s.draft_done ? act('transfers', 'Transfers jetzt ausführen', 'Alle hinterlegten Wünsche werden sofort ausgeführt.') : ''}
    <button class="btn ghost" data-act="adm" data-k="ingest">Resultate jetzt laden</button>
    <div class="tiny muted">Letzter Resultat-Import: ${s.last_ingest_at ? fmtDT(s.last_ingest_at) : 'noch keiner'} · ${esc(s.last_ingest_status || '')}</div></section>`;
}

/* ----- Join ----- */
function vJoin() {
  if (S.token && S.me) return '';
  return `<div class="join"><img src="img/logo.jpg" alt="Ski-Fantasy" width="240" height="222">
    <div><div class="eyebrow">Weltcup 2026/27</div><h1 class="gl">Mitspielen</h1><div class="gates" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div></div>
    <p class="small" style="color:var(--soft);margin:0">Du draftest 5 Männer und 5 Frauen und holst mit ihren Weltcup-Resultaten Punkte. Anmeldung bis <b>${fmtDT(S.set.reg_deadline)}</b>.</p>
    ${S.err ? `<div class="notice err">${esc(S.err)}</div>` : ''}
    <label>Dein Name in der Liga<input id="joinName" type="text" maxlength="24" placeholder="Vorname oder Spitzname" autocomplete="nickname"></label>
    <button class="btn" data-act="join">Ich bin dabei</button>
    <div class="tiny muted">Kein Konto, kein Passwort. Du bekommst einen persönlichen Link, über den du immer reinkommst.</div></div>`;
}

/* ---------------- actions ---------------- */
let saveTimer = null;
function saveDraftWish(g) {
  const el = $('#saveState'); if (el) el.textContent = 'speichere …';
  clearTimeout(saveTimer);
  saveTimer = setTimeout(async () => {
    try { await rpc('set_draft_wish', { p_token: S.token, p_g: g, p_list: S.me.draft_wish[g] }); const e = $('#saveState'); if (e) e.textContent = 'gespeichert'; }
    catch (e) { toast(e.message); }
  }, 500);
}
let tSaveTimer = null;
function saveTransferWish() {
  clearTimeout(tSaveTimer);
  tSaveTimer = setTimeout(async () => {
    const w = S.me.transfer_wish;
    try { await rpc('set_transfer_wish', { p_token: S.token, p_wants: w.wants, p_drops_m: w.drops_m, p_drops_w: w.drops_w }); }
    catch (e) { toast(e.message); }
  }, 400);
}
async function copy(v) {
  try { await navigator.clipboard.writeText(v); toast('Link kopiert'); }
  catch (e) { prompt('Link kopieren:', v); }
}
function setTab(t) { S.ui.tab = t; S.ui.confirm = null; try { sessionStorage.setItem('sf_tab', t); } catch (e) { } render(); window.scrollTo(0, 0); }

document.addEventListener('input', e => {
  if (e.target.id === 'dq') { S.ui.dq = e.target.value; $('#dpool').innerHTML = draftPool(); }
  if (e.target.id === 'tq') { S.ui.tq = e.target.value; $('#tpool').innerHTML = freePool(); }
});
document.addEventListener('click', async e => {
  const b = e.target.closest('[data-act],[data-tab]'); if (!b) return;
  if (b.dataset.tab) return setTab(b.dataset.tab);
  const act = b.dataset.act, id = b.dataset.id;
  const dw = S.me && S.me.draft_wish; const g = S.ui.dg;
  switch (act) {
    case 'hideHint': store('sf_hint', '1'); render(); break;
    case 'openP': S.ui.open = S.ui.open === +id ? null : +id; render(); break;
    case 'race': S.ui.race = S.ui.race === id ? null : id; render(); break;
    case 'dg': S.ui.dg = b.dataset.g; render(); break;
    case 'tg': S.ui.tg = b.dataset.g; render(); break;
    case 'dStar': { const l = dw[g] = (dw[g] || []).slice(); const i = l.indexOf(id); if (i >= 0) l.splice(i, 1); else l.push(id); saveDraftWish(g); render(); break; }
    case 'dUp': { const l = dw[g]; const i = +b.dataset.i; [l[i - 1], l[i]] = [l[i], l[i - 1]]; saveDraftWish(g); render(); break; }
    case 'dDel': { dw[g].splice(+b.dataset.i, 1); saveDraftWish(g); render(); break; }
    case 'tAdd': case 'tUp': case 'tDel': case 'tDrop': {
      const w = S.me.transfer_wish = S.me.transfer_wish || { wants: [], drops_m: [], drops_w: [] };
      if (act === 'tAdd') { if (w.wants.length >= 15) { toast('Maximal 15 Wünsche'); break; } if (!w.wants.includes(id)) w.wants.push(id); toast('Auf der Transferliste'); }
      if (act === 'tUp') { const i = +b.dataset.i; [w.wants[i - 1], w.wants[i]] = [w.wants[i], w.wants[i - 1]]; }
      if (act === 'tDel') w.wants.splice(+b.dataset.i, 1);
      if (act === 'tDrop') { const k = b.dataset.g === 'm' ? 'drops_m' : 'drops_w'; const i = w[k].indexOf(id); if (i >= 0) w[k].splice(i, 1); else w[k].push(id); }
      saveTransferWish(); render(); break;
    }
    case 'join': {
      const n = ($('#joinName').value || '').trim(); if (n.length < 2) { toast('Bitte einen Namen eingeben'); break; }
      b.disabled = true;
      try { const t = await rpc('register', { p_invite: joinCode, p_name: n }); store('sf_token', t); store('sf_hint', null); location.replace(BASE + '?p=' + encodeURIComponent(t)); }
      catch (err) { S.err = err.message; b.disabled = false; render(); }
      break;
    }
    case 'copy': copy(b.dataset.v); break;
    case 'ask': S.ui.confirm = b.dataset.k; render(); break;
    case 'cancel': S.ui.confirm = null; render(); break;
    case 'rm': try { await rpc('admin_remove_player', { p_token: S.token, p_id: +id }); toast('Entfernt'); S.ui.confirm = null; await load(); } catch (err) { toast(err.message); } break;
    case 'addP': { const n = ($('#addName').value || '').trim(); try { await rpc('admin_add_player', { p_token: S.token, p_name: n }); toast(n + ' hinzugefügt'); await load(); } catch (err) { toast(err.message); } break; }
    case 'adm': try { const msg = await rpc('admin_action', { p_token: S.token, p_action: b.dataset.k }); toast(msg); S.ui.confirm = null; await load(); } catch (err) { toast(err.message); } break;
    case 'saveSet': {
      const iso = v => v ? new Date(v).toISOString() : null;
      try {
        await rpc('admin_settings', { p_token: S.token, p: { reg_deadline: iso($('#s_reg').value), order_draw_at: iso($('#s_draw').value), draft_at: iso($('#s_draft').value), season_start: $('#s_start').value || null, max_transfers: +$('#s_max').value } });
        toast('Gespeichert'); await load();
      } catch (err) { toast(err.message); }
      break;
    }
  }
});

load();
})();
