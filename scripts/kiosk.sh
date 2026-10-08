#!/bin/sh
# CamGrid - kiosk display
#
# Sets up the screens, starts one Chromium window per monitor in kiosk mode on
# the display page of the streaming service and keeps watching the windows.
#
# Usage: kiosk.sh [--einmal] [--neustart] [--help]
#
# Lessons learned that are implemented here on purpose:
#   - After a system start a waiting time is required, otherwise Chromium hangs
#     in state D (disk sleep) on the SD card and shows empty white windows.
#   - On X11 --use-angle=gl is mandatory, otherwise the video images are
#     green and purple. Under Wayland the same flag keeps the GPU process
#     from starting at all, so there Chromium keeps its own default.
#   - 4K runs on these devices only at 30 Hz and overloads the Pi; the default
#     is therefore 1920x1080 at 60 Hz.
#   - The timestamp in the address keeps Chromium from showing an old version
#     of the page from its cache.
#   - "exit_type" must be changed from "Crashed" to "Normal" before the start,
#     otherwise Chromium comes up with an empty window after a hard power-off.
set -u

CONFDATEI="/etc/camgrid/config.json"
KIOSKINFO="/opt/camgrid/app/kioskinfo.py"
ANZEIGEPORT="1984"        # overwritten from the configuration
ANZEIGEURL="http://127.0.0.1:$ANZEIGEPORT/"

BREITE_STANDARD="1920"
HOEHE_STANDARD="1080"
BILDRATE_STANDARD="60"

XWARTEZEIT="120"          # seconds until the X server must be there
DIENSTWARTEZEIT="180"     # seconds until the streaming service must answer
BOOTWARTEZEIT="15"        # extra waiting time right after a system start
STARTSCHWELLE="180"       # up to this uptime it counts as a system start
PRUEFTAKT="30"            # seconds between two checks
MINDESTVERBINDUNGEN="2"   # TCP connections per window to the streaming service
MAXFEHLVERSUCHE="2"       # after this many failures the window is restarted
SPERRWARTEZEIT="30"       # seconds to wait for a lock held by someone else

BETRIEBSART="ueberwachen"
LOGDATEI="/dev/null"
SPERRDATEI=""
PIDDATEI=""
TMPVERZ=""
PLANDATEI=""
CHROMIUM=""
GRAFIKFLAG=""            # decided at the start, see grafik_waehlen
GRAFIKWECHSEL="nein"     # the fallback is only tried once
NEUSTARTGESAMT="0"
PIDZUORDNUNG="ja"
FENSTERANZAHL="0"

DISPLAY="${DISPLAY:-:0}"
export DISPLAY

# When the script is started from a service (for example "restart display" in
# the dashboard), the permission for the X server is missing. It lives in the
# home directory of the logged-in user.
if [ -z "${XAUTHORITY:-}" ]; then
    for _kandidat in "$HOME/.Xauthority" "/home/$(id -un)/.Xauthority"; do
        if [ -r "$_kandidat" ]; then
            XAUTHORITY="$_kandidat"
            export XAUTHORITY
            break
        fi
    done
fi

# -------------------------------------------------------------- parameters --

hilfe() {
    printf '%s\n' \
"CamGrid - kiosk display" \
"" \
"Usage:" \
"  kiosk.sh [options]" \
"" \
"Options:" \
"  --einmal     Start the windows, then do not watch them" \
"  --neustart   Stop running windows and start them again" \
"  --help       Show this help"
}

NEUSTART="nein"
while [ $# -gt 0 ]; do
    case "$1" in
        --einmal)   BETRIEBSART="einmal"; shift ;;
        --neustart) NEUSTART="ja"; shift ;;
        --help|-h)  hilfe; exit 0 ;;
        *)
            printf 'Unknown option: %s (see --help)\n' "$1" >&2
            exit 1
            ;;
    esac
done

# ----------------------------------------------------------------- logging --

waehle_logdatei() {
    for kandidat in /var/log/camgrid/kiosk.log \
                    "${HOME:-/tmp}/camgrid-kiosk.log" \
                    /tmp/camgrid-kiosk.log; do
        verz=$(dirname "$kandidat")
        if [ -w "$kandidat" ]; then
            LOGDATEI="$kandidat"
            return 0
        fi
        if [ ! -e "$kandidat" ] && [ -d "$verz" ] && [ -w "$verz" ]; then
            LOGDATEI="$kandidat"
            return 0
        fi
    done
    LOGDATEI="/dev/null"
}

