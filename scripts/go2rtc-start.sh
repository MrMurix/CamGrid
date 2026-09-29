#!/bin/sh
# CamGrid - Streaming-Dienst starten.
#
# Erzeugt erst die go2rtc-Konfiguration aus config.json (das macht auf Linux
# systemd per ExecStartPre) und startet dann go2rtc. Wird von launchd auf
# macOS gebraucht, weil es dort kein ExecStartPre gibt. Laesst sich auch von
# Hand aufrufen, wenn es gar keine Dienstverwaltung gibt.
set -eu

ZIELVERZ="${CAMGRID_ZIEL:-/opt/camgrid}"
YAML="${CAMGRID_GO2RTC_YAML:-/var/lib/camgrid/go2rtc.yaml}"
PROGRAMM="$ZIELVERZ/bin/go2rtc"

PYTHON="${CAMGRID_PYTHON:-}"
if [ -z "$PYTHON" ]; then
    PYTHON=$(command -v python3 || command -v python || true)
fi

export CAMGRID_GO2RTC_YAML="$YAML"
export PYTHONUNBUFFERED=1

if [ -n "$PYTHON" ] && [ -f "$ZIELVERZ/app/streams.py" ]; then
    "$PYTHON" "$ZIELVERZ/app/streams.py" || \
        printf 'Warnung: go2rtc.yaml konnte nicht erzeugt werden - vorhandene Fassung wird verwendet.\n' >&2
else
    printf 'Warnung: Python 3 oder app/streams.py fehlt - go2rtc.yaml wird nicht erneuert.\n' >&2
fi

[ -x "$PROGRAMM" ] || { printf 'Fehler: %s fehlt oder ist nicht ausfuehrbar.\n' "$PROGRAMM" >&2; exit 1; }
[ -f "$YAML" ] || { printf 'Fehler: %s fehlt.\n' "$YAML" >&2; exit 1; }

cd "$(dirname "$YAML")"
exec "$PROGRAMM" -config "$YAML"
