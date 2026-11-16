#!/usr/bin/env python3
"""Erzeugt data/calendar.ics aus data/calendar.json. Aufruf: python3 tools/build_calendar.py"""
import json, datetime as dt, hashlib, os
from zoneinfo import ZoneInfo
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
Z = ZoneInfo('Europe/Zurich'); U = dt.timezone.utc
cal = json.load(open(os.path.join(ROOT, 'data/calendar.json')))
G = {'m': 'Männer', 'w': 'Frauen'}
def esc(s): return s.replace('\\', '\\\\').replace(',', '\\,').replace(';', '\\;').replace('\n', '\\n')
def fmt(t): return t.astimezone(U).strftime('%Y%m%dT%H%M%SZ')
out = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Ski-Fantasy//Rennkalender//DE', 'CALSCALE:GREGORIAN',
       'METHOD:PUBLISH', 'X-WR-CALNAME:Ski-Fantasy Weltcup 26/27', 'X-WR-TIMEZONE:Europe/Zurich',
       'REFRESH-INTERVAL;VALUE=DURATION:PT12H', 'X-PUBLISHED-TTL:PT12H']
stamp = dt.datetime.now(U).strftime('%Y%m%dT%H%M%SZ')
for r in cal['races']:
    d = dt.date.fromisoformat(r['date'])
    uid = hashlib.sha1((r['date'] + r['g'] + r['disc']).encode()).hexdigest()[:16] + '@skifantasy'
    status = r.get('status') or ''
    title = f"{'❌ ABGESAGT: ' if status == 'cancelled' else ''}{r['disc']} {G[r['g']]} · {r['place']}"
    desc = []
    if r.get('t1'): desc.append(f"1. Lauf {r['t1']}" + (f", 2. Lauf {r['t2']}" if r.get('t2') else ''))
    if r.get('note'): desc.append(r['note'])
    if not r.get('counts', True): desc.append('Zählt nicht für Ski-Fantasy.')
    desc.append('https://stoepps.github.io/fantaski/')
    ev = ['BEGIN:VEVENT', f'UID:{uid}', f'DTSTAMP:{stamp}', f'SUMMARY:{esc(title)}']
    if r.get('t1'):
        h, m = map(int, r['t1'].split(':')); s = dt.datetime(d.year, d.month, d.day, h, m, tzinfo=Z)
        if r.get('t2'):
            h2, m2 = map(int, r['t2'].split(':')); e = dt.datetime(d.year, d.month, d.day, h2, m2, tzinfo=Z) + dt.timedelta(minutes=75)
        else:
            e = s + dt.timedelta(minutes=105)
        ev += [f'DTSTART:{fmt(s)}', f'DTEND:{fmt(e)}']
    else:
        ev += [f'DTSTART;VALUE=DATE:{d:%Y%m%d}', f'DTEND;VALUE=DATE:{d + dt.timedelta(days=1):%Y%m%d}']
    ev += [f'LOCATION:{esc(r["place"] + " (" + r["nat"] + ")")}', f'DESCRIPTION:{esc(chr(10).join(desc))}']
    if status == 'cancelled': ev.append('STATUS:CANCELLED')
    ev.append('END:VEVENT'); out += ev
for x in cal.get('events', []):
    a = dt.date.fromisoformat(x['from']); b = dt.date.fromisoformat(x['to']) + dt.timedelta(days=1)
    out += ['BEGIN:VEVENT', f'UID:{hashlib.sha1(x["title"].encode()).hexdigest()[:16]}@skifantasy', f'DTSTAMP:{stamp}',
            f'SUMMARY:{esc(x["title"])}', f'DTSTART;VALUE=DATE:{a:%Y%m%d}', f'DTEND;VALUE=DATE:{b:%Y%m%d}',
            f'DESCRIPTION:{esc(x.get("note", ""))}', 'TRANSP:TRANSPARENT', 'END:VEVENT']
out.append('END:VCALENDAR')
def fold(l):
    b = l.encode('utf-8'); parts = []
    while len(b) > 74:
        i = 74
        while (b[i] & 0xC0) == 0x80: i -= 1
        parts.append(b[:i].decode()); b = b[i:]
    parts.append(b.decode()); return '\r\n '.join(parts)
out = [fold(l) for l in out]
open(os.path.join(ROOT, 'data/calendar.ics'), 'w', newline='').write('\r\n'.join(out) + '\r\n')
print(len(cal['races']), 'Rennen ->', 'data/calendar.ics')
