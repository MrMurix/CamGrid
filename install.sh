#!/bin/sh
# CamGrid - Installationsskript fuer Linux (Debian/Raspberry Pi OS/Ubuntu,
# Fedora, Arch, openSUSE) und macOS.
#
# Richtet Admin-Server, Streaming-Dienst (go2rtc) und - falls eine grafische
# Oberflaeche vorhanden ist - die Kiosk-Anzeige ein.
#
# Aufruf: sudo ./install.sh [--user NAME] [--no-kiosk] [--port N] [--help]
set -eu

ZIELVERZ="/opt/camgrid"
CONFVERZ="/etc/camgrid"
LOGVERZ="/var/log/camgrid"
DATAVERZ="/var/lib/camgrid"
SUDOERSDATEI="/etc/sudoers.d/camgrid"
SYSTEMDVERZ="/etc/systemd/system"
GO2RTC_REPO="AlexxIT/go2rtc"
GO2RTC_FESTVERSION="v1.9.9"

ADMINPORT="8080"
ANZEIGEPORT="1984"
DIENSTBENUTZER=""
KIOSK="ja"

# Feste Startzugangsdaten. Sie sind absichtlich bekannt und muessen beim
# ersten Anmelden geaendert werden - siehe Hinweis in der Zusammenfassung.
STANDARDBENUTZER="admin"
STANDARDPASSWORT="camgrid"

SKRIPTVERZ=$(cd "$(dirname "$0")" && pwd)
QUELLVERZ="$SKRIPTVERZ"        # hier liegen vendor/ und web/
TROCKEN="nein"                 # --dry-run: nur zeigen, nichts aendern

SYSTEM="unbekannt"             # linux oder macos
PAKETVERWALTER="keiner"        # apt, dnf, pacman, zypper, brew, keiner
HAT_SYSTEMD="nein"
HAT_LAUNCHD="nein"
HAT_GRAFIK="unbekannt"
DIENSTART="keiner"             # systemd, launchd oder keiner
CHROMIUM=""
GO2RTC_BEREIT="nein"
FEHLENDE_PAKETE=""
PROJEKTVERSION="unbekannt"
SCHRITT="Start"

# ---------------------------------------------------------------- Ausgaben ---

meldung() {
    printf '[camgrid] %s\n' "$1"
}

warnung() {
    printf '[camgrid] Warnung: %s\n' "$1" >&2
}

fehler() {
    printf '[camgrid] Fehler: %s\n' "$1" >&2
    exit 1
}

# Wird bei jedem unerwarteten Abbruch aufgerufen (set -e oder Strg+C), damit
# der Nutzer weiss, wo es stehen geblieben ist und wie er weitermacht.
abbruchhinweis() {
    code="$?"
    if [ "$code" != "0" ]; then
        printf '\n[camgrid] Abgebrochen im Schritt: %s\n' "$SCHRITT" >&2
        printf '[camgrid] Das Skript ist mehrfach ausfuehrbar - einfach erneut starten.\n' >&2
        printf '[camgrid] Alles wieder entfernen: sudo %s/uninstall.sh\n' "$SKRIPTVERZ" >&2
    fi
}

schritt() {
    SCHRITT="$1"
}

lies_projektversion() {
    for kandidat in "$SKRIPTVERZ/VERSION" "$ZIELVERZ/VERSION"; do
        if [ -r "$kandidat" ]; then
            PROJEKTVERSION=$(head -n 1 "$kandidat" | tr -d ' \t\r\n')
            [ -n "$PROJEKTVERSION" ] || PROJEKTVERSION="unbekannt"
            return 0
        fi
    done
    PROJEKTVERSION="unbekannt"
}

hilfe() {
    printf '%s\n' \
"CamGrid - Installation (Version $PROJEKTVERSION)" \
"" \
"Aufruf:" \
"  sudo ./install.sh [Optionen]              (Linux, Raspberry Pi OS, macOS)" \
"" \
"Optionen:" \
"  --user NAME        Dienstbenutzer (Standard: Benutzer der grafischen Sitzung)" \
"  --no-kiosk         Nur Dienste einrichten, keinen Chromium-Autostart anlegen" \
"  --port N           Port des Admin-Servers (Standard: 8080)" \
"  --dry-run          Nur anzeigen, was getan wuerde - aendert nichts" \
"  --deinstallieren   Hinweis zum Entfernen anzeigen (siehe uninstall.sh)" \
"  --version          Projektversion anzeigen" \
"  --help             Diese Hilfe anzeigen" \
"" \
"Das Skript ist mehrfach ausfuehrbar. Eine vorhandene Konfiguration unter" \
"$CONFVERZ/config.json wird niemals ueberschrieben." \
"" \
"Ohne grafische Oberflaeche (Server) entfaellt die Kiosk-Anzeige, die Dienste" \
"werden trotzdem eingerichtet. Auf macOS werden launchd-Dienste statt systemd" \
"verwendet und es gibt keinen Kiosk-Autostart."
}

deinstallationshinweis() {
    printf '%s\n' \
"CamGrid - Deinstallation" \
"" \
"Diese Aufgabe uebernimmt uninstall.sh:" \
"  sudo $SKRIPTVERZ/uninstall.sh              (Konfiguration wird erfragt)" \
"  sudo $SKRIPTVERZ/uninstall.sh --behalten   (Konfiguration behalten)" \
"  sudo $SKRIPTVERZ/uninstall.sh --alles      (auch $CONFVERZ loeschen)" \
"" \
"Auf Windows: powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall"
}

# --------------------------------------------------------------- Parameter ---

lies_projektversion

while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            [ $# -ge 2 ] || fehler "--user benoetigt einen Benutzernamen."
            DIENSTBENUTZER="$2"
            shift 2
            ;;
        --user=*)
            DIENSTBENUTZER="${1#--user=}"
            shift
            ;;
        --dry-run|--probelauf)
            TROCKEN="ja"
            shift
            ;;
        --no-kiosk|--ohne-kiosk)
            KIOSK="nein"
            shift
            ;;
        --port)
            [ $# -ge 2 ] || fehler "--port benoetigt eine Portnummer."
            ADMINPORT="$2"
            shift 2
            ;;
        --port=*)
            ADMINPORT="${1#--port=}"
            shift
            ;;
        --deinstallieren|--uninstall)
            deinstallationshinweis
            exit 0
            ;;
        --version|-V)
            printf 'CamGrid %s\n' "$PROJEKTVERSION"
            exit 0
            ;;
        --help|-h)
            hilfe
            exit 0
            ;;
        *)
            fehler "Unbekannte Option: $1 (siehe --help)"
            ;;
    esac
done

case "$ADMINPORT" in
    ''|*[!0-9]*) fehler "Ungueltiger Admin-Port: $ADMINPORT" ;;
esac
if [ "$ADMINPORT" -lt 1 ] || [ "$ADMINPORT" -gt 65535 ]; then
    fehler "Admin-Port ausserhalb des gueltigen Bereichs: $ADMINPORT"
fi
if [ "$ADMINPORT" = "$ANZEIGEPORT" ]; then
    fehler "Der Admin-Port darf nicht $ANZEIGEPORT sein - den benutzt die Anzeige."
fi

trap abbruchhinweis EXIT

# ------------------------------------------------------------ Vorbedingungen -

erkenne_system() {
    schritt "Betriebssystem erkennen"
    kern=$(uname -s 2>/dev/null || printf 'unbekannt')
    case "$kern" in
        Linux)  SYSTEM="linux" ;;
        Darwin) SYSTEM="macos" ;;
        *)
            if [ "$TROCKEN" = "ja" ]; then
                # Damit sich der Probelauf auch unter Git Bash oder WSL ansehen
                # laesst, wird dort Linux angenommen.
                SYSTEM="linux"
                meldung "[Probelauf] Unbekannter Systemkern '$kern' - es wird Linux angenommen."
            else
                fehler "Nicht unterstuetztes Betriebssystem: $kern. Fuer Windows bitte install.ps1 verwenden."
            fi
            ;;
    esac

    beschreibung="$kern"
    if [ "$SYSTEM" = "linux" ] && [ -r /etc/os-release ]; then
        # In einer Subshell einlesen, damit ID und VERSION die eigenen
        # Variablen des Skripts nicht ueberschreiben.
        beschreibung=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
    elif [ "$SYSTEM" = "macos" ]; then
        beschreibung="macOS $(sw_vers -productVersion 2>/dev/null || printf 'unbekannt')"
    fi
    meldung "Betriebssystem: $beschreibung"

    if [ "$SYSTEM" = "macos" ] && [ "$KIOSK" = "ja" ]; then
        KIOSK="nein"
        meldung "macOS: kein Kiosk-Autostart (Hinweis zum Vollbild steht am Ende)."
    fi
}