protokoll() {
    zeit=$(date '+%Y-%m-%d %H:%M:%S')
    if ! printf '%s kiosk[%s] %s\n' "$zeit" "$$" "$1" >> "$LOGDATEI" 2>/dev/null; then
        printf '%s kiosk[%s] %s\n' "$zeit" "$$" "$1"
    fi
}

# -------------------------------------------------------------------- lock --

waehle_sperrdatei() {
    for kandidat in /run/lock/camgrid-kiosk.lock \
                    "${HOME:-/tmp}/.camgrid-kiosk.lock" \
                    /tmp/camgrid-kiosk.lock; do
        verz=$(dirname "$kandidat")
        if [ -w "$kandidat" ] || { [ ! -e "$kandidat" ] && [ -d "$verz" ] && [ -w "$verz" ]; }; then
            SPERRDATEI="$kandidat"
            PIDDATEI="${kandidat%.lock}.pid"
            return 0
        fi
    done
    SPERRDATEI=""
    PIDDATEI=""
}

sperre_belegen() {
    if [ -z "$SPERRDATEI" ]; then
        protokoll "WARNING No writable lock file found - a second start is not prevented."
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        protokoll "WARNING flock is missing - a second start is not prevented."
        return 0
    fi
    # Check first: a failed exec would end the shell.
    if ! : >> "$SPERRDATEI" 2>/dev/null; then
        protokoll "WARNING Lock file $SPERRDATEI is not writable - a second start is not prevented."
        return 0
    fi
    exec 9>>"$SPERRDATEI"

    gewartet="0"
    gemeldet="nein"
    while :; do
        if flock -n 9; then
            return 0
        fi
        if [ "$gemeldet" = "nein" ]; then
            protokoll "Lock $SPERRDATEI is held - waiting up to $SPERRWARTEZEIT s."
            gemeldet="ja"
        fi
        if [ "$gewartet" -ge "$SPERRWARTEZEIT" ]; then
            protokoll "ERROR Lock $SPERRDATEI still held after $SPERRWARTEZEIT s - aborting. Force it with: kiosk.sh --neustart"
            exit 1
        fi
        sleep 2
        gewartet=$((gewartet + 2))
    done
}

schreibe_pidkennung() {
    if [ -n "$PIDDATEI" ]; then
        printf '%s\n' "$$" > "$PIDDATEI" 2>/dev/null || true
    fi
}

aufraeumen() {
    if [ -n "$PIDDATEI" ] && [ -f "$PIDDATEI" ]; then
        eigen=$(head -n 1 "$PIDDATEI" 2>/dev/null || true)
        if [ "${eigen:-}" = "$$" ]; then
            rm -f "$PIDDATEI"
        fi
    fi
    if [ -n "$TMPVERZ" ] && [ -d "$TMPVERZ" ]; then
        rm -rf "$TMPVERZ"
    fi
}

# ------------------------------------------------------- stop older parts ---

beende_alte_instanz() {
    [ -n "$PIDDATEI" ] || return 0
    [ -f "$PIDDATEI" ] || return 0

    alt=$(head -n 1 "$PIDDATEI" 2>/dev/null || true)
    case "${alt:-}" in
        ''|*[!0-9]*) rm -f "$PIDDATEI"; return 0 ;;
    esac
    if [ "$alt" = "$$" ]; then
        return 0
    fi
    if kill -0 "$alt" 2>/dev/null; then
        protokoll "Stopping the previous instance (PID $alt)."
        kill "$alt" 2>/dev/null || true
        versuch="0"
        while [ "$versuch" -lt 10 ] && kill -0 "$alt" 2>/dev/null; do
            sleep 1
            versuch=$((versuch + 1))
        done
        kill -9 "$alt" 2>/dev/null || true
    fi
    rm -f "$PIDDATEI"
}

