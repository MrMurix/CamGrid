#!/bin/sh
# CamGrid - unlock the keyring at login.
#
# On a Pi without a keyboard the password dialog of the GNOME keyring would
# otherwise stay on screen and cover the display.
# The password is kept in /etc/camgrid/keyring.pw (mode 600, owned by the
# service user). If the file is missing, the script exits silently.
set -u

PWDATEI="/etc/camgrid/keyring.pw"

[ -f "$PWDATEI" ] || exit 0
[ -r "$PWDATEI" ] || exit 0

command -v gnome-keyring-daemon >/dev/null 2>&1 || exit 0

passwort=$(head -n 1 "$PWDATEI")
[ -n "$passwort" ] || exit 0

# --unlock reads the password from standard input.
printf '%s\n' "$passwort" \
    | gnome-keyring-daemon --unlock --daemonize --components=secrets >/dev/null 2>&1 || exit 0

exit 0
