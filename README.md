# Ski-Fantasy

Private Fantasy-Liga zum Ski-Alpin-Weltcup 2026/27.

- App: https://stoepps.github.io/fantaski/
- `supabase-setup.sql` – Datenbank, Spiellogik (Draft, Transfers, Punkte) und Zeitsteuerung für Supabase
- `data/results.json` – Weltcup-Ranglisten, werden nach jedem Rennen automatisch ergänzt und von der Datenbank alle 30 Minuten eingelesen
- `supabase-update-2026-11-16.sql` – provisorische Resultate (*), Teamnamen, Punkte gehören dem Besitzer am Ende des Renntags
- `data/calendar.json` / `data/calendar.ics` – Rennkalender (ICS zum Abonnieren; nach Änderungen `python3 tools/build_calendar.py`)
- `stats.js` – Wochenwertung, Auszeichnungen, Kugeln, Verlauf, Form (App und News-Jobs)
- `tools/fetch.sh` + `tools/report.mjs` – Wochenbericht für die News: `bash tools/fetch.sh /tmp/sfdata && node tools/report.mjs /tmp/sfdata [--final]`