# The patterns are bracketed on purpose, so that pkill/pgrep do not match
# their own command line: "[k]amerawand-fenster" does not match itself.
beende_alle_fenster() {
    if ! pgrep -f '[k]amerawand-fenster' >/dev/null 2>&1; then
        return 0
    fi
    protokoll "Stopping running display windows."
    pkill -f '[k]amerawand-fenster' >/dev/null 2>&1 || true
    versuch="0"
    while [ "$versuch" -lt 10 ] && pgrep -f '[k]amerawand-fenster' >/dev/null 2>&1; do
        sleep 1
        versuch=$((versuch + 1))
    done
    pkill -9 -f '[k]amerawand-fenster' >/dev/null 2>&1 || true
}

beende_einzelfenster() {
    nr="$1"
    pid="$2"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        versuch="0"
        while [ "$versuch" -lt 8 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 1
            versuch=$((versuch + 1))
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    # Clean up leftovers of the same window; ($|[^0-9]) keeps monitor 1 and 10 apart.
    pkill -f "[k]amerawand-fenster$nr(\$|[^0-9])" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------- waiting --

warte_auf_x() {
    gewartet="0"
    while [ "$gewartet" -lt "$XWARTEZEIT" ]; do
        if xset q >/dev/null 2>&1; then
            protokoll "X server reachable (DISPLAY=$DISPLAY)."
            return 0
        fi
        sleep 1
        gewartet=$((gewartet + 1))
    done
    protokoll "ERROR X server not reachable after $XWARTEZEIT s (DISPLAY=$DISPLAY) - aborting."
    exit 1
}

warte_nach_systemstart() {
    laufzeit="0"
    if [ -r /proc/uptime ]; then
        laufzeit=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || printf '0')
    fi
    case "${laufzeit:-}" in
        ''|*[!0-9]*) laufzeit="0" ;;
    esac
    if [ "$laufzeit" -lt "$STARTSCHWELLE" ]; then
        protokoll "System start detected (uptime ${laufzeit} s) - waiting ${BOOTWARTEZEIT} s, otherwise Chromium hangs in state D on the SD card."
        sleep "$BOOTWARTEZEIT"
    fi
}

warte_auf_dienst() {
    if ! command -v curl >/dev/null 2>&1; then
        protokoll "WARNING curl is missing - the streaming service cannot be checked."
        return 0
    fi
    gewartet="0"
    code="000"
    while [ "$gewartet" -lt "$DIENSTWARTEZEIT" ]; do
        code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$ANZEIGEURL" 2>/dev/null || printf '000')
        if [ "$code" = "200" ]; then
            protokoll "Streaming service reachable ($ANZEIGEURL)."
            return 0
        fi
        sleep 2
        gewartet=$((gewartet + 2))
    done
    protokoll "ERROR Streaming service $ANZEIGEURL not reachable after $DIENSTWARTEZEIT s (last answer: HTTP $code) - aborting."
    exit 1
}

# ----------------------------------------------------------- monitor data ----

feld() {
    # feld "<line>" "<key>" -> value or empty
    printf '%s' "$1" | tr ';' '\n' | sed -n "s/^$2=//p" | head -n 1
}

notfallplan() {
    protokoll "WARNING Fallback values are used: one monitor ${BREITE_STANDARD}x${HOEHE_STANDARD}@${BILDRATE_STANDARD}."
    printf 'MONITOR=1;AUSGANG=;X=0;BREITE=%s;HOEHE=%s;BILDRATE=%s;PORT=%s\n' \
        "$BREITE_STANDARD" "$HOEHE_STANDARD" "$BILDRATE_STANDARD" "$ANZEIGEPORT"
}

lies_monitorangaben() {
    rohdatei="$TMPVERZ/monitore.txt"
    : > "$rohdatei"

    if [ -f "$KIOSKINFO" ] && command -v python3 >/dev/null 2>&1; then
        if CAMGRID_CONFIG="$CONFDATEI" python3 "$KIOSKINFO" > "$rohdatei" 2>/dev/null; then
            :
        else
            protokoll "WARNING $KIOSKINFO could not be run."
            : > "$rohdatei"
        fi
    else
        protokoll "WARNING $KIOSKINFO or python3 is missing."
    fi

    if ! grep -q '^MONITOR=' "$rohdatei" 2>/dev/null; then
        protokoll "WARNING No monitor data received from $KIOSKINFO (configuration: $CONFDATEI)."
        notfallplan > "$rohdatei"
    fi

    printf '%s' "$rohdatei"
}