pruefe_root() {
    schritt "Rechte pruefen"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Probelauf] Rechte werden nicht geprueft."
        return 0
    fi
    [ "$(id -u)" = "0" ] || fehler "Bitte mit Root-Rechten starten: sudo ./install.sh"
}

erkenne_dienstverwaltung() {
    schritt "Dienstverwaltung erkennen"
    if [ "$SYSTEM" = "macos" ]; then
        if command -v launchctl >/dev/null 2>&1; then
            HAT_LAUNCHD="ja"
            DIENSTART="launchd"
            meldung "Dienstverwaltung: launchd"
        else
            DIENSTART="keiner"
            warnung "launchctl fehlt - die Dienste werden nur eingerichtet, nicht gestartet."
        fi
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        HAT_SYSTEMD="ja"
        DIENSTART="systemd"
        meldung "Dienstverwaltung: systemd"
    elif command -v systemctl >/dev/null 2>&1; then
        warnung "systemd ist installiert, laeuft aber nicht (/run/systemd/system fehlt)."
    else
        warnung "Kein systemd gefunden - es werden keine Autostart-Dienste eingerichtet."
    fi

    if [ "$DIENSTART" = "keiner" ]; then
        warnung "Start dann von Hand: python3 $ZIELVERZ/app/dienst.py --mit-server --config $CONFVERZ/config.json"
    fi
}

erkenne_paketverwalter() {
    schritt "Paketverwaltung erkennen"
    for kandidat in apt-get dnf pacman zypper brew; do
        if command -v "$kandidat" >/dev/null 2>&1; then
            case "$kandidat" in
                apt-get) PAKETVERWALTER="apt" ;;
                *)       PAKETVERWALTER="$kandidat" ;;
            esac
            break
        fi
    done
    if [ "$SYSTEM" = "macos" ] && [ "$PAKETVERWALTER" != "brew" ]; then
        PAKETVERWALTER="keiner"
    fi
    case "$PAKETVERWALTER" in
        keiner)
            warnung "Keine bekannte Paketverwaltung gefunden (apt, dnf, pacman, zypper, brew)."
            warnung "Fehlende Programme werden nur genannt, nicht selbst installiert."
            ;;
        *)
            meldung "Paketverwaltung: $PAKETVERWALTER"
            ;;
    esac
}

ermittle_architektur() {
    schritt "Architektur erkennen"
    maschine=$(uname -m)
    if [ "$SYSTEM" = "macos" ]; then
        case "$maschine" in
            arm64|aarch64) GO2RTC_DATEI="go2rtc_mac_arm64" ;;
            x86_64|amd64)  GO2RTC_DATEI="go2rtc_mac_amd64" ;;
            *) fehler "Nicht unterstuetzte Architektur auf macOS: $maschine" ;;
        esac
    else
        case "$maschine" in
            aarch64|arm64)      GO2RTC_DATEI="go2rtc_linux_arm64" ;;
            armv7l|armv7|armhf) GO2RTC_DATEI="go2rtc_linux_arm" ;;
            armv6l)             GO2RTC_DATEI="go2rtc_linux_armv6" ;;
            x86_64|amd64)       GO2RTC_DATEI="go2rtc_linux_amd64" ;;
            *)
                fehler "Nicht unterstuetzte Architektur: $maschine (erwartet arm64, armv7, armv6 oder amd64)."
                ;;
        esac
    fi
    meldung "Architektur: $maschine -> $GO2RTC_DATEI"
}

# Auf einem Server ohne Bildschirm darf der Kiosk-Teil einfach entfallen -
# das ist kein Fehler.
erkenne_grafik() {
    schritt "Grafische Oberflaeche pruefen"
    if [ "$SYSTEM" = "macos" ]; then
        HAT_GRAFIK="ja"
        return 0
    fi

    HAT_GRAFIK="nein"
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        HAT_GRAFIK="ja"
    elif [ -n "$(ls /tmp/.X11-unix/ 2>/dev/null || true)" ]; then
        HAT_GRAFIK="ja"
    elif command -v Xorg >/dev/null 2>&1 || [ -x /usr/lib/xorg/Xorg ]; then
        HAT_GRAFIK="ja"
    elif command -v labwc >/dev/null 2>&1 || command -v wayfire >/dev/null 2>&1; then
        HAT_GRAFIK="ja"
    fi

    if [ "$HAT_GRAFIK" = "ja" ]; then
        meldung "Grafische Oberflaeche: vorhanden."
    else
        meldung "Grafische Oberflaeche: keine gefunden - Server-Betrieb."
        if [ "$KIOSK" = "ja" ]; then
            KIOSK="nein"
            meldung "Die Kiosk-Anzeige entfaellt daher. Die Anzeigeseite bleibt im Netz erreichbar."
        fi
    fi
}

# ------------------------------------------------------------ Dienstbenutzer -

# Heimatverzeichnis eines Benutzers; getent gibt es auf macOS nicht.
heimatverzeichnis() {
    benutzer="$1"
    heim=""
    if command -v getent >/dev/null 2>&1; then
        heim=$(getent passwd "$benutzer" 2>/dev/null | cut -d: -f6 || true)
    fi
    if [ -z "$heim" ] && command -v dscl >/dev/null 2>&1; then
        heim=$(dscl . -read "/Users/$benutzer" NFSHomeDirectory 2>/dev/null \
            | sed -n 's/^NFSHomeDirectory: //p' || true)
    fi
    if [ -z "$heim" ] && [ -r /etc/passwd ]; then
        heim=$(awk -F: -v b="$benutzer" '$1==b {print $6; exit}' /etc/passwd 2>/dev/null || true)
    fi
    printf '%s' "$heim"
}

ermittle_dienstbenutzer() {
    schritt "Dienstbenutzer ermitteln"
    if [ "$TROCKEN" = "ja" ]; then
        if [ -z "$DIENSTBENUTZER" ]; then DIENSTBENUTZER="$(id -un 2>/dev/null || echo pi)"; fi
        BENUTZERHEIM="${HOME:-/home/$DIENSTBENUTZER}"
        BENUTZERGRUPPE="$DIENSTBENUTZER"
        meldung "[Probelauf] Dienstbenutzer waere: $DIENSTBENUTZER"
        return 0
    fi
    if [ -n "$DIENSTBENUTZER" ]; then
        return 0
    fi

    # 1. Besitzer einer grafischen Sitzung
    if command -v loginctl >/dev/null 2>&1; then
        kandidat=$(loginctl list-sessions --no-legend 2>/dev/null \
            | awk '{print $3}' | grep -v '^root$' | head -n 1 || true)
        if [ -n "${kandidat:-}" ]; then
            DIENSTBENUTZER="$kandidat"
            return 0
        fi
    fi

    kandidat=$(who 2>/dev/null | awk '$2 ~ /^:[0-9]/ {print $1; exit}' || true)
    if [ -n "${kandidat:-}" ]; then
        DIENSTBENUTZER="$kandidat"
        return 0
    fi

    # 2. Aufrufender Benutzer
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        DIENSTBENUTZER="$SUDO_USER"
        return 0
    fi

    kandidat=$(logname 2>/dev/null || true)
    if [ -n "${kandidat:-}" ] && [ "$kandidat" != "root" ]; then
        DIENSTBENUTZER="$kandidat"
        return 0
    fi

    kandidat=$(who 2>/dev/null | awk '{print $1; exit}' || true)
    if [ -n "${kandidat:-}" ] && [ "$kandidat" != "root" ]; then
        DIENSTBENUTZER="$kandidat"
        return 0
    fi

    # 3. Erster regulaerer Benutzer des Systems
    if [ "$SYSTEM" = "macos" ]; then
        kandidat=$(dscl . -list /Users UniqueID 2>/dev/null \
            | awk '$2>=500 && $2<60000 {print $1; exit}' || true)
    else
        kandidat=$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd 2>/dev/null || true)
    fi
    if [ -n "${kandidat:-}" ]; then
        DIENSTBENUTZER="$kandidat"
        return 0
    fi

    # 4. Notfall auf einem reinen Server: eigenen Systembenutzer anlegen.
    if [ "$SYSTEM" = "linux" ] && command -v useradd >/dev/null 2>&1; then
        meldung "Kein regulaerer Benutzer gefunden - Systembenutzer 'camgrid' wird angelegt."
        useradd --system --create-home --home-dir /var/lib/camgrid-heim \
                --shell /bin/sh camgrid >/dev/null 2>&1 \
            || useradd -r -m -d /var/lib/camgrid-heim camgrid >/dev/null 2>&1 \
            || fehler "Benutzer 'camgrid' konnte nicht angelegt werden. Bitte --user NAME angeben."
        DIENSTBENUTZER="camgrid"
        return 0
    fi

    fehler "Dienstbenutzer nicht ermittelbar. Bitte mit --user NAME angeben."
}

