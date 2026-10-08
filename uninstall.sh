#!/bin/sh
# CamGrid - uninstall script (Linux and macOS)
# Removes the services (systemd or launchd), the autostart entries, the
# sudoers rule and /opt/camgrid. The configuration in /etc/camgrid is kept
# on request (default).
# Usage: sudo ./uninstall.sh [--alles] [--behalten] [--help]
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
    printf '[camgrid] Warning: %s\n' "$1" >&2
}

fehler() {
    printf '[camgrid] Error: %s\n' "$1" >&2
    exit 1
}

hilfe() {
    printf '%s\n' \
"CamGrid - uninstall" \
"" \
"Usage:" \
"  sudo ./uninstall.sh [options]" \
"" \
"Options:" \
"  --behalten   Keep the configuration in /etc/camgrid (no question asked)" \
"  --alles      Delete the configuration as well (no question asked)" \
"  --help       Show this help" \
"" \
"Without an option you are asked. The default answer is to keep it."
}

while [ $# -gt 0 ]; do
    case "$1" in
        --alles)    KONFIG_ENTFERNEN="ja"; shift ;;
        --behalten) KONFIG_ENTFERNEN="nein"; shift ;;
        --help|-h)  hilfe; exit 0 ;;
        *)          fehler "Unknown option: $1 (see --help)" ;;
    esac
done

[ "$(id -u)" = "0" ] || fehler "Please run with root rights, for example: sudo ./uninstall.sh"

# ------------------------------------------------------------------ services -

beende_dienste() {
    if ! command -v systemctl >/dev/null 2>&1; then
        meldung "No systemd present - systemd services are skipped."
        return 0
    fi
    meldung "Stopping and disabling the systemd services ..."
    for einheit in camgrid-admin.service camgrid-go2rtc.service; do
        systemctl stop "$einheit" >/dev/null 2>&1 || true
        systemctl disable "$einheit" >/dev/null 2>&1 || true
        if [ -f "$SYSTEMDVERZ/$einheit" ]; then
            rm -f "$SYSTEMDVERZ/$einheit"
            meldung "Removed: $SYSTEMDVERZ/$einheit"
        fi
    done
    systemctl daemon-reload || true
    systemctl reset-failed camgrid-admin.service camgrid-go2rtc.service >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------ launchd --

# On macOS the services are user agents in
# ~/Library/LaunchAgents/de.camgrid.*.plist - in every home directory, so that
# a changed service user is covered as well.
beende_launchd_dienste() {
    [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] || return 0
    command -v launchctl >/dev/null 2>&1 || return 0
    meldung "Unloading the launchd services ..."

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
            meldung "Removed: $plist"
        done
    done
}

# ------------------------------------------------------------ kiosk windows --

beende_fenster() {
    meldung "Stopping running display windows ..."
    # The pattern is bracketed so that pkill does not match its own command line
    pkill -f '[k]amerawand-fenster' >/dev/null 2>&1 || true
    pkill -f '[k]iosk.sh' >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- autostart --

entferne_autostart() {
    meldung "Removing the autostart entries ..."
    # Search all home directories, so that a changed service user is covered
    # as well.
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
                printf '[camgrid] Removed: %s\n' "$heim/.config/autostart/$datei"
            fi
        done
        # The Wayland session (labwc) keeps its own autostart file.
        labwcdatei="$heim/.config/labwc/autostart"
        if [ -f "$labwcdatei" ] && grep -q "/camgrid/scripts/" "$labwcdatei" 2>/dev/null; then
            grep -v "/camgrid/scripts/" "$labwcdatei" > "$labwcdatei.neu" 2>/dev/null \
                && mv "$labwcdatei.neu" "$labwcdatei"
            printf '[camgrid] Cleaned up: %s\n' "$labwcdatei"
        fi
    done
}

# ------------------------------------------------------------------ sudoers --

entferne_sudoers() {
    if [ -f "$SUDOERSDATEI" ]; then
        rm -f "$SUDOERSDATEI"
        meldung "Removed: $SUDOERSDATEI"
        if ! visudo -c >/dev/null 2>&1; then
            warnung "'visudo -c' reports an error. Please check /etc/sudoers."
        fi
    fi
}

# -------------------------------------------------------------------- files --

entferne_programmdateien() {
    if [ -d "$ZIELVERZ" ]; then
        rm -rf "$ZIELVERZ"
        meldung "Removed: $ZIELVERZ"
    fi
    if [ -d "$DATAVERZ" ]; then
        rm -rf "$DATAVERZ"
        meldung "Removed: $DATAVERZ"
    fi
    if [ -d "$LOGVERZ" ]; then
        rm -rf "$LOGVERZ"
        meldung "Removed: $LOGVERZ"
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
        meldung "No input possible - the configuration is kept."
        KONFIG_ENTFERNEN="nein"
        return 0
    fi

    printf 'Keep the configuration in %s? [Y/n] ' "$CONFVERZ"
    read -r antwort || antwort=""
    case "$antwort" in
        n|N|no|No|NO|nein|Nein|NEIN) KONFIG_ENTFERNEN="ja" ;;
        *)                           KONFIG_ENTFERNEN="nein" ;;
    esac
}

entferne_konfiguration() {
    if [ "$KONFIG_ENTFERNEN" = "ja" ]; then
        rm -rf "$CONFVERZ"
        meldung "Removed: $CONFVERZ"
    else
        meldung "The configuration is kept: $CONFVERZ"
    fi
}

# --------------------------------------------------------------------- flow --

frage_konfiguration
beende_fenster
beende_dienste
beende_launchd_dienste
entferne_autostart
entferne_sudoers
entferne_programmdateien
entferne_konfiguration

printf '\n'
meldung "Uninstall finished."
if [ "$KONFIG_ENTFERNEN" != "ja" ]; then
    meldung "To remove everything: sudo rm -rf $CONFVERZ"
fi