verbundene_ausgaenge() {
    if command -v xrandr >/dev/null 2>&1; then
        xrandr --query 2>/dev/null | awk '/ connected/ {printf "%s ", $1}'
    fi
}

# Builds the display plan from the monitor data:
#   <no>|<output>|<x>|<width>|<height>|<refresh rate>
# If the output is missing in the configuration, the next free connected
# output in xrandr order is taken. X is derived from the widths one after
# another, so that it matches the arrangement with --right-of.
erstelle_plan() {
    rohdatei="$1"
    PLANDATEI="$TMPVERZ/plan.txt"
    : > "$PLANDATEI"

    frei=$(verbundene_ausgaenge)
    if [ -z "$frei" ]; then
        protokoll "WARNING xrandr reports no connected outputs."
    else
        protokoll "Connected outputs: $frei"
    fi

    xnaechste="0"
    FENSTERANZAHL="0"
    while IFS= read -r zeile; do
        case "$zeile" in
            MONITOR=*) ;;
            *) continue ;;
        esac

        nr=$(feld "$zeile" MONITOR)
        aus=$(feld "$zeile" AUSGANG)
        breite=$(feld "$zeile" BREITE)
        hoehe=$(feld "$zeile" HOEHE)
        rate=$(feld "$zeile" BILDRATE)
        xkonf=$(feld "$zeile" X)
        port=$(feld "$zeile" PORT)
        case "${port:-}" in
            ''|*[!0-9]*) : ;;
            *) ANZEIGEPORT="$port"; ANZEIGEURL="http://127.0.0.1:$ANZEIGEPORT/" ;;
        esac

        case "${nr:-}" in
            ''|*[!0-9]*) protokoll "WARNING Line without a valid monitor number is skipped: $zeile"; continue ;;
        esac
        case "${breite:-}" in ''|*[!0-9]*) breite="$BREITE_STANDARD" ;; esac
        case "${hoehe:-}" in ''|*[!0-9]*) hoehe="$HOEHE_STANDARD" ;; esac
        case "${rate:-}" in ''|*[!0-9]*) rate="$BILDRATE_STANDARD" ;; esac

        if [ -z "${aus:-}" ]; then
            aus=$(printf '%s' "$frei" | awk '{print $1}')
            if [ -z "$aus" ]; then
                protokoll "WARNING Monitor $nr: no output configured and no free connected output available."
            else
                protokoll "Monitor $nr: no output configured, $aus is used."
                frei=$(printf '%s' "$frei" | awk '{ $1=""; sub(/^ +/, ""); print }')
            fi
        else
            frei=$(printf '%s' "$frei" | tr ' ' '\n' | sed '/^$/d' | grep -Fxv "$aus" | tr '\n' ' ' || true)
        fi

        if [ -n "${xkonf:-}" ] && [ "$xkonf" != "$xnaechste" ]; then
            protokoll "Note Monitor $nr: X=$xkonf from the configuration differs from the arrangement, X=$xnaechste is used."
        fi

        printf '%s|%s|%s|%s|%s|%s\n' "$nr" "${aus:-}" "$xnaechste" "$breite" "$hoehe" "$rate" >> "$PLANDATEI"
        xnaechste=$((xnaechste + breite))
        FENSTERANZAHL=$((FENSTERANZAHL + 1))
    done < "$rohdatei"

    if [ "$FENSTERANZAHL" -eq 0 ]; then
        protokoll "WARNING The display plan is empty - fallback values are used."
        printf '1|%s|0|%s|%s|%s\n' \
            "$(printf '%s' "$(verbundene_ausgaenge)" | awk '{print $1}')" \
            "$BREITE_STANDARD" "$HOEHE_STANDARD" "$BILDRATE_STANDARD" "$ANZEIGEPORT" > "$PLANDATEI"
        FENSTERANZAHL="1"
    fi
    protokoll "Display plan: $FENSTERANZAHL window(s)."
}

# ------------------------------------------------------------------ screens --