pruefe_dienstbenutzer() {
    schritt "Dienstbenutzer pruefen"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Probelauf] Dienstbenutzer wird nicht geprueft."
        return 0
    fi
    id "$DIENSTBENUTZER" >/dev/null 2>&1 \
        || fehler "Benutzer '$DIENSTBENUTZER' existiert nicht."
    [ "$DIENSTBENUTZER" != "root" ] \
        || fehler "root ist als Dienstbenutzer nicht zulaessig. Bitte --user NAME angeben."
    BENUTZERGRUPPE=$(id -gn "$DIENSTBENUTZER")
    BENUTZERHEIM=$(heimatverzeichnis "$DIENSTBENUTZER")
    if [ -z "$BENUTZERHEIM" ] || [ ! -d "$BENUTZERHEIM" ]; then
        fehler "Heimatverzeichnis von '$DIENSTBENUTZER' nicht gefunden."
    fi
    meldung "Dienstbenutzer: $DIENSTBENUTZER (Gruppe $BENUTZERGRUPPE, Heim $BENUTZERHEIM)"
}

# ------------------------------------------------------------------- Pakete --

# Paketname zu einem Befehl - je Paketverwaltung unterschiedlich.
# Leere Ausgabe bedeutet: dafuer ist kein Paket bekannt.
paketname() {
    befehl="$1"
    case "$PAKETVERWALTER" in
        apt)
            case "$befehl" in
                python3) printf 'python3' ;;
                curl)    printf 'curl' ;;
                ffmpeg)  printf 'ffmpeg' ;;
                ss)      printf 'iproute2' ;;
                flock)   printf 'util-linux' ;;
                xset|xrandr) printf 'x11-xserver-utils' ;;
                scrot)   printf 'scrot' ;;
                unzip)   printf 'unzip' ;;
                chromium) printf 'chromium' ;;
            esac
            ;;
        dnf)
            case "$befehl" in
                python3) printf 'python3' ;;
                curl)    printf 'curl' ;;
                ffmpeg)  printf 'ffmpeg-free' ;;
                ss)      printf 'iproute' ;;
                flock)   printf 'util-linux-core' ;;
                xset)    printf 'xorg-x11-server-utils' ;;
                xrandr)  printf 'xrandr' ;;
                scrot)   printf 'scrot' ;;
                unzip)   printf 'unzip' ;;
                chromium) printf 'chromium' ;;
            esac
            ;;
        pacman)
            case "$befehl" in
                python3) printf 'python' ;;
                curl)    printf 'curl' ;;
                ffmpeg)  printf 'ffmpeg' ;;
                ss)      printf 'iproute2' ;;
                flock)   printf 'util-linux' ;;
                xset)    printf 'xorg-xset' ;;
                xrandr)  printf 'xorg-xrandr' ;;
                scrot)   printf 'scrot' ;;
                unzip)   printf 'unzip' ;;
                chromium) printf 'chromium' ;;
            esac
            ;;
        zypper)
            case "$befehl" in
                python3) printf 'python3' ;;
                curl)    printf 'curl' ;;
                ffmpeg)  printf 'ffmpeg' ;;
                ss)      printf 'iproute2' ;;
                flock)   printf 'util-linux' ;;
                xset)    printf 'xset' ;;
                xrandr)  printf 'xrandr' ;;
                scrot)   printf 'scrot' ;;
                unzip)   printf 'unzip' ;;
                chromium) printf 'chromium' ;;
            esac
            ;;
        brew)
            case "$befehl" in
                python3) printf 'python3' ;;
                curl)    printf 'curl' ;;
                ffmpeg)  printf 'ffmpeg' ;;
                unzip)   printf 'unzip' ;;
                chromium) printf 'chromium' ;;
            esac
            ;;
    esac
}

# Kann diese Paketverwaltung ohne Rueckfrage installieren?
kann_installieren() {
    case "$PAKETVERWALTER" in
        apt|dnf|pacman) return 0 ;;
        *)              return 1 ;;
    esac
}

installationsbefehl() {
    case "$PAKETVERWALTER" in
        apt)    printf 'sudo apt-get install -y' ;;
        dnf)    printf 'sudo dnf install -y' ;;
        pacman) printf 'sudo pacman -S --needed' ;;
        zypper) printf 'sudo zypper install -y' ;;
        brew)   printf 'brew install' ;;
        *)      printf 'mit der Paketverwaltung des Systems installieren:' ;;
    esac
}

LISTEN_AKTUELL="nein"

listen_aktualisieren() {
    [ "$LISTEN_AKTUELL" = "nein" ] || return 0
    LISTEN_AKTUELL="ja"
    case "$PAKETVERWALTER" in
        apt)
            meldung "Paketlisten werden aktualisiert ..."
            DEBIAN_FRONTEND=noninteractive apt-get update -qq \
                || warnung "apt-get update war nicht erfolgreich - Installation wird dennoch versucht."
            ;;
        pacman)
            meldung "Paketlisten werden aktualisiert ..."
            pacman -Sy --noconfirm >/dev/null 2>&1 \
                || warnung "pacman -Sy war nicht erfolgreich - Installation wird dennoch versucht."
            ;;
    esac
}

# Installiert das Paket zu einem Befehl. Rueckgabe 0 = Befehl ist nun da.
paket_installieren() {
    befehl="$1"
    paket=$(paketname "$befehl")
    if [ -z "$paket" ]; then
        return 1
    fi
    if ! kann_installieren; then
        merke_fehlendes_paket "$paket"
        return 1
    fi
    listen_aktualisieren
    meldung "Paket wird installiert: $paket"
    case "$PAKETVERWALTER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$paket" \
                >/dev/null 2>&1 || { merke_fehlendes_paket "$paket"; return 1; }
            ;;
        dnf)
            dnf install -y "$paket" >/dev/null 2>&1 \
                || { merke_fehlendes_paket "$paket"; return 1; }
            ;;
        pacman)
            pacman -S --noconfirm --needed "$paket" >/dev/null 2>&1 \
                || { merke_fehlendes_paket "$paket"; return 1; }
            ;;
    esac
    command -v "$befehl" >/dev/null 2>&1 || return 1
    return 0
}

merke_fehlendes_paket() {
    for vorhanden in $FEHLENDE_PAKETE; do
        [ "$vorhanden" != "$1" ] || return 0
    done
    FEHLENDE_PAKETE="$FEHLENDE_PAKETE $1"
}

