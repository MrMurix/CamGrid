#!/bin/sh
# CamGrid - Installation in einem Befehl.
#
# Holt das Projekt von GitHub nach /opt/camgrid-quelle (oder aktualisiert
# eine vorhandene Kopie) und startet danach install.sh. Alle weiteren
# Parameter werden unveraendert an install.sh weitergegeben.
#
# Aufruf:
#   curl -fsSL https://raw.githubusercontent.com/MrMurix/CamGrid/main/netz-installation.sh | sudo sh
#
# Mit Parametern fuer install.sh (das -s -- ist dabei wichtig):
#   curl -fsSL .../netz-installation.sh | sudo sh -s -- --no-kiosk --port 8090
set -eu

# PLATZHALTER durch den eigenen GitHub-Benutzernamen ersetzen.
GITHUB_BENUTZER="PLATZHALTER"
PROJEKTNAME="camgrid"
ZWEIG="main"

QUELLVERZ="/opt/camgrid-quelle"
REPO="${CAMGRID_REPO:-}"

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
"CamGrid - Installation in einem Befehl" \
"" \
"Aufruf:" \
"  curl -fsSL https://raw.githubusercontent.com/$GITHUB_BENUTZER/$PROJEKTNAME/$ZWEIG/netz-installation.sh | sudo sh" \
"" \
"Mit Parametern fuer install.sh:" \
"  curl -fsSL .../netz-installation.sh | sudo sh -s -- --no-kiosk --port 8090" \
"" \
"Eigene Optionen:" \
"  --repo ADRESSE    Git-Adresse des Projekts (sonst GitHub, siehe oben)" \
"  --zweig NAME      Zweig (Standard: $ZWEIG)" \
"  --quelle VERZ     Ablage der Arbeitskopie (Standard: $QUELLVERZ)" \
"  --hilfe, --help   Diese Hilfe anzeigen" \
"" \
"Alle anderen Optionen gehen an install.sh weiter, zum Beispiel:" \
"  --user NAME  --no-kiosk  --port N  --dry-run  --version" \
"" \
"Ablauf:" \
"  1. git pruefen und notfalls installieren (apt, dnf, pacman, zypper, brew)" \
"  2. Projekt nach $QUELLVERZ klonen oder per git pull aktualisieren" \
"  3. sh $QUELLVERZ/install.sh mit den uebergebenen Parametern starten" \
"" \
"Statt der Umgebungsvariable CAMGRID_REPO kann auch --repo verwendet werden."
}

# --------------------------------------------------------------- Parameter ---

# Eigene Optionen herausfiltern, alle uebrigen in der urspruenglichen Form
# fuer install.sh behalten. Dazu wird die Parameterliste einmal durchgedreht:
# jeder fremde Parameter wird hinten wieder angehaengt.
UEBRIG=$#
while [ "$UEBRIG" -gt 0 ]; do
    arg="$1"
    shift
    UEBRIG=$((UEBRIG - 1))
    case "$arg" in
        --hilfe|--help|-h)
            hilfe
            exit 0
            ;;
        --repo)
            [ "$UEBRIG" -ge 1 ] || fehler "--repo benoetigt eine Adresse."
            REPO="$1"; shift; UEBRIG=$((UEBRIG - 1)) ;;
        --repo=*)
            REPO="${arg#--repo=}" ;;
        --zweig)
            [ "$UEBRIG" -ge 1 ] || fehler "--zweig benoetigt einen Namen."
            ZWEIG="$1"; shift; UEBRIG=$((UEBRIG - 1)) ;;
        --zweig=*)
            ZWEIG="${arg#--zweig=}" ;;
        --quelle)
            [ "$UEBRIG" -ge 1 ] || fehler "--quelle benoetigt ein Verzeichnis."
            QUELLVERZ="$1"; shift; UEBRIG=$((UEBRIG - 1)) ;;
        --quelle=*)
            QUELLVERZ="${arg#--quelle=}" ;;
        *)
            # Unveraendert an install.sh weitergeben.
            set -- "$@" "$arg" ;;
    esac
done

if [ -z "$REPO" ]; then
    REPO="https://github.com/$GITHUB_BENUTZER/$PROJEKTNAME.git"
fi

# ------------------------------------------------------------ Vorbedingungen -

[ "$(id -u)" = "0" ] || fehler "Bitte mit Root-Rechten starten, zum Beispiel: curl -fsSL ... | sudo sh"

kern=$(uname -s 2>/dev/null || printf 'unbekannt')
case "$kern" in
    Linux|Darwin) : ;;
    *) fehler "Dieses Skript ist fuer Linux und macOS. Fuer Windows: install.ps1 verwenden." ;;
esac