richte_bildschirme_ein() {
    if ! command -v xrandr >/dev/null 2>&1; then
        protokoll "WARNING xrandr is missing - the screens are not configured."
        return 0
    fi

    vorher=""
    while IFS='|' read -r nr aus x breite hoehe rate; do
        if [ -z "$aus" ]; then
            protokoll "WARNING Monitor $nr: no output - xrandr is skipped."
            continue
        fi
        modus="${breite}x${hoehe}"
        if [ -z "$vorher" ]; then
            lage="--pos ${x}x0 --primary"
        else
            lage="--right-of $vorher"
        fi

        # shellcheck disable=SC2086
        if xrandr --output "$aus" --mode "$modus" --rate "$rate" $lage >/dev/null 2>&1; then
            protokoll "Monitor $nr: output $aus set to ${modus}@${rate} (X=$x)."
        # shellcheck disable=SC2086
        elif xrandr --output "$aus" --mode "$modus" $lage >/dev/null 2>&1; then
            protokoll "WARNING Monitor $nr: refresh rate $rate not possible on output $aus, ${modus} set with the default rate."
        else
            protokoll "WARNING Monitor $nr: ${modus}@${rate} not possible on output $aus - the existing setting stays. Note: 4K runs here only at 30 Hz and overloads the device."
        fi
        vorher="$aus"
    done < "$PLANDATEI"
}

schalte_bildschirmschoner_aus() {
    if ! command -v xset >/dev/null 2>&1; then
        protokoll "WARNING xset is missing - the screen saver stays active."
        return 0
    fi
    if xset s off -dpms s noblank >/dev/null 2>&1; then
        protokoll "Screen saver and power saving switched off."
    else
        xset s off >/dev/null 2>&1 || true
        xset -dpms >/dev/null 2>&1 || true
        xset s noblank >/dev/null 2>&1 || true
        protokoll "Screen saver switched off (one call at a time)."
    fi
}

# ----------------------------------------------------------------- Chromium --

finde_chromium() {
    for kandidat in chromium chromium-browser /usr/bin/chromium /usr/bin/chromium-browser; do
        if command -v "$kandidat" >/dev/null 2>&1; then
            command -v "$kandidat"
            return 0
        fi
    done
    return 1
}

# Chromium comes up with an empty window after a hard power-off when the
# profile still holds "exit_type":"Crashed".
normalisiere_profil() {
    einstellungen="$1/Default/Preferences"
    [ -f "$einstellungen" ] || return 0
    zwischen="$einstellungen.neu"
    if sed -e 's/"exit_type":"Crashed"/"exit_type":"Normal"/g' \
           -e 's/"exit_type": *"Crashed"/"exit_type": "Normal"/g' \
           -e 's/"exited_cleanly":false/"exited_cleanly":true/g' \
           -e 's/"exited_cleanly": *false/"exited_cleanly": true/g' \
           "$einstellungen" > "$zwischen" 2>/dev/null; then
        mv -f "$zwischen" "$einstellungen" 2>/dev/null || rm -f "$zwischen"
    else
        rm -f "$zwischen"
    fi
}

starte_fenster() {
    nr="$1"
    x="$2"
    breite="$3"
    hoehe="$4"

    profil="$PROFILBASIS/camgrid-fenster$nr"
    mkdir -p "$profil" 2>/dev/null || true
    normalisiere_profil "$profil"

    stempel=$(date +%s)
    "$CHROMIUM" \
        --user-data-dir="$profil" \
        --class="camgrid-fenster$nr" \
        --kiosk \
        --noerrdialogs \
        --disable-infobars \
        --no-first-run \
        --disable-session-crashed-bubble \
        --autoplay-policy=no-user-gesture-required \
        --password-store=basic \
        --disable-features=Translate \
        $GRAFIKFLAG \
        --window-position="$x,0" \
        --window-size="$breite,$hoehe" \
        "http://127.0.0.1:$ANZEIGEPORT/?monitor=$nr&v=$stempel" \
        </dev/null >/dev/null 2>&1 &
    neuepid=$!

    eval "PID_$nr=\$neuepid"
    eval "FEHLER_$nr=0"
    protokoll "Monitor $nr: window started (PID $neuepid, position ${x},0, size ${breite}x${hoehe})."
}

