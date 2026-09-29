#!/bin/sh
# CamGrid - Kiosk-Anzeige
#
# Richtet die Bildschirme ein, startet pro Monitor ein Chromium-Fenster im
# Kiosk-Modus auf der Anzeigeseite des Streaming-Dienstes und ueberwacht die
# Fenster dauerhaft.
#
# Aufruf: kiosk.sh [--einmal] [--neustart] [--help]
#
# Erfahrungswerte, die hier bewusst so umgesetzt sind:
#   - Nach dem Systemstart ist eine Wartezeit notwendig, sonst haengt Chromium
#     im Zustand D (disk sleep) auf der SD-Karte und zeigt leere weisse Fenster.
#   - --use-angle=gl ist zwingend, sonst sind die Videobilder gruen/lila.
#   - 4K laeuft an diesen Geraeten nur mit 30 Hz und ueberlastet den Pi;
#     Standard ist daher 1920x1080 mit 60 Hz.
#   - Der Zeitstempel in der Adresse verhindert, dass Chromium eine alte
#     Seitenfassung aus dem Zwischenspeicher zeigt.
#   - "exit_type" muss vor dem Start von "Crashed" auf "Normal" gesetzt werden,
#     sonst startet Chromium nach hartem Ausschalten mit leerem Fenster.
set -u

CONFDATEI="/etc/camgrid/config.json"
KIOSKINFO="/opt/camgrid/app/kioskinfo.py"
ANZEIGEPORT="1984"        # wird aus der Konfiguration ueberschrieben
ANZEIGEURL="http://127.0.0.1:$ANZEIGEPORT/"

BREITE_STANDARD="1920"
HOEHE_STANDARD="1080"
BILDRATE_STANDARD="60"

XWARTEZEIT="120"          # Sekunden, bis der X-Server da sein muss
DIENSTWARTEZEIT="180"     # Sekunden, bis der Streaming-Dienst antworten muss
BOOTWARTEZEIT="15"        # zusaetzliche Wartezeit direkt nach dem Systemstart
STARTSCHWELLE="180"       # bis zu dieser Systemlaufzeit gilt es als Systemstart
PRUEFTAKT="30"            # Sekunden zwischen zwei Pruefungen
MINDESTVERBINDUNGEN="2"   # TCP-Verbindungen je Fenster zum Streaming-Dienst
MAXFEHLVERSUCHE="2"       # danach wird das Fenster neu gestartet
SPERRWARTEZEIT="30"       # Sekunden, die auf eine belegte Sperre gewartet wird

BETRIEBSART="ueberwachen"
LOGDATEI="/dev/null"
SPERRDATEI=""
PIDDATEI=""
TMPVERZ=""
PLANDATEI=""
CHROMIUM=""
PIDZUORDNUNG="ja"
FENSTERANZAHL="0"

DISPLAY="${DISPLAY:-:0}"
export DISPLAY

# Wird das Skript aus einem Dienst heraus gestartet (z. B. "Anzeige neu starten"
# im Dashboard), fehlt die Berechtigung für den X-Server. Die liegt im
# Heimverzeichnis des angemeldeten Benutzers.
if [ -z "${XAUTHORITY:-}" ]; then
    for _kandidat in "$HOME/.Xauthority" "/home/$(id -un)/.Xauthority"; do
        if [ -r "$_kandidat" ]; then
            XAUTHORITY="$_kandidat"
            export XAUTHORITY
            break
        fi
    done
fi

# ---------------------------------------------------------------- Parameter --

hilfe() {
    printf '%s\n' \
"CamGrid - Kiosk-Anzeige" \
"" \
"Aufruf:" \
"  kiosk.sh [Optionen]" \
"" \
"Optionen:" \
"  --einmal     Fenster starten, danach nicht ueberwachen" \
"  --neustart   Laufende Fenster beenden und neu starten" \
"  --help       Diese Hilfe anzeigen"
}

