#!/bin/sh
# Startet CamGrid zum Testen direkt aus diesem Ordner - ohne Installation.
# Konfiguration und Protokolle landen unter test/lokal.
set -eu

VERZ=$(cd "$(dirname "$0")" && pwd)
cd "$VERZ"

PYTHON=$(command -v python3 || command -v python || true)
[ -n "$PYTHON" ] || { echo "Python 3 wird benoetigt."; exit 1; }

mkdir -p test/lokal
export CAMGRID_CONFIG="$VERZ/test/lokal/config.json"
export CAMGRID_GO2RTC_YAML="$VERZ/test/lokal/go2rtc.yaml"
export CAMGRID_WEB="$VERZ/web/public"
export PYTHONIOENCODING=utf-8

echo "CamGrid startet lokal ..."
echo "  Verwaltung : http://127.0.0.1:8080"
echo "  Anzeige    : http://127.0.0.1:1984/?monitor=1"
echo "  Anmeldung  : admin / camgrid  (bitte bald aendern)"
echo "  Daten      : $VERZ/test/lokal"
echo "  Beenden mit Strg+C"
echo

exec "$PYTHON" -m app.dienst --mit-server --config "$CAMGRID_CONFIG" --port 8080
