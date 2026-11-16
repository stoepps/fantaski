#!/usr/bin/env bash
# Lädt die öffentlichen Views nach $1 (Standard: /tmp/sfdata). Nur lesen.
D="${1:-/tmp/sfdata}"; mkdir -p "$D"
H='apikey: sb_publishable_bCwTOeE2vb4kQtRtag4rUQ_jIKtESZb'; B='https://iapkocqgclfjcxrlkghw.supabase.co/rest/v1'
for v in v_settings v_players v_athletes v_races v_results v_ownership v_player_race_pts v_owned_pts v_standings v_transfers v_draft_picks; do
  curl -sf "$B/$v?select=*" -H "$H" -o "$D/$v.json" || { echo "Fehler beim Laden von $v" >&2; exit 1; }
done
echo "$D"