NEUSTART="nein"
while [ $# -gt 0 ]; do
    case "$1" in
        --einmal)   BETRIEBSART="einmal"; shift ;;
        --neustart) NEUSTART="ja"; shift ;;
        --help|-h)  hilfe; exit 0 ;;
        *)
            printf 'Unbekannte Option: %s (siehe --help)\n' "$1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------- Protokoll --

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

# ------------------------------------------------------------------- Sperre --

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
        protokoll "WARNUNG Keine beschreibbare Sperrdatei gefunden - Mehrfachstart wird nicht verhindert."
        return 0
    fi
    if ! command -v flock >/dev/null 2>&1; then
        protokoll "WARNUNG flock fehlt - Mehrfachstart wird nicht verhindert."
        return 0
    fi
    # Vorab pruefen: ein fehlgeschlagenes exec wuerde die Shell beenden.
    if ! : >> "$SPERRDATEI" 2>/dev/null; then
        protokoll "WARNUNG Sperrdatei $SPERRDATEI nicht beschreibbar - Mehrfachstart wird nicht verhindert."
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
            protokoll "Sperre $SPERRDATEI ist belegt - es wird bis zu $SPERRWARTEZEIT s gewartet."
            gemeldet="ja"
        fi
        if [ "$gewartet" -ge "$SPERRWARTEZEIT" ]; then
            protokoll "FEHLER Sperre $SPERRDATEI nach $SPERRWARTEZEIT s noch belegt - Abbruch. Erzwingen mit: kiosk.sh --neustart"
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

# ------------------------------------------------------- Beenden alter Teile --

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
        protokoll "Vorherige Instanz (PID $alt) wird beendet."
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