finde_chromium() {
    for kandidat in chromium chromium-browser google-chrome chromium-freeworld \
                    /usr/bin/chromium /usr/bin/chromium-browser \
                    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
        if [ -x "$kandidat" ]; then
            printf '%s' "$kandidat"
            return 0
        fi
        if command -v "$kandidat" >/dev/null 2>&1; then
            command -v "$kandidat"
            return 0
        fi
    done
    return 1
}

installiere_pakete() {
    schritt "Pakete pruefen"
    if [ "$TROCKEN" = "ja" ]; then
        if kann_installieren; then
            meldung "[Probelauf] Fehlende Pakete wuerden mit $PAKETVERWALTER installiert."
        else
            meldung "[Probelauf] Fehlende Pakete wuerden nur genannt (Paketverwaltung: $PAKETVERWALTER)."
        fi
        return 0
    fi
    meldung "Programme werden geprueft ..."

    # Pflicht: ohne Python 3 laeuft nichts.
    if ! command -v python3 >/dev/null 2>&1; then
        paket_installieren python3 || true
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        paket=$(paketname python3)
        fehler "Python 3 fehlt. Bitte installieren: $(installationsbefehl) ${paket:-python3}"
    fi

    # Nuetzlich, aber nicht zwingend.
    for befehl in curl ffmpeg; do
        command -v "$befehl" >/dev/null 2>&1 && continue
        paket_installieren "$befehl" || true
        command -v "$befehl" >/dev/null 2>&1 \
            || warnung "'$befehl' fehlt. Ohne curl entfaellt das Nachladen, ohne ffmpeg die Umkodierung."
    done

    if [ "$KIOSK" != "ja" ]; then
        meldung "Ohne Kiosk-Anzeige werden Chromium und die X11-Werkzeuge nicht benoetigt."
        return 0
    fi

    # Nur fuer die Kiosk-Anzeige: X11-Werkzeuge und Chromium.
    for befehl in xset xrandr ss flock scrot; do
        command -v "$befehl" >/dev/null 2>&1 && continue
        paket_installieren "$befehl" || true
        command -v "$befehl" >/dev/null 2>&1 \
            || warnung "'$befehl' fehlt - die Kiosk-Anzeige arbeitet mit Einschraenkungen weiter."
    done

    CHROMIUM=$(finde_chromium || true)
    if [ -z "$CHROMIUM" ]; then
        paket_installieren chromium || true
        CHROMIUM=$(finde_chromium || true)
    fi
    if [ -z "$CHROMIUM" ] && [ "$PAKETVERWALTER" = "apt" ]; then
        # Auf aelteren Debian-Fassungen heisst das Paket anders.
        meldung "Paket wird installiert: chromium-browser"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            chromium-browser >/dev/null 2>&1 || true
        CHROMIUM=$(finde_chromium || true)
    fi
    if [ -z "$CHROMIUM" ]; then
        KIOSK="nein"
        merke_fehlendes_paket "chromium"
        warnung "Chromium ist nicht vorhanden - die Kiosk-Anzeige wird uebersprungen."
        warnung "Nach dem Nachinstallieren einfach install.sh erneut starten."
    else
        meldung "Chromium: $CHROMIUM"
    fi
}

# ------------------------------------------------------------- Verzeichnisse -

lege_verzeichnisse_an() {
    schritt "Verzeichnisse anlegen"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Probelauf] Verzeichnisse wuerden angelegt: $ZIELVERZ $CONFVERZ $LOGVERZ $DATAVERZ"
        return 0
    fi
    meldung "Verzeichnisse werden angelegt ..."

    mkdir -p "$ZIELVERZ" "$ZIELVERZ/bin" "$ZIELVERZ/web/public"
    mkdir -p "$CONFVERZ" "$LOGVERZ" "$DATAVERZ"

    chown root:"$(id -gn root 2>/dev/null || printf 'root')" "$ZIELVERZ" 2>/dev/null \
        || chown root "$ZIELVERZ" 2>/dev/null || true
    chmod 0755 "$ZIELVERZ"

    chown -R "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$CONFVERZ" "$LOGVERZ" "$DATAVERZ"
    chmod 0750 "$CONFVERZ"
    chmod 0755 "$LOGVERZ" "$DATAVERZ"

    # Protokolldatei der Kiosk-Anzeige vorbereiten
    if [ ! -f "$LOGVERZ/kiosk.log" ]; then
        : > "$LOGVERZ/kiosk.log"
    fi
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$LOGVERZ/kiosk.log"
    chmod 0644 "$LOGVERZ/kiosk.log"
}

kopiere_programmdateien() {
    schritt "Programmdateien kopieren"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Probelauf] Programmdateien wuerden nach $ZIELVERZ kopiert."
        return 0
    fi
    if [ "$SKRIPTVERZ" = "$ZIELVERZ" ]; then
        meldung "Programmdateien liegen bereits in $ZIELVERZ - kein Kopieren notwendig."
        return 0
    fi

    meldung "Programmdateien werden nach $ZIELVERZ kopiert ..."
    for verzeichnis in app scripts web config systemd; do
        if [ -d "$SKRIPTVERZ/$verzeichnis" ]; then
            mkdir -p "$ZIELVERZ/$verzeichnis"
            cp -a "$SKRIPTVERZ/$verzeichnis/." "$ZIELVERZ/$verzeichnis/"
        fi
    done

    for datei in install.sh uninstall.sh VERSION; do
        if [ -f "$SKRIPTVERZ/$datei" ]; then
            cp -a "$SKRIPTVERZ/$datei" "$ZIELVERZ/$datei"
        fi
    done

    chown -R root "$ZIELVERZ" 2>/dev/null || true
    find "$ZIELVERZ" -name '*.sh' -type f -exec chmod 0755 {} + 2>/dev/null || true
    find "$ZIELVERZ" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

    # app/streams.py legt anzeige.json neben die Anzeigeseite; dieses
    # Verzeichnis muss dem Dienstbenutzer gehoeren.
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$ZIELVERZ/web/public"
    chmod 0755 "$ZIELVERZ/web/public"
    if [ -f "$ZIELVERZ/web/public/anzeige.json" ]; then
        chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$ZIELVERZ/web/public/anzeige.json"
    fi
}

# -------------------------------------------------------------------- go2rtc -

ermittle_go2rtc_version() {
    version=""
    if command -v curl >/dev/null 2>&1; then
        version=$(curl -fsSL --max-time 15 \
            "https://api.github.com/repos/$GO2RTC_REPO/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name"' \
            | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//' -e 's/".*//' || true)
    fi
    case "${version:-}" in
        v[0-9]*) printf '%s' "$version" ;;
        *)
            warnung "Neueste go2rtc-Version nicht ermittelbar - Rueckfall auf $GO2RTC_FESTVERSION."
            printf '%s' "$GO2RTC_FESTVERSION"
            ;;
    esac
}

# Fragt nur, wenn eine Eingabe moeglich ist. Bei 'curl ... | sudo sh' gibt es
# kein Terminal - dann wird geladen, weil genau das gewuenscht ist.
frage_ja() {
    if [ ! -t 0 ]; then
        meldung "$1 (keine Eingabe moeglich - es wird geladen)"
        return 0
    fi
    printf '[camgrid] %s [J/n] ' "$1"
    read -r antwort || antwort=""
    case "$antwort" in
        n|N|nein|Nein|NEIN) return 1 ;;
        *) return 0 ;;
    esac
}