# Chromium's graphics backend depends on the session. On X11 the videos come
# out green and purple unless ANGLE uses desktop GL. Under Wayland (labwc on
# Raspberry Pi OS, reached through Xwayland) that very flag makes the GPU
# process die on start: the window stays black and the page is never loaded.
grafik_waehlen() {
    _wl="${WAYLAND_DISPLAY:-}"
    if [ -z "$_wl" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        for _sock in "$XDG_RUNTIME_DIR"/wayland-*; do
            if [ -S "$_sock" ]; then
                _wl="$_sock"
                break
            fi
        done
    fi
    if [ -n "$_wl" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
        GRAFIKFLAG=""
        protokoll "Wayland session - Chromium keeps its own graphics backend."
    else
        GRAFIKFLAG="--use-angle=gl"
        protokoll "X11 session - Chromium starts with --use-angle=gl."
    fi
}

# If no window comes up, the other backend is worth a try.
grafik_umschalten() {
    if [ -n "$GRAFIKFLAG" ]; then
        GRAFIKFLAG=""
        protokoll "WARNING No window comes up - trying again without --use-angle=gl."
    else
        GRAFIKFLAG="--use-angle=gl"
        protokoll "WARNING No window comes up - trying again with --use-angle=gl."
    fi
}

starte_alle_fenster() {
    while IFS='|' read -r nr aus x breite hoehe rate; do
        starte_fenster "$nr" "$x" "$breite" "$hoehe"
        sleep 2
    done < "$PLANDATEI"
}

# --------------------------------------------------------------- monitoring --

# Prints the PID and all of its descendants (based on a single ps snapshot).
nachkommen() {
    awk -v wurzel="$1" '
        { kinder[NR]=$1; elter[$1]=$2; anzahl=NR }
        END {
            gehoert[wurzel]=1
            geaendert=1
            while (geaendert) {
                geaendert=0
                for (i=1; i<=anzahl; i++) {
                    p=kinder[i]
                    if (!(p in gehoert) && (elter[p] in gehoert)) {
                        gehoert[p]=1
                        geaendert=1
                    }
                }
            }
            for (p in gehoert) printf "%s ", p
        }' "$2"
}

# Counts established TCP connections from the window to the streaming service.
zaehle_verbindungen() {
    hauptpid="$1"
    psdatei="$2"
    ssdatei="$3"

    pids=$(nachkommen "$hauptpid" "$psdatei")
    if [ -z "$pids" ]; then
        printf '0'
        return 0
    fi
    awk -v liste="$pids" '
        BEGIN {
            anzahl=split(liste, teile, " ")
            for (i=1; i<=anzahl; i++) if (teile[i] != "") ist[teile[i]]=1
        }
        {
            rest=$0
            while (match(rest, /pid=[0-9]+/)) {
                p=substr(rest, RSTART+4, RLENGTH-4)
                if (p in ist) { treffer++; break }
                rest=substr(rest, RSTART+RLENGTH)
            }
        }
        END { printf "%d", treffer+0 }' "$ssdatei"
}

ueberwache() {
    if ! command -v ss >/dev/null 2>&1; then
        protokoll "WARNING ss is missing - only the presence of the windows is checked."
        PIDZUORDNUNG="aus"
    fi
    protokoll "Continuous monitoring starts (check every ${PRUEFTAKT} s, at least ${MINDESTVERBINDUNGEN} connections per window)."

    ssdatei="$TMPVERZ/ss.txt"
    psdatei="$TMPVERZ/ps.txt"

    while :; do
        sleep "$PRUEFTAKT"

        : > "$ssdatei"
        if [ "$PIDZUORDNUNG" != "aus" ]; then
            ss -tnp state established 2>/dev/null \
                | grep -F "127.0.0.1:$ANZEIGEPORT" > "$ssdatei" 2>/dev/null || : > "$ssdatei"
            if [ -s "$ssdatei" ] && ! grep -q 'pid=' "$ssdatei" 2>/dev/null; then
                if [ "$PIDZUORDNUNG" = "ja" ]; then
                    protokoll "WARNING ss does not report the owning process - the total number of connections is checked instead."
                    PIDZUORDNUNG="gesamt"
                fi
            fi
        fi
        : > "$psdatei"
        ps -eo pid=,ppid= > "$psdatei" 2>/dev/null || : > "$psdatei"

        gesamt=$(wc -l < "$ssdatei" 2>/dev/null | tr -d ' ')
        case "${gesamt:-}" in
            ''|*[!0-9]*) gesamt="0" ;;
        esac

        while IFS='|' read -r nr aus x breite hoehe rate; do
            eval "pid=\${PID_$nr:-}"
            eval "fehl=\${FEHLER_$nr:-0}"
            inordnung="ja"
            grund=""

            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
                inordnung="nein"
                grund="process is not running"
            elif [ "$PIDZUORDNUNG" = "ja" ]; then
                anzahl=$(zaehle_verbindungen "$pid" "$psdatei" "$ssdatei")
                if [ "$anzahl" -lt "$MINDESTVERBINDUNGEN" ]; then
                    inordnung="nein"
                    grund="only $anzahl connection(s) to 127.0.0.1:$ANZEIGEPORT"
                fi
            elif [ "$PIDZUORDNUNG" = "gesamt" ]; then
                noetig=$((MINDESTVERBINDUNGEN * FENSTERANZAHL))
                if [ "$gesamt" -lt "$noetig" ]; then
                    inordnung="nein"
                    grund="only $gesamt of $noetig expected connections in total"
                fi
            fi

            if [ "$inordnung" = "ja" ]; then
                eval "FEHLER_$nr=0"
            else
                fehl=$((fehl + 1))
                eval "FEHLER_$nr=\$fehl"
                protokoll "WARNING Monitor $nr: $grund (failure $fehl of $MAXFEHLVERSUCHE)."
                if [ "$fehl" -ge "$MAXFEHLVERSUCHE" ]; then
                    NEUSTARTGESAMT=$((NEUSTARTGESAMT + 1))
                    if [ "$NEUSTARTGESAMT" -ge 2 ] && [ "$GRAFIKWECHSEL" = "nein" ]; then
                        grafik_umschalten
                        GRAFIKWECHSEL="ja"
                    fi
                    protokoll "Monitor $nr is being restarted."
                    beende_einzelfenster "$nr" "$pid"
                    starte_fenster "$nr" "$x" "$breite" "$hoehe"
                fi
            fi
        done < "$PLANDATEI"
    done
}

# --------------------------------------------------------------------- flow --

waehle_logdatei
waehle_sperrdatei

if [ "$BETRIEBSART" = "einmal" ]; then _art="once"; else _art="watch"; fi
if [ "$NEUSTART" = "ja" ]; then _neustart="yes"; else _neustart="no"; fi
protokoll "Start (mode: $_art, restart: $_neustart)."

if [ "$NEUSTART" = "ja" ]; then
    # Stop the old instance first, so that the lock becomes free.
    beende_alte_instanz
    beende_alle_fenster
fi

sperre_belegen
trap 'aufraeumen' EXIT
trap 'protokoll "Signal received - end."; exit 0' INT TERM
schreibe_pidkennung

TMPVERZ=$(mktemp -d 2>/dev/null || printf '%s' "/tmp/camgrid-kiosk.$$")
mkdir -p "$TMPVERZ" 2>/dev/null || true
if [ ! -d "$TMPVERZ" ]; then
    protokoll "ERROR The work directory could not be created - aborting."
    exit 1
fi

CHROMIUM=$(finde_chromium || true)
if [ -z "$CHROMIUM" ]; then
    protokoll "ERROR Chromium not found (neither chromium nor chromium-browser) - aborting."
    exit 1
fi

PROFILBASIS="${HOME:-/tmp}/.config/camgrid"
mkdir -p "$PROFILBASIS" 2>/dev/null || true

warte_auf_x
grafik_waehlen
warte_nach_systemstart
warte_auf_dienst

ROHDATEI=$(lies_monitorangaben)
erstelle_plan "$ROHDATEI"

richte_bildschirme_ein
schalte_bildschirmschoner_aus

beende_alle_fenster
starte_alle_fenster

if [ "$BETRIEBSART" = "einmal" ]; then
    protokoll "Mode --einmal: no monitoring, end."
    exit 0
fi

ueberwache