# Muster stehen bewusst in Klammern, damit pkill/pgrep nicht die eigene
# Befehlszeile trifft: "[k]amerawand-fenster" passt nicht auf sich selbst.
beende_alle_fenster() {
    if ! pgrep -f '[k]amerawand-fenster' >/dev/null 2>&1; then
        return 0
    fi
    protokoll "Laufende Anzeigefenster werden beendet."
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
    # Reste desselben Fensters aufraeumen; ($|[^0-9]) trennt Monitor 1 von 10.
    pkill -f "[k]amerawand-fenster$nr(\$|[^0-9])" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------- Warten --

warte_auf_x() {
    gewartet="0"
    while [ "$gewartet" -lt "$XWARTEZEIT" ]; do
        if xset q >/dev/null 2>&1; then
            protokoll "X-Server erreichbar (DISPLAY=$DISPLAY)."
            return 0
        fi
        sleep 1
        gewartet=$((gewartet + 1))
    done
    protokoll "FEHLER X-Server nach $XWARTEZEIT s nicht erreichbar (DISPLAY=$DISPLAY) - Abbruch."
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
        protokoll "Systemstart erkannt (Laufzeit ${laufzeit} s) - ${BOOTWARTEZEIT} s Wartezeit, sonst haengt Chromium im Zustand D auf der SD-Karte."
        sleep "$BOOTWARTEZEIT"
    fi
}

warte_auf_dienst() {
    if ! command -v curl >/dev/null 2>&1; then
        protokoll "WARNUNG curl fehlt - der Streaming-Dienst kann nicht geprueft werden."
        return 0
    fi
    gewartet="0"
    code="000"
    while [ "$gewartet" -lt "$DIENSTWARTEZEIT" ]; do
        code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$ANZEIGEURL" 2>/dev/null || printf '000')
        if [ "$code" = "200" ]; then
            protokoll "Streaming-Dienst erreichbar ($ANZEIGEURL)."
            return 0
        fi
        sleep 2
        gewartet=$((gewartet + 2))
    done
    protokoll "FEHLER Streaming-Dienst $ANZEIGEURL nach $DIENSTWARTEZEIT s nicht erreichbar (letzte Antwort: HTTP $code) - Abbruch."
    exit 1
}

# --------------------------------------------------------- Monitorangaben ----

feld() {
    # feld "<zeile>" "<schluessel>" -> Wert oder leer
    printf '%s' "$1" | tr ';' '\n' | sed -n "s/^$2=//p" | head -n 1
}

notfallplan() {
    protokoll "WARNUNG Notfallwerte werden verwendet: ein Monitor ${BREITE_STANDARD}x${HOEHE_STANDARD}@${BILDRATE_STANDARD}."
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
            protokoll "WARNUNG $KIOSKINFO konnte nicht ausgefuehrt werden."
            : > "$rohdatei"
        fi
    else
        protokoll "WARNUNG $KIOSKINFO oder python3 fehlt."
    fi

    if ! grep -q '^MONITOR=' "$rohdatei" 2>/dev/null; then
        protokoll "WARNUNG Keine Monitorangaben aus $KIOSKINFO erhalten (Konfiguration: $CONFDATEI)."
        notfallplan > "$rohdatei"
    fi

    printf '%s' "$rohdatei"
}

verbundene_ausgaenge() {
    if command -v xrandr >/dev/null 2>&1; then
        xrandr --query 2>/dev/null | awk '/ connected/ {printf "%s ", $1}'
    fi
}

# Baut aus den Monitorangaben den Anzeigeplan:
#   <nr>|<ausgang>|<x>|<breite>|<hoehe>|<bildrate>
# Fehlt der Ausgang in der Konfiguration, wird der naechste freie verbundene
# Ausgang in der Reihenfolge von xrandr genommen. X wird fortlaufend aus den
# Breiten gebildet, damit es zur Anordnung mit --right-of passt.
erstelle_plan() {
    rohdatei="$1"
    PLANDATEI="$TMPVERZ/plan.txt"
    : > "$PLANDATEI"

    frei=$(verbundene_ausgaenge)
    if [ -z "$frei" ]; then
        protokoll "WARNUNG xrandr meldet keine verbundenen Ausgaenge."
    else
        protokoll "Verbundene Ausgaenge: $frei"
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
            ''|*[!0-9]*) protokoll "WARNUNG Zeile ohne gueltige Monitornummer wird uebergangen: $zeile"; continue ;;
        esac
        case "${breite:-}" in ''|*[!0-9]*) breite="$BREITE_STANDARD" ;; esac
        case "${hoehe:-}" in ''|*[!0-9]*) hoehe="$HOEHE_STANDARD" ;; esac
        case "${rate:-}" in ''|*[!0-9]*) rate="$BILDRATE_STANDARD" ;; esac

        if [ -z "${aus:-}" ]; then
            aus=$(printf '%s' "$frei" | awk '{print $1}')
            if [ -z "$aus" ]; then
                protokoll "WARNUNG Monitor $nr: kein Ausgang konfiguriert und kein freier verbundener Ausgang vorhanden."
            else
                protokoll "Monitor $nr: kein Ausgang konfiguriert, es wird $aus verwendet."
                frei=$(printf '%s' "$frei" | awk '{ $1=""; sub(/^ +/, ""); print }')
            fi
        else
            frei=$(printf '%s' "$frei" | tr ' ' '\n' | sed '/^$/d' | grep -Fxv "$aus" | tr '\n' ' ' || true)
        fi

        if [ -n "${xkonf:-}" ] && [ "$xkonf" != "$xnaechste" ]; then
            protokoll "Hinweis Monitor $nr: X=$xkonf aus der Konfiguration weicht von der Anordnung ab, es gilt X=$xnaechste."
        fi

        printf '%s|%s|%s|%s|%s|%s\n' "$nr" "${aus:-}" "$xnaechste" "$breite" "$hoehe" "$rate" >> "$PLANDATEI"
        xnaechste=$((xnaechste + breite))
        FENSTERANZAHL=$((FENSTERANZAHL + 1))
    done < "$rohdatei"

    if [ "$FENSTERANZAHL" -eq 0 ]; then
        protokoll "WARNUNG Anzeigeplan ist leer - Notfallwerte werden verwendet."
        printf '1|%s|0|%s|%s|%s\n' \
            "$(printf '%s' "$(verbundene_ausgaenge)" | awk '{print $1}')" \
            "$BREITE_STANDARD" "$HOEHE_STANDARD" "$BILDRATE_STANDARD" "$ANZEIGEPORT" > "$PLANDATEI"
        FENSTERANZAHL="1"
    fi
    protokoll "Anzeigeplan: $FENSTERANZAHL Fenster."
}