# Laedt go2rtc von GitHub. Fuer macOS liegt dort ein ZIP-Archiv.
lade_go2rtc_aus_netz() {
    ziel="$1"
    command -v curl >/dev/null 2>&1 || { warnung "curl fehlt - go2rtc kann nicht geladen werden."; return 1; }
    GO2RTC_VERSION=$(ermittle_go2rtc_version)
    zwischen="$ZIELVERZ/bin/go2rtc.neu.$$"
    rm -f "$zwischen" "$zwischen.zip"

    if [ "$SYSTEM" = "macos" ]; then
        quelle="https://github.com/$GO2RTC_REPO/releases/download/$GO2RTC_VERSION/$GO2RTC_DATEI.zip"
        meldung "go2rtc $GO2RTC_VERSION wird geladen: $quelle"
        if ! curl -fsSL --max-time 300 -o "$zwischen.zip" "$quelle"; then
            rm -f "$zwischen.zip"
            warnung "Download fehlgeschlagen: $quelle"
            return 1
        fi
        if ! command -v unzip >/dev/null 2>&1; then
            rm -f "$zwischen.zip"
            warnung "unzip fehlt - $GO2RTC_DATEI.zip kann nicht entpackt werden."
            return 1
        fi
        entpackt="$ZIELVERZ/bin/entpackt.$$"
        mkdir -p "$entpackt"
        if ! unzip -o -q "$zwischen.zip" -d "$entpackt" 2>/dev/null; then
            rm -rf "$entpackt" "$zwischen.zip"
            warnung "Archiv konnte nicht entpackt werden."
            return 1
        fi
        gefunden=$(find "$entpackt" -type f -name 'go2rtc*' | head -n 1)
        if [ -z "$gefunden" ]; then
            rm -rf "$entpackt" "$zwischen.zip"
            warnung "Im Archiv war kein go2rtc-Programm."
            return 1
        fi
        mv -f "$gefunden" "$zwischen"
        rm -rf "$entpackt" "$zwischen.zip"
    else
        quelle="https://github.com/$GO2RTC_REPO/releases/download/$GO2RTC_VERSION/$GO2RTC_DATEI"
        meldung "go2rtc $GO2RTC_VERSION wird geladen: $quelle"
        if ! curl -fsSL --max-time 300 -o "$zwischen" "$quelle"; then
            rm -f "$zwischen"
            warnung "Download fehlgeschlagen: $quelle"
            return 1
        fi
    fi

    chmod 0755 "$zwischen"
    if ! "$zwischen" --version >/dev/null 2>&1; then
        rm -f "$zwischen"
        warnung "Das geladene go2rtc laeuft auf diesem System nicht (falsche Architektur?)."
        return 1
    fi
    mv -f "$zwischen" "$ziel"
    chmod 0755 "$ziel"
    meldung "go2rtc installiert: $ziel"
    return 0
}

lade_go2rtc() {
    schritt "go2rtc einrichten"
    ziel="$ZIELVERZ/bin/go2rtc"
    mitgeliefert="$QUELLVERZ/vendor/go2rtc/$GO2RTC_DATEI"
    if [ -r "$QUELLVERZ/vendor/go2rtc/VERSION" ]; then
        GO2RTC_VERSION=$(head -n 1 "$QUELLVERZ/vendor/go2rtc/VERSION" | tr -d ' \t\r\n')
    else
        GO2RTC_VERSION="$GO2RTC_FESTVERSION"
    fi

    if [ "$TROCKEN" = "ja" ]; then
        if [ -r "$mitgeliefert" ]; then
            meldung "[Probelauf] go2rtc $GO2RTC_VERSION aus dem Projekt kopieren: $mitgeliefert -> $ziel"
        else
            meldung "[Probelauf] go2rtc fehlt im Projekt ($mitgeliefert) - es wuerde von GitHub geladen."
        fi
        GO2RTC_BEREIT="ja"
        return 0
    fi

    if [ -x "$ziel" ] && "$ziel" --version >/dev/null 2>&1; then
        meldung "go2rtc ist bereits installiert."
        GO2RTC_BEREIT="ja"
        return 0
    fi

    # Der Regelfall auf Linux: das Programm liegt im Projekt und wird nur
    # kopiert. Dadurch braucht die Installation kein Internet.
    if [ -r "$mitgeliefert" ]; then
        meldung "go2rtc $GO2RTC_VERSION wird aus dem Projekt installiert ($GO2RTC_DATEI) ..."
        cp -f "$mitgeliefert" "$ziel"
        chmod 0755 "$ziel"
        if ! "$ziel" --version >/dev/null 2>&1; then
            rm -f "$ziel"
            warnung "Das mitgelieferte go2rtc laeuft auf diesem System nicht (falsche Architektur?)."
        else
            meldung "go2rtc installiert: $ziel"
            GO2RTC_BEREIT="ja"
            return 0
        fi
    else
        warnung "go2rtc fuer dieses System liegt nicht im Projekt: $mitgeliefert"
        if [ "$SYSTEM" = "macos" ]; then
            warnung "Fuer macOS wird go2rtc nicht mitgeliefert (nur Linux und Windows)."
        fi
    fi

    if frage_ja "go2rtc jetzt von GitHub laden ($GO2RTC_DATEI)?"; then
        if lade_go2rtc_aus_netz "$ziel"; then
            GO2RTC_BEREIT="ja"
            return 0
        fi
    else
        meldung "Kein Download - die Installation wird ohne Streaming-Dienst abgeschlossen."
    fi

    GO2RTC_BEREIT="nein"
    warnung "Ohne go2rtc gibt es keine Videobilder. Die Verwaltung laeuft trotzdem."
    warnung "Nachtraeglich: Datei $GO2RTC_DATEI von https://github.com/$GO2RTC_REPO/releases"
    warnung "nach $ziel legen, ausfuehrbar machen (chmod +x) und install.sh erneut starten."
}

lade_weboberflaeche() {
    schritt "Anzeigebausteine bereitstellen"
    # video-rtc.js und video-stream.js liegen im Projekt und werden nur kopiert.
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Probelauf] Wiedergabe-Bausteine kopieren nach $ZIELVERZ/web/public"
        return 0
    fi
    mkdir -p "$ZIELVERZ/web/public"
    for datei in video-rtc.js video-stream.js; do
        quelle="$QUELLVERZ/web/public/$datei"
        if [ -r "$quelle" ]; then
            cp -f "$quelle" "$ZIELVERZ/web/public/$datei"
            chmod 0644 "$ZIELVERZ/web/public/$datei"
        elif [ -s "$ZIELVERZ/web/public/$datei" ]; then
            warnung "$datei fehlt im Projekt - vorhandene Fassung bleibt."
        else
            fehler "$datei fehlt im Projekt ($quelle) - die Anzeige wuerde kein Bild zeigen."
        fi
    done
    meldung "Wiedergabe-Bausteine bereitgestellt."
}

# ------------------------------------------------------------- Konfiguration -

# Die Startkonfiguration wird von app/config.py erzeugt, damit es nur eine
# Quelle fuer den Aufbau der Datei gibt. Schlaegt das fehl, schreibt das
# Skript eine gleichwertige Minimalfassung selbst.
erzeuge_konfiguration_python() {
    ziel="$1"
    python3 - "$ZIELVERZ" "$ziel" "$ADMINPORT" "$ANZEIGEPORT" <<'PYENDE'
import sys

sys.path.insert(0, sys.argv[1])
from app import config as konfig

ziel, adminport, anzeigeport = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
daten = konfig.standard_konfiguration()
daten["dienste"]["admin_port"] = adminport
daten["dienste"]["go2rtc_port"] = anzeigeport
daten["monitore"][0]["spalten"] = 2
daten["monitore"][0]["zeilen"] = 2
daten["kameras"] = []
konfig.speichern(daten, ziel)
print("ok")
PYENDE
}

erzeuge_konfiguration_notfall() {
    ziel="$1"
    {
        printf '{\n'
        printf '  "version": 1,\n'
        printf '  "anlage": { "name": "CamGrid" },\n'
        printf '  "anzeige": {\n'
        printf '    "aufloesung": "1920x1080",\n'
        printf '    "bildrate": 60,\n'
        printf '    "rand": true,\n'
        printf '    "beschriftung": true,\n'
        printf '    "abstand": 14,\n'
        printf '    "hintergrund": "#0e1116"\n'
        printf '  },\n'
        printf '  "monitore": [\n'
        printf '    {\n'
        printf '      "id": 1,\n'
        printf '      "name": "Monitor 1",\n'
        printf '      "ausgang": "",\n'
        printf '      "spalten": 2,\n'
        printf '      "zeilen": 2,\n'
        printf '      "kacheln": []\n'
        printf '    }\n'
        printf '  ],\n'
        printf '  "kameras": [],\n'
        printf '  "zugang": {\n'
        printf '    "admin_benutzer": "%s",\n' "$STANDARDBENUTZER"
        printf '    "admin_passwort": "%s",\n' "$STANDARDPASSWORT"
        printf '    "anzeige_benutzer": "anzeige",\n'
        printf '    "anzeige_passwort": ""\n'
        printf '  },\n'
        printf '  "scan": {\n'
        printf '    "netz": "",\n'
        printf '    "zugangsdaten": [ { "benutzer": "admin", "passwort": "" } ]\n'
        printf '  },\n'
        printf '  "dienste": {\n'
        printf '    "go2rtc_port": %s,\n' "$ANZEIGEPORT"
        printf '    "admin_port": %s\n' "$ADMINPORT"
        printf '  }\n'
        printf '}\n'
    } > "$ziel"
}