# Steht im Repo noch der Platzhalter, kann nichts geklont werden - ausser es
# liegt schon eine Arbeitskopie mit eigener Adresse vor.
pruefe_platzhalter() {
    case "$REPO" in
        *PLATZHALTER*) : ;;
        *) return 0 ;;
    esac
    if [ -d "$QUELLVERZ/.git" ]; then
        warnung "Die Projektadresse enthaelt noch den Platzhalter 'PLATZHALTER'."
        warnung "Es wird die vorhandene Arbeitskopie in $QUELLVERZ verwendet."
        REPO=""
        return 0
    fi
    printf '\n' >&2
    printf '[camgrid] Die Projektadresse ist noch nicht eingetragen:\n' >&2
    printf '    %s\n' "$REPO" >&2
    printf '[camgrid] In netz-installation.sh muss PLATZHALTER durch den eigenen\n' >&2
    printf '[camgrid] GitHub-Benutzernamen ersetzt werden (Zeile GITHUB_BENUTZER).\n' >&2
    printf '[camgrid] Sofort loesbar ohne Aenderung der Datei:\n' >&2
    printf '    curl -fsSL ... | sudo sh -s -- --repo https://github.com/NAME/camgrid.git\n' >&2
    printf '    oder: CAMGRID_REPO=https://github.com/NAME/camgrid.git sudo -E sh netz-installation.sh\n' >&2
    printf '\n' >&2
    exit 1
}

# ---------------------------------------------------------------------- git --

installiere_git() {
    command -v git >/dev/null 2>&1 && return 0
    meldung "git fehlt und wird installiert ..."
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y git >/dev/null 2>&1 || true
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed git >/dev/null 2>&1 || true
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install git >/dev/null 2>&1 || true
    elif [ "$kern" = "Darwin" ]; then
        # Auf macOS bringt git die Xcode-Kommandozeile mit.
        xcode-select --install >/dev/null 2>&1 || true
        warnung "Bitte die Installation der Xcode-Kommandozeilenwerkzeuge bestaetigen."
    fi
    command -v git >/dev/null 2>&1 \
        || fehler "git konnte nicht installiert werden. Bitte von Hand installieren und erneut starten."
    meldung "git ist vorhanden: $(git --version 2>/dev/null || printf 'git')"
}

# ------------------------------------------------------------- Arbeitskopie --

hole_projekt() {
    if [ -d "$QUELLVERZ/.git" ]; then
        meldung "Vorhandene Arbeitskopie wird aktualisiert: $QUELLVERZ"
        if [ -n "$REPO" ]; then
            git -C "$QUELLVERZ" remote set-url origin "$REPO" >/dev/null 2>&1 || true
        fi
        git -C "$QUELLVERZ" fetch --depth 1 origin "$ZWEIG" >/dev/null 2>&1 \
            || warnung "git fetch war nicht erfolgreich - es wird mit dem vorhandenen Stand gearbeitet."
        if ! git -C "$QUELLVERZ" reset --hard "origin/$ZWEIG" >/dev/null 2>&1; then
            git -C "$QUELLVERZ" pull --ff-only >/dev/null 2>&1 \
                || warnung "git pull war nicht erfolgreich - es wird mit dem vorhandenen Stand gearbeitet."
        fi
    else
        if [ -d "$QUELLVERZ" ] && [ -n "$(ls -A "$QUELLVERZ" 2>/dev/null || true)" ]; then
            fehler "$QUELLVERZ ist vorhanden, aber keine Arbeitskopie. Bitte umbenennen oder --quelle angeben."
        fi
        meldung "Projekt wird geholt: $REPO (Zweig $ZWEIG)"
        mkdir -p "$(dirname "$QUELLVERZ")"
        if ! git clone --depth 1 --branch "$ZWEIG" "$REPO" "$QUELLVERZ" >/dev/null 2>&1; then
            rm -rf "$QUELLVERZ"
            fehler "Das Projekt konnte nicht geklont werden: $REPO (Zweig $ZWEIG)"
        fi
    fi

    [ -f "$QUELLVERZ/install.sh" ] \
        || fehler "$QUELLVERZ/install.sh fehlt - ist das die richtige Projektadresse?"
    chmod 0755 "$QUELLVERZ/install.sh" 2>/dev/null || true
    meldung "Stand: $(git -C "$QUELLVERZ" log -1 --format='%h %ad' --date=short 2>/dev/null || printf 'unbekannt')"
}

# ------------------------------------------------------------------- Ablauf --

pruefe_platzhalter
installiere_git
hole_projekt

meldung "install.sh wird gestartet ..."
if [ $# -gt 0 ]; then
    meldung "Parameter: $*"
fi
printf '\n'

cd "$QUELLVERZ"
# Ohne "|| ergebnis=$?" wuerde set -e hier sofort abbrechen.
ergebnis=0
sh "$QUELLVERZ/install.sh" "$@" || ergebnis=$?

if [ "$ergebnis" = "0" ]; then
    meldung "Arbeitskopie fuer spaetere Aktualisierungen: $QUELLVERZ"
    meldung "Aktualisieren: sudo sh $QUELLVERZ/netz-installation.sh"
fi
exit "$ergebnis"
