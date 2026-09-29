#!/bin/sh
# CamGrid - Deinstallationsskript (Linux und macOS)
# Entfernt Dienste (systemd oder launchd), Autostart, sudoers-Regel und
# /opt/camgrid. Die Konfiguration unter /etc/camgrid wird auf Wunsch
# behalten (Standard).
# Aufruf: sudo ./uninstall.sh [--alles] [--behalten] [--help]
set -eu

ZIELVERZ="/opt/camgrid"
CONFVERZ="/etc/camgrid"
LOGVERZ="/var/log/camgrid"
DATAVERZ="/var/lib/camgrid"
SUDOERSDATEI="/etc/sudoers.d/camgrid"
SYSTEMDVERZ="/etc/systemd/system"

KONFIG_ENTFERNEN="frage"

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

hilfe() {
    printf '%s\n' \
"CamGrid - Deinstallation" \
"" \
"Aufruf:" \
"  sudo ./uninstall.sh [Optionen]" \
"" \
"Optionen:" \
"  --behalten   Konfiguration in /etc/camgrid behalten (keine Rueckfrage)" \
"  --alles      Konfiguration ebenfalls loeschen (keine Rueckfrage)" \
"  --help       Diese Hilfe anzeigen" \
"" \
"Ohne Option wird nachgefragt. Standard der Rueckfrage: behalten."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --alles)    KONFIG_ENTFERNEN="ja"; shift ;;
        --behalten) KONFIG_ENTFERNEN="nein"; shift ;;
        --help|-h)  hilfe; exit 0 ;;
        *)          fehler "Unbekannte Option: $1 (siehe --help)" ;;
    esac
done

[ "$(id -u)" = "0" ] || fehler "Bitte mit Root-Rechten starten: sudo ./uninstall.sh"

# ------------------------------------------------------------------ Dienste --

beende_dienste() {
    if ! command -v systemctl >/dev/null 2>&1; then
        meldung "Kein systemd vorhanden - systemd-Dienste werden uebergangen."
        return 0
    fi
    meldung "systemd-Dienste werden beendet und abgeschaltet ..."
    for einheit in camgrid-admin.service camgrid-go2rtc.service; do
        systemctl stop "$einheit" >/dev/null 2>&1 || true
        systemctl disable "$einheit" >/dev/null 2>&1 || true
        if [ -f "$SYSTEMDVERZ/$einheit" ]; then
            rm -f "$SYSTEMDVERZ/$einheit"
            meldung "Entfernt: $SYSTEMDVERZ/$einheit"
        fi
    done
    systemctl daemon-reload || true
    systemctl reset-failed camgrid-admin.service camgrid-go2rtc.service >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ launchd --

# Auf macOS liegen die Dienste als Benutzer-Agenten in
# ~/Library/LaunchAgents/de.camgrid.*.plist - und zwar in jedem
# Heimatverzeichnis, damit auch ein gewechselter Dienstbenutzer erfasst wird.
beende_launchd_dienste() {
    [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] || return 0
    command -v launchctl >/dev/null 2>&1 || return 0
    meldung "launchd-Dienste werden entladen ..."

    for heim in /Users/*; do
        [ -d "$heim/Library/LaunchAgents" ] || continue
        besitzer=$(stat -f '%Su' "$heim" 2>/dev/null || true)
        kennung=""
        [ -z "$besitzer" ] || kennung=$(id -u "$besitzer" 2>/dev/null || true)
        for label in de.camgrid.admin de.camgrid.go2rtc; do
            plist="$heim/Library/LaunchAgents/$label.plist"
            [ -f "$plist" ] || continue
            if [ -n "$kennung" ]; then
                sudo -u "$besitzer" launchctl bootout "gui/$kennung/$label" >/dev/null 2>&1 || true
                sudo -u "$besitzer" launchctl unload "$plist" >/dev/null 2>&1 || true
            fi
            rm -f "$plist"
            meldung "Entfernt: $plist"
        done
    done
}

# ------------------------------------------------------------ Kiosk-Fenster --

beende_fenster() {
    meldung "Laufende Anzeigefenster werden beendet ..."
    # Muster in Klammern, damit pkill nicht die eigene Befehlszeile trifft
    pkill -f '[k]amerawand-fenster' >/dev/null 2>&1 || true
    pkill -f '[k]iosk.sh' >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- Autostart --

entferne_autostart() {
    meldung "Autostart-Eintraege werden entfernt ..."
    # Alle Heimatverzeichnisse durchsuchen, damit auch ein geaenderter
    # Dienstbenutzer erfasst wird.
    heimliste() {
        if command -v getent >/dev/null 2>&1; then
            getent passwd | awk -F: '$3>=1000 && $3<65534 {print $6}'
        else
            ls -d /Users/* /home/* 2>/dev/null || true
        fi
    }
    heimliste | while read -r heim; do
        [ -n "$heim" ] || continue
        for datei in camgrid-kiosk.desktop camgrid-keyring.desktop; do
            if [ -f "$heim/.config/autostart/$datei" ]; then
                rm -f "$heim/.config/autostart/$datei"
                printf '[camgrid] Entfernt: %s\n' "$heim/.config/autostart/$datei"
            fi
        done
    done
}

# ------------------------------------------------------------------ sudoers --

entferne_sudoers() {
    if [ -f "$SUDOERSDATEI" ]; then
        rm -f "$SUDOERSDATEI"
        meldung "Entfernt: $SUDOERSDATEI"
        if ! visudo -c >/dev/null 2>&1; then
            warnung "'visudo -c' meldet einen Fehler. Bitte /etc/sudoers pruefen."
        fi
    fi
}

# ------------------------------------------------------------------- Dateien -

entferne_programmdateien() {
    if [ -d "$ZIELVERZ" ]; then
        rm -rf "$ZIELVERZ"
        meldung "Entfernt: $ZIELVERZ"
    fi
    if [ -d "$DATAVERZ" ]; then
        rm -rf "$DATAVERZ"
        meldung "Entfernt: $DATAVERZ"
    fi
    if [ -d "$LOGVERZ" ]; then
        rm -rf "$LOGVERZ"
        meldung "Entfernt: $LOGVERZ"
    fi
}

frage_konfiguration() {
    if [ ! -d "$CONFVERZ" ]; then
        KONFIG_ENTFERNEN="nein"
        return 0
    fi
    if [ "$KONFIG_ENTFERNEN" != "frage" ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        meldung "Keine Eingabe moeglich - Konfiguration wird behalten."
        KONFIG_ENTFERNEN="nein"
        return 0
    fi

    printf 'Konfiguration in %s behalten? [J/n] ' "$CONFVERZ"
    read -r antwort || antwort=""
    case "$antwort" in
        n|N|nein|Nein|NEIN) KONFIG_ENTFERNEN="ja" ;;
        *)                  KONFIG_ENTFERNEN="nein" ;;
    esac
}

entferne_konfiguration() {
    if [ "$KONFIG_ENTFERNEN" = "ja" ]; then
        rm -rf "$CONFVERZ"
        meldung "Entfernt: $CONFVERZ"
    else
        meldung "Konfiguration bleibt erhalten: $CONFVERZ"
    fi
}

# ------------------------------------------------------------------- Ablauf --

frage_konfiguration
beende_fenster
beende_dienste
beende_launchd_dienste
entferne_autostart
entferne_sudoers
entferne_programmdateien
entferne_konfiguration

printf '\n'
meldung "Deinstallation abgeschlossen."
if [ "$KONFIG_ENTFERNEN" != "ja" ]; then
    meldung "Zum vollstaendigen Entfernen: sudo rm -rf $CONFVERZ"
fi