# Setzt die festen Startzugangsdaten in einer frisch erzeugten Datei.
# Vorhandene Konfigurationen werden nie angefasst.
setze_standardzugang() {
    ziel="$1"
    python3 - "$ziel" "$STANDARDBENUTZER" "$STANDARDPASSWORT" <<'PYENDE'
import json, sys

pfad, benutzer, passwort = sys.argv[1], sys.argv[2], sys.argv[3]
with open(pfad, encoding="utf-8") as datei:
    daten = json.load(datei)
zugang = daten.setdefault("zugang", {})
zugang["admin_benutzer"] = benutzer
zugang["admin_passwort"] = passwort
with open(pfad, "w", encoding="utf-8") as datei:
    json.dump(daten, datei, indent=2, ensure_ascii=False)
    datei.write("\n")
PYENDE
}

erzeuge_konfiguration() {
    schritt "Konfiguration anlegen"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Probelauf] Konfiguration $CONFVERZ/config.json wuerde angelegt (vorhandene bleibt unveraendert)."
        meldung "[Probelauf] Startzugang waere: $STANDARDBENUTZER / $STANDARDPASSWORT"
        ADMINPASSWORT="$STANDARDPASSWORT"
        return 0
    fi
    ADMINPASSWORT=""
    ziel="$CONFVERZ/config.json"
    if [ -f "$ziel" ]; then
        meldung "Konfiguration $ziel ist vorhanden und bleibt unveraendert."
        if [ "$ADMINPORT" != "8080" ]; then
            warnung "--port $ADMINPORT wird nicht uebernommen: der Port steht in der vorhandenen Konfiguration."
        fi
        return 0
    fi

    meldung "Startkonfiguration wird angelegt: $ziel"
    if ! erzeuge_konfiguration_python "$ziel" >/dev/null 2>&1 || [ ! -s "$ziel" ]; then
        warnung "app/config.py konnte die Konfiguration nicht erzeugen - Minimalfassung wird geschrieben."
        rm -f "$ziel"
        erzeuge_konfiguration_notfall "$ziel"
    fi
    [ -s "$ziel" ] || fehler "Konfiguration $ziel konnte nicht geschrieben werden."

    # Feste Startzugangsdaten erzwingen, unabhaengig davon, was app/config.py
    # als Vorgabe mitbringt.
    if ! setze_standardzugang "$ziel" >/dev/null 2>&1; then
        warnung "Startzugangsdaten konnten nicht gesetzt werden - bitte $ziel pruefen."
    fi
    ADMINPASSWORT="$STANDARDPASSWORT"

    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$ziel"
    chmod 0600 "$ziel"
}

richte_schluesselbund_ein() {
    schritt "Schluesselbund pruefen"
    if [ "$TROCKEN" = "ja" ] || [ "$SYSTEM" != "linux" ]; then
        return 0
    fi
    ziel="$CONFVERZ/keyring.pw"
    if [ -f "$ziel" ]; then
        chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$ziel"
        chmod 0600 "$ziel"
        meldung "Passwortdatei des Schluesselbunds gefunden - Rechte auf 600 gesetzt."
    fi
}

# ------------------------------------------------------------------ Dienste --

ermittle_python() {
    PYTHON3=$(command -v python3 2>/dev/null || true)
    if [ -z "$PYTHON3" ]; then
        PYTHON3="/usr/bin/python3"
    fi
}

installiere_dienste_systemd() {
    meldung "systemd-Units werden installiert ..."
    for einheit in camgrid-admin.service camgrid-go2rtc.service; do
        if [ "$einheit" = "camgrid-go2rtc.service" ] && [ "$GO2RTC_BEREIT" != "ja" ]; then
            meldung "camgrid-go2rtc wird uebersprungen (go2rtc fehlt)."
            # Eine frueher installierte Unit wuerde sonst dauernd scheitern.
            if [ -f "$SYSTEMDVERZ/$einheit" ]; then
                systemctl disable --now "$einheit" >/dev/null 2>&1 || true
                rm -f "$SYSTEMDVERZ/$einheit"
            fi
            continue
        fi
        quelle="$SKRIPTVERZ/systemd/$einheit"
        if [ ! -f "$quelle" ]; then
            quelle="$ZIELVERZ/systemd/$einheit"
        fi
        [ -f "$quelle" ] || fehler "Unit-Datei fehlt: systemd/$einheit"
        sed -e "s|__DIENSTBENUTZER__|$DIENSTBENUTZER|g" \
            -e "s|__DIENSTGRUPPE__|$BENUTZERGRUPPE|g" \
            -e "s|__PYTHON__|$PYTHON3|g" \
            "$quelle" > "$SYSTEMDVERZ/$einheit"
        chmod 0644 "$SYSTEMDVERZ/$einheit"
    done

    systemctl daemon-reload
    if [ "$GO2RTC_BEREIT" = "ja" ]; then
        systemctl enable --now camgrid-go2rtc.service \
            || warnung "camgrid-go2rtc laeuft nicht (pruefen: journalctl -u camgrid-go2rtc)."
    fi
    systemctl enable --now camgrid-admin.service \
        || warnung "camgrid-admin laeuft nicht (pruefen: journalctl -u camgrid-admin)."
}

# launchd kennt kein ExecStartPre - deshalb startet go2rtc ueber
# scripts/go2rtc-start.sh, das vorher go2rtc.yaml erzeugt.
schreibe_launchd_plist() {
    label="$1"
    plist="$2"
    log="$3"
    shift 3
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        printf '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n'
        printf '  <key>Label</key><string>%s</string>\n' "$label"
        printf '  <key>ProgramArguments</key>\n  <array>\n'
        for teil in "$@"; do
            printf '    <string>%s</string>\n' "$teil"
        done
        printf '  </array>\n'
        printf '  <key>WorkingDirectory</key><string>%s</string>\n' "$ZIELVERZ"
        printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
        printf '    <key>PYTHONUNBUFFERED</key><string>1</string>\n'
        printf '    <key>CAMGRID_CONFIG</key><string>%s/config.json</string>\n' "$CONFVERZ"
        printf '    <key>CAMGRID_GO2RTC_YAML</key><string>%s/go2rtc.yaml</string>\n' "$DATAVERZ"
        printf '    <key>CAMGRID_WEB</key><string>%s/web/public</string>\n' "$ZIELVERZ"
        printf '    <key>CAMGRID_ZIEL</key><string>%s</string>\n' "$ZIELVERZ"
        printf '  </dict>\n'
        printf '  <key>RunAtLoad</key><true/>\n'
        printf '  <key>KeepAlive</key><true/>\n'
        printf '  <key>StandardOutPath</key><string>%s</string>\n' "$log"
        printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$log"
        printf '</dict>\n</plist>\n'
    } > "$plist"
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$plist" 2>/dev/null || true
    chmod 0644 "$plist"
}

