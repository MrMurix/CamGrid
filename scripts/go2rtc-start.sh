#!/bin/sh
# CamGrid - start the streaming service.
#
# First creates the go2rtc configuration from config.json (on Linux systemd
# does that via ExecStartPre), then starts go2rtc. Needed by launchd on macOS,
# because there is no ExecStartPre there. Can also be called by hand when there
# is no service manager at all.
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
        printf 'Warning: could not create go2rtc.yaml - the existing version is used.\n' >&2
else
    printf 'Warning: Python 3 or app/streams.py is missing - go2rtc.yaml is not refreshed.\n' >&2
fi

[ -x "$PROGRAMM" ] || { printf 'Error: %s is missing or not executable.\n' "$PROGRAMM" >&2; exit 1; }
[ -f "$YAML" ] || { printf 'Error: %s is missing.\n' "$YAML" >&2; exit 1; }

cd "$(dirname "$YAML")"
exec "$PROGRAMM" -config "$YAML"
