#!/bin/sh
# CamGrid - Schluesselbund beim Anmelden entsperren.
#
# Auf einem Pi ohne Tastatur bliebe sonst das Passwortfenster des
# GNOME-Schluesselbunds stehen und verdeckt die Anzeige.
# Das Passwort steht in /etc/camgrid/keyring.pw (Rechte 600,
# Eigentuemer ist der Dienstbenutzer). Fehlt die Datei, endet das
# Skript kommentarlos.
set -u

PWDATEI="/etc/camgrid/keyring.pw"

[ -f "$PWDATEI" ] || exit 0
[ -r "$PWDATEI" ] || exit 0

command -v gnome-keyring-daemon >/dev/null 2>&1 || exit 0

passwort=$(head -n 1 "$PWDATEI")
[ -n "$passwort" ] || exit 0

# --unlock liest das Passwort aus der Standardeingabe.
printf '%s\n' "$passwort" \
    | gnome-keyring-daemon --unlock --daemonize --components=secrets >/dev/null 2>&1 || exit 0

exit 0