launchd_laden() {
    label="$1"
    plist="$2"
    kennung=$(id -u "$DIENSTBENUTZER" 2>/dev/null || printf '')
    if [ -z "$kennung" ]; then
        warnung "Benutzerkennung von $DIENSTBENUTZER nicht ermittelbar - $label bitte von Hand laden."
        return 1
    fi
    # Erst abmelden, damit ein erneuter Aufruf nicht scheitert (Idempotenz).
    sudo -u "$DIENSTBENUTZER" launchctl bootout "gui/$kennung/$label" >/dev/null 2>&1 || true
    sudo -u "$DIENSTBENUTZER" launchctl unload "$plist" >/dev/null 2>&1 || true

    if sudo -u "$DIENSTBENUTZER" launchctl bootstrap "gui/$kennung" "$plist" >/dev/null 2>&1; then
        meldung "launchd-Dienst geladen: $label"
        return 0
    fi
    if sudo -u "$DIENSTBENUTZER" launchctl load -w "$plist" >/dev/null 2>&1; then
        meldung "launchd-Dienst geladen (load -w): $label"
        return 0
    fi
    warnung "$label konnte nicht geladen werden. Von Hand (als $DIENSTBENUTZER):"
    warnung "  launchctl bootstrap gui/\$(id -u) $plist"
    return 1
}

installiere_dienste_launchd() {
    agentverz="$BENUTZERHEIM/Library/LaunchAgents"
    mkdir -p "$agentverz"
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$agentverz" 2>/dev/null || true

    adminplist="$agentverz/de.camgrid.admin.plist"
    go2rtcplist="$agentverz/de.camgrid.go2rtc.plist"

    meldung "launchd-Dienste werden eingerichtet: $agentverz"
    schreibe_launchd_plist "de.camgrid.admin" "$adminplist" "$LOGVERZ/admin.log" \
        "$PYTHON3" "$ZIELVERZ/app/server.py" "--config" "$CONFVERZ/config.json"
    launchd_laden "de.camgrid.admin" "$adminplist" || true

    if [ "$GO2RTC_BEREIT" = "ja" ]; then
        schreibe_launchd_plist "de.camgrid.go2rtc" "$go2rtcplist" "$LOGVERZ/go2rtc.log" \
            "/bin/sh" "$ZIELVERZ/scripts/go2rtc-start.sh"
        launchd_laden "de.camgrid.go2rtc" "$go2rtcplist" || true
    else
        meldung "de.camgrid.go2rtc wird uebersprungen (go2rtc fehlt)."
        rm -f "$go2rtcplist"
    fi
}

installiere_dienste() {
    schritt "Dienste einrichten"
    ermittle_python
    if [ "$TROCKEN" = "ja" ]; then
        case "$DIENSTART" in
            systemd) meldung "[Probelauf] systemd-Dienste wuerden eingerichtet und gestartet." ;;
            launchd) meldung "[Probelauf] launchd-Dienste in ~/Library/LaunchAgents wuerden eingerichtet." ;;
            *)       meldung "[Probelauf] Keine Dienstverwaltung - Start muesste von Hand erfolgen." ;;
        esac
        return 0
    fi

    case "$DIENSTART" in
        systemd) installiere_dienste_systemd ;;
        launchd) installiere_dienste_launchd ;;
        *)
            warnung "Keine Dienstverwaltung vorhanden - es wird nichts automatisch gestartet."
            meldung "Von Hand starten (im Vordergrund):"
            meldung "  $PYTHON3 $ZIELVERZ/app/dienst.py --mit-server --config $CONFVERZ/config.json"
            ;;
    esac
}

# ------------------------------------------------------------------ Autostart -

schreibe_autostart() {
    schritt "Autostart einrichten"
    if [ "$SYSTEM" != "linux" ]; then
        return 0
    fi
    if [ "$TROCKEN" = "ja" ]; then
        if [ "$KIOSK" = "ja" ]; then
            meldung "[Probelauf] Kiosk-Autostart in ~/.config/autostart wuerde angelegt."
        else
            meldung "[Probelauf] Kein Kiosk-Autostart (abgeschaltet oder keine Oberflaeche)."
        fi
        return 0
    fi
    if [ "$HAT_GRAFIK" != "ja" ] && [ "$KIOSK" != "ja" ]; then
        meldung "Ohne grafische Oberflaeche wird kein Autostart angelegt."
        # Reste einer frueheren Installation mit Bildschirm aufraeumen.
        for alt_datei in camgrid-kiosk.desktop camgrid-keyring.desktop; do
            if [ -f "$BENUTZERHEIM/.config/autostart/$alt_datei" ]; then
                rm -f "$BENUTZERHEIM/.config/autostart/$alt_datei"
                meldung "Alter Autostart-Eintrag entfernt: $alt_datei"
            fi
        done
        return 0
    fi

    autostart="$BENUTZERHEIM/.config/autostart"
    kioskdatei="$autostart/camgrid-kiosk.desktop"
    keyringdatei="$autostart/camgrid-keyring.desktop"

    mkdir -p "$autostart"
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$BENUTZERHEIM/.config" "$autostart" 2>/dev/null || true

    if [ "$KIOSK" = "nein" ]; then
        if [ -f "$kioskdatei" ]; then
            rm -f "$kioskdatei"
            meldung "Kiosk-Autostart entfernt."
        else
            meldung "Kiosk-Autostart wird nicht angelegt."
        fi
    else
        meldung "Autostart der Anzeige: $kioskdatei"
        {
            printf '[Desktop Entry]\n'
            printf 'Type=Application\n'
            printf 'Name=CamGrid Anzeige\n'
            printf 'Comment=Startet die Kamera-Anzeigewand im Kiosk-Modus\n'
            printf 'Exec=%s/scripts/kiosk.sh\n' "$ZIELVERZ"
            printf 'Terminal=false\n'
            printf 'X-GNOME-Autostart-enabled=true\n'
        } > "$kioskdatei"
        chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$kioskdatei"
        chmod 0644 "$kioskdatei"
    fi

    meldung "Autostart des Schluesselbunds: $keyringdatei"
    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=CamGrid Schluesselbund\n'
        printf 'Comment=Entsperrt den GNOME-Schluesselbund ohne Tastatureingabe\n'
        printf 'Exec=%s/scripts/keyring.sh\n' "$ZIELVERZ"
        printf 'Terminal=false\n'
        printf 'X-GNOME-Autostart-enabled=true\n'
    } > "$keyringdatei"
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$keyringdatei"
    chmod 0644 "$keyringdatei"
}

# ------------------------------------------------------------------- sudoers -

# Die Regel erlaubt dem Dienstbenutzer nur das Neustarten der eigenen Dienste
# und einen Neustart des Geraets - beides aus dem Dashboard heraus.
schreibe_sudoers() {
    schritt "sudoers-Regel anlegen"
    if [ "$TROCKEN" = "ja" ]; then
        if [ "$SYSTEM" = "linux" ] && [ "$DIENSTART" = "systemd" ]; then
            meldung "[Probelauf] sudoers-Regel $SUDOERSDATEI wuerde angelegt."
        else
            meldung "[Probelauf] Keine sudoers-Regel notwendig (nur bei systemd sinnvoll)."
        fi
        return 0
    fi
    if [ "$SYSTEM" != "linux" ] || [ "$DIENSTART" != "systemd" ]; then
        meldung "Keine sudoers-Regel notwendig (nur bei systemd sinnvoll)."
        return 0
    fi
    if ! command -v visudo >/dev/null 2>&1; then
        warnung "visudo fehlt - die sudoers-Regel wird nicht angelegt."
        warnung "Ohne sie kann das Dashboard die Dienste nicht selbst neu starten."
        return 0
    fi
    meldung "sudoers-Regel wird angelegt: $SUDOERSDATEI"

    sicherung=""
    if [ -f "$SUDOERSDATEI" ]; then
        sicherung="$SUDOERSDATEI.sicherung.$$"
        cp -a "$SUDOERSDATEI" "$sicherung"
    fi

    neu="$SUDOERSDATEI.neu.$$"
    {
        printf '# CamGrid - von install.sh erzeugt, nicht von Hand aendern.\n'
        printf 'Cmnd_Alias CAMGRID_DIENSTE = '
        erster="ja"
        for pfad in /usr/bin/systemctl /bin/systemctl; do
            for befehl in restart status stop start; do
                if [ "$erster" = "ja" ]; then
                    erster="nein"
                else
                    printf ', '
                fi
                printf '%s %s camgrid-go2rtc' "$pfad" "$befehl"
            done
            printf ', %s restart camgrid-admin' "$pfad"
        done
        printf '\n'
        printf 'Cmnd_Alias CAMGRID_NEUSTART = /sbin/reboot, /usr/sbin/reboot\n'
        printf '%s ALL=(root) NOPASSWD: CAMGRID_DIENSTE, CAMGRID_NEUSTART\n' "$DIENSTBENUTZER"
    } > "$neu"
    chown root "$neu" 2>/dev/null || true
    chmod 0440 "$neu"

    if visudo -c -f "$neu" >/dev/null 2>&1; then
        mv -f "$neu" "$SUDOERSDATEI"
        rm -f "$sicherung"
    else
        rm -f "$neu"
        if [ -n "$sicherung" ]; then
            mv -f "$sicherung" "$SUDOERSDATEI"
            fehler "sudoers-Regel ist fehlerhaft - vorherige Fassung wurde wiederhergestellt."
        fi
        fehler "sudoers-Regel ist fehlerhaft und wurde nicht uebernommen."
    fi

    # Gesamtpruefung, damit ein defektes sudo sofort auffaellt
    if ! visudo -c >/dev/null 2>&1; then
        rm -f "$SUDOERSDATEI"
        fehler "Gesamtpruefung von sudoers fehlgeschlagen - Regel wurde wieder entfernt."
    fi
    meldung "sudoers-Regel geprueft (visudo -c)."
}