# ------------------------------------------------------------- Bildschirme ---

richte_bildschirme_ein() {
    if ! command -v xrandr >/dev/null 2>&1; then
        protokoll "WARNUNG xrandr fehlt - die Bildschirme werden nicht eingestellt."
        return 0
    fi

    vorher=""
    while IFS='|' read -r nr aus x breite hoehe rate; do
        if [ -z "$aus" ]; then
            protokoll "WARNUNG Monitor $nr: kein Ausgang - xrandr wird uebersprungen."
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
            protokoll "Monitor $nr: Ausgang $aus auf ${modus}@${rate} gesetzt (X=$x)."
        # shellcheck disable=SC2086
        elif xrandr --output "$aus" --mode "$modus" $lage >/dev/null 2>&1; then
            protokoll "WARNUNG Monitor $nr: Bildrate $rate am Ausgang $aus nicht moeglich, ${modus} mit Standardrate gesetzt."
        else
            protokoll "WARNUNG Monitor $nr: ${modus}@${rate} am Ausgang $aus nicht moeglich - vorhandene Einstellung bleibt. Hinweis: 4K laeuft hier nur mit 30 Hz und ueberlastet das Geraet."
        fi
        vorher="$aus"
    done < "$PLANDATEI"
}

schalte_bildschirmschoner_aus() {
    if ! command -v xset >/dev/null 2>&1; then
        protokoll "WARNUNG xset fehlt - Bildschirmschoner bleibt aktiv."
        return 0
    fi
    if xset s off -dpms s noblank >/dev/null 2>&1; then
        protokoll "Bildschirmschoner und Energiesparen abgeschaltet."
    else
        xset s off >/dev/null 2>&1 || true
        xset -dpms >/dev/null 2>&1 || true
        xset s noblank >/dev/null 2>&1 || true
        protokoll "Bildschirmschoner abgeschaltet (einzelne Aufrufe)."
    fi
}

# ---------------------------------------------------------------- Chromium ---

finde_chromium() {
    for kandidat in chromium chromium-browser /usr/bin/chromium /usr/bin/chromium-browser; do
        if command -v "$kandidat" >/dev/null 2>&1; then
            command -v "$kandidat"
            return 0
        fi
    done
    return 1
}

# Chromium startet nach hartem Ausschalten mit leerem Fenster, wenn im Profil
# noch "exit_type":"Crashed" steht.
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
        --use-angle=gl \
        --window-position="$x,0" \
        --window-size="$breite,$hoehe" \
        "http://127.0.0.1:$ANZEIGEPORT/?monitor=$nr&v=$stempel" \
        </dev/null >/dev/null 2>&1 &
    neuepid=$!

    eval "PID_$nr=\$neuepid"
    eval "FEHLER_$nr=0"
    protokoll "Monitor $nr: Fenster gestartet (PID $neuepid, Position ${x},0, Groesse ${breite}x${hoehe})."
}

starte_alle_fenster() {
    while IFS='|' read -r nr aus x breite hoehe rate; do
        starte_fenster "$nr" "$x" "$breite" "$hoehe"
        sleep 2
    done < "$PLANDATEI"
}

# --------------------------------------------------------------- Ueberwachung -

# Gibt PID und alle Nachkommen aus (ein einziger ps-Abzug als Grundlage).
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

