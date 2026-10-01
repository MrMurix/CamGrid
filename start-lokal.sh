#!/bin/sh
# Starts CamGrid for testing straight from this folder - without installing.
# Configuration and logs end up under test/lokal.
set -eu

VERZ=$(cd "$(dirname "$0")" && pwd)
cd "$VERZ"

PYTHON=$(command -v python3 || command -v python || true)
[ -n "$PYTHON" ] || { echo "Python 3 is required."; exit 1; }

mkdir -p test/lokal
export CAMGRID_CONFIG="$VERZ/test/lokal/config.json"
export CAMGRID_GO2RTC_YAML="$VERZ/test/lokal/go2rtc.yaml"
export CAMGRID_WEB="$VERZ/web/public"
export PYTHONIOENCODING=utf-8

echo "CamGrid is starting locally ..."
echo "  Admin   : http://127.0.0.1:8080"
echo "  Display : http://127.0.0.1:1984/?monitor=1"
echo "  Login   : admin / camgrid  (please change it soon)"
echo "  Data    : $VERZ/test/lokal"
echo "  Stop with Ctrl+C"
echo

exec "$PYTHON" -m app.dienst --mit-server --config "$CAMGRID_CONFIG" --port 8080