# ------------------------------------------------------------ Zusammenfassung -

ermittle_ip() {
    adresse=""
    if [ "$SYSTEM" = "macos" ]; then
        for netzgeraet in en0 en1 en2; do
            adresse=$(ipconfig getifaddr "$netzgeraet" 2>/dev/null || true)
            [ -z "$adresse" ] || break
        done
    else
        adresse=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi
    if [ -z "${adresse:-}" ] && command -v ip >/dev/null 2>&1; then
        adresse=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {print $7; exit}' || true)
    fi
    if [ -z "${adresse:-}" ]; then
        adresse="<ip-adresse>"
    fi
    printf '%s' "$adresse"
}

lies_port() {
    # lies_port <schluessel> <ersatzwert>
    wert=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "$CONFVERZ/config.json" 2>/dev/null | head -n 1 || true)
    case "${wert:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$wert" ;;
    esac
}

zusammenfassung() {
    schritt "Zusammenfassung"
    ip=$(ermittle_ip)
    port=$(lies_port admin_port "$ADMINPORT")
    ANZEIGEPORT=$(lies_port go2rtc_port "$ANZEIGEPORT")

    printf '\n'
    printf '========================================================\n'
    if [ "$TROCKEN" = "ja" ]; then
        printf ' CamGrid %s - Probelauf beendet (nichts geaendert)\n' "$PROJEKTVERSION"
    else
        printf ' CamGrid %s - Installation abgeschlossen\n' "$PROJEKTVERSION"
    fi
    printf '========================================================\n'
    printf '\n'
    printf ' Adressen\n'
    printf '   Verwaltung : http://%s:%s\n' "$ip" "$port"
    printf '   Anzeige    : http://%s:%s/?monitor=1\n' "$ip" "$ANZEIGEPORT"
    printf '\n'
    printf ' Zugangsdaten\n'
    if [ -n "${ADMINPASSWORT:-}" ]; then
        printf '   Benutzer   : %s\n' "$STANDARDBENUTZER"
        printf '   Passwort   : %s\n' "$ADMINPASSWORT"
        printf '   >>> Das ist die bekannte Vorgabe. Bitte SOFORT nach dem ersten\n'
        printf '   >>> Anmelden in der Verwaltung ein eigenes Passwort setzen.\n'
    else
        printf '   Unveraendert (vorhandene Konfiguration wurde beibehalten).\n'
        printf '   Vorgabe bei einer frischen Installation: %s / %s\n' "$STANDARDBENUTZER" "$STANDARDPASSWORT"
    fi
    printf '\n'
    printf ' Pfade\n'
    printf '   Programm       : %s\n' "$ZIELVERZ"
    printf '   Konfiguration  : %s/config.json\n' "$CONFVERZ"
    printf '   Protokolle     : %s\n' "$LOGVERZ"
    printf '   Laufzeitdaten  : %s (go2rtc.yaml)\n' "$DATAVERZ"
    printf '   Dienstbenutzer : %s\n' "$DIENSTBENUTZER"
    printf '\n'
    if [ -n "$FEHLENDE_PAKETE" ]; then
        printf ' Fehlende Pakete bitte nachinstallieren\n'
        printf '   %s%s\n' "$(installationsbefehl)" "$FEHLENDE_PAKETE"
        printf '   Danach install.sh einfach erneut starten.\n'
        printf '\n'
    fi
    if [ "$GO2RTC_BEREIT" != "ja" ]; then
        printf ' Ohne Streaming-Dienst installiert\n'
        printf '   go2rtc fehlt. Datei %s von\n' "$GO2RTC_DATEI"
        printf '   https://github.com/%s/releases holen, nach\n' "$GO2RTC_REPO"
        printf '   %s/bin/go2rtc legen, chmod +x setzen und install.sh erneut starten.\n' "$ZIELVERZ"
        printf '\n'
    fi
    printf ' Naechste Schritte\n'
    printf '   1. Verwaltung im Browser oeffnen, Passwort aendern, Kameras eintragen.\n'
    printf '   2. Monitore, Ausgaenge und Kachelraster festlegen.\n'
    if [ "$SYSTEM" = "macos" ]; then
        printf '   3. Anzeige im Vollbild oeffnen (kein Autostart auf macOS):\n'
        printf '      open -a "Google Chrome" --args --kiosk "http://127.0.0.1:%s/?monitor=1"\n' "$ANZEIGEPORT"
        printf '      oder Safari oeffnen und mit Strg+Cmd+F auf Vollbild schalten.\n'
    elif [ "$KIOSK" = "ja" ]; then
        printf '   3. Geraet neu starten (sudo reboot) - die Anzeige startet dann selbst.\n'
        printf '      Sofort pruefen: %s/scripts/kiosk.sh --neustart\n' "$ZIELVERZ"
    else
        printf '   3. Keine Kiosk-Anzeige eingerichtet.\n'
        printf '      Anzeige im Netz: http://%s:%s/?monitor=1\n' "$ip" "$ANZEIGEPORT"
        printf '      Von Hand starten: %s/scripts/kiosk.sh\n' "$ZIELVERZ"
    fi
    printf '\n'
    printf ' Dienste pruefen\n'
    case "$DIENSTART" in
        systemd)
            printf '   systemctl status camgrid-admin camgrid-go2rtc\n'
            printf '   journalctl -u camgrid-go2rtc -f\n'
            ;;
        launchd)
            printf '   launchctl list | grep de.camgrid\n'
            printf '   tail -f %s/admin.log %s/go2rtc.log\n' "$LOGVERZ" "$LOGVERZ"
            ;;
        *)
            printf '   %s %s/app/dienst.py --mit-server --config %s/config.json\n' \
                "${PYTHON3:-python3}" "$ZIELVERZ" "$CONFVERZ"
            ;;
    esac
    printf '\n'
    printf ' Entfernen\n'
    printf '   sudo %s/uninstall.sh\n' "$ZIELVERZ"
    printf '\n'
}

# ------------------------------------------------------------------- Ablauf --

erkenne_system
pruefe_root
erkenne_paketverwalter
erkenne_dienstverwaltung
ermittle_architektur
ermittle_dienstbenutzer
pruefe_dienstbenutzer
erkenne_grafik
installiere_pakete
lege_verzeichnisse_an
kopiere_programmdateien
lade_go2rtc
lade_weboberflaeche
erzeuge_konfiguration
richte_schluesselbund_ein
installiere_dienste
schreibe_autostart
schreibe_sudoers
zusammenfassung

trap - EXIT
exit 0