# Zaehlt hergestellte TCP-Verbindungen des Fensters zum Streaming-Dienst.
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
        protokoll "WARNUNG ss fehlt - es wird nur geprueft, ob die Fenster laufen."
        PIDZUORDNUNG="aus"
    fi
    protokoll "Dauerueberwachung beginnt (Pruefung alle ${PRUEFTAKT} s, mindestens ${MINDESTVERBINDUNGEN} Verbindungen je Fenster)."

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
                    protokoll "WARNUNG ss liefert keine Prozesszuordnung - es wird die Gesamtzahl der Verbindungen geprueft."
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
                grund="Prozess laeuft nicht"
            elif [ "$PIDZUORDNUNG" = "ja" ]; then
                anzahl=$(zaehle_verbindungen "$pid" "$psdatei" "$ssdatei")
                if [ "$anzahl" -lt "$MINDESTVERBINDUNGEN" ]; then
                    inordnung="nein"
                    grund="nur $anzahl Verbindung(en) zu 127.0.0.1:$ANZEIGEPORT"
                fi
            elif [ "$PIDZUORDNUNG" = "gesamt" ]; then
                noetig=$((MINDESTVERBINDUNGEN * FENSTERANZAHL))
                if [ "$gesamt" -lt "$noetig" ]; then
                    inordnung="nein"
                    grund="insgesamt nur $gesamt von $noetig erwarteten Verbindungen"
                fi
            fi

            if [ "$inordnung" = "ja" ]; then
                eval "FEHLER_$nr=0"
            else
                fehl=$((fehl + 1))
                eval "FEHLER_$nr=\$fehl"
                protokoll "WARNUNG Monitor $nr: $grund (Fehlversuch $fehl von $MAXFEHLVERSUCHE)."
                if [ "$fehl" -ge "$MAXFEHLVERSUCHE" ]; then
                    protokoll "Monitor $nr wird neu gestartet."
                    beende_einzelfenster "$nr" "$pid"
                    starte_fenster "$nr" "$x" "$breite" "$hoehe"
                fi
            fi
        done < "$PLANDATEI"
    done
}

# ------------------------------------------------------------------- Ablauf --

waehle_logdatei
waehle_sperrdatei

protokoll "Start (Betriebsart: $BETRIEBSART, Neustart: $NEUSTART)."

if [ "$NEUSTART" = "ja" ]; then
    # Erst die alte Instanz beenden, damit die Sperre frei wird.
    beende_alte_instanz
    beende_alle_fenster
fi

sperre_belegen
trap 'aufraeumen' EXIT
trap 'protokoll "Signal empfangen - Ende."; exit 0' INT TERM
schreibe_pidkennung

TMPVERZ=$(mktemp -d 2>/dev/null || printf '%s' "/tmp/camgrid-kiosk.$$")
mkdir -p "$TMPVERZ" 2>/dev/null || true
if [ ! -d "$TMPVERZ" ]; then
    protokoll "FEHLER Arbeitsverzeichnis konnte nicht angelegt werden - Abbruch."
    exit 1
fi

CHROMIUM=$(finde_chromium || true)
if [ -z "$CHROMIUM" ]; then
    protokoll "FEHLER Chromium nicht gefunden (weder chromium noch chromium-browser) - Abbruch."
    exit 1
fi

PROFILBASIS="${HOME:-/tmp}/.config/camgrid"
mkdir -p "$PROFILBASIS" 2>/dev/null || true

warte_auf_x
warte_nach_systemstart
warte_auf_dienst

ROHDATEI=$(lies_monitorangaben)
erstelle_plan "$ROHDATEI"

richte_bildschirme_ein
schalte_bildschirmschoner_aus

beende_alle_fenster
starte_alle_fenster

if [ "$BETRIEBSART" = "einmal" ]; then
    protokoll "Betriebsart --einmal: keine Ueberwachung, Ende."
    exit 0
fi

ueberwache
