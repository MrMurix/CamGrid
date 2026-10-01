#!/bin/sh
# CamGrid - installation in a single command.
#
# Fetches the project from GitHub into /opt/camgrid-quelle (or updates an
# existing copy) and then runs install.sh. All further parameters are passed
# on to install.sh unchanged.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/MrMurix/CamGrid/main/netz-installation.sh | sudo sh
#
# With parameters for install.sh (the -s -- part matters):
#   curl -fsSL .../netz-installation.sh | sudo sh -s -- --no-kiosk --port 8090
set -eu

# Replace PLACEHOLDER with your own GitHub user name.
GITHUB_BENUTZER="PLACEHOLDER"
PROJEKTNAME="camgrid"
ZWEIG="main"

QUELLVERZ="/opt/camgrid-quelle"
REPO="${CAMGRID_REPO:-}"

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
"CamGrid - installation in a single command" \
"" \
"Usage:" \
"  curl -fsSL https://raw.githubusercontent.com/$GITHUB_BENUTZER/$PROJEKTNAME/$ZWEIG/netz-installation.sh | sudo sh" \
"" \
"With parameters for install.sh:" \
"  curl -fsSL .../netz-installation.sh | sudo sh -s -- --no-kiosk --port 8090" \
"" \
"Own options:" \
"  --repo ADDRESS    Git address of the project (otherwise GitHub, see above)" \
"  --zweig NAME      Branch (default: $ZWEIG)" \
"  --quelle DIR      Where the working copy is kept (default: $QUELLVERZ)" \
"  --hilfe, --help   Show this help" \
"" \
"All other options are passed on to install.sh, for example:" \
"  --user NAME  --no-kiosk  --port N  --dry-run  --version" \
"" \
"Steps:" \
"  1. Check for git and install it if needed (apt, dnf, pacman, zypper, brew)" \
"  2. Clone the project into $QUELLVERZ or update it with git pull" \
"  3. Run sh $QUELLVERZ/install.sh with the given parameters" \
"" \
"Instead of the environment variable CAMGRID_REPO you can also use --repo."
}

# -------------------------------------------------------------- parameters ---

# Filter out the own options and keep all remaining ones in their original
# form for install.sh. The parameter list is rotated once: every foreign
# parameter is appended at the end again.
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
            [ "$UEBRIG" -ge 1 ] || fehler "--repo needs an address."
            REPO="$1"; shift; UEBRIG=$((UEBRIG - 1)) ;;
        --repo=*)
            REPO="${arg#--repo=}" ;;
        --zweig)
            [ "$UEBRIG" -ge 1 ] || fehler "--zweig needs a name."
            ZWEIG="$1"; shift; UEBRIG=$((UEBRIG - 1)) ;;
        --zweig=*)
            ZWEIG="${arg#--zweig=}" ;;
        --quelle)
            [ "$UEBRIG" -ge 1 ] || fehler "--quelle needs a directory."
            QUELLVERZ="$1"; shift; UEBRIG=$((UEBRIG - 1)) ;;
        --quelle=*)
            QUELLVERZ="${arg#--quelle=}" ;;
        *)
            # Pass on to install.sh unchanged.
            set -- "$@" "$arg" ;;
    esac
done

if [ -z "$REPO" ]; then
    REPO="https://github.com/$GITHUB_BENUTZER/$PROJEKTNAME.git"
fi

# ----------------------------------------------------------- prerequisites ---

[ "$(id -u)" = "0" ] || fehler "Please run with root rights, for example: curl -fsSL ... | sudo sh"

kern=$(uname -s 2>/dev/null || printf 'unknown')
case "$kern" in
    Linux|Darwin) : ;;
    *) fehler "This script is for Linux and macOS. For Windows use install.ps1." ;;
esac

# If the repository still holds the placeholder, nothing can be cloned -
# unless a working copy with its own address is already there.
pruefe_platzhalter() {
    case "$REPO" in
        *PLACEHOLDER*) : ;;
        *) return 0 ;;
    esac
    if [ -d "$QUELLVERZ/.git" ]; then
        warnung "The project address still contains the placeholder PLACEHOLDER."
        warnung "The existing working copy in $QUELLVERZ is used instead."
        REPO=""
        return 0
    fi
    printf '\n' >&2
    printf '[camgrid] The project address is not set yet:\n' >&2
    printf '    %s\n' "$REPO" >&2
    printf '[camgrid] In netz-installation.sh, PLACEHOLDER must be replaced with your\n' >&2
    printf '[camgrid] own GitHub user name (line GITHUB_BENUTZER).\n' >&2
    printf '[camgrid] Quick fix without editing the file:\n' >&2
    printf '    curl -fsSL ... | sudo sh -s -- --repo https://github.com/NAME/camgrid.git\n' >&2
    printf '    or: CAMGRID_REPO=https://github.com/NAME/camgrid.git sudo -E sh netz-installation.sh\n' >&2
    printf '\n' >&2
    exit 1
}

# ---------------------------------------------------------------------- git --

installiere_git() {
    command -v git >/dev/null 2>&1 && return 0
    meldung "git is missing and will be installed ..."
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
        # On macOS git comes with the Xcode command line tools.
        xcode-select --install >/dev/null 2>&1 || true
        warnung "Please confirm the installation of the Xcode command line tools."
    fi
    command -v git >/dev/null 2>&1 \
        || fehler "git could not be installed. Please install it by hand and start again."
    meldung "git is present: $(git --version 2>/dev/null || printf 'git')"
}

# ------------------------------------------------------------ working copy --

hole_projekt() {
    if [ -d "$QUELLVERZ/.git" ]; then
        meldung "Updating the existing working copy: $QUELLVERZ"
        if [ -n "$REPO" ]; then
            git -C "$QUELLVERZ" remote set-url origin "$REPO" >/dev/null 2>&1 || true
        fi
        git -C "$QUELLVERZ" fetch --depth 1 origin "$ZWEIG" >/dev/null 2>&1 \
            || warnung "git fetch was not successful - the existing state is used."
        if ! git -C "$QUELLVERZ" reset --hard "origin/$ZWEIG" >/dev/null 2>&1; then
            git -C "$QUELLVERZ" pull --ff-only >/dev/null 2>&1 \
                || warnung "git pull was not successful - the existing state is used."
        fi
    else
        if [ -d "$QUELLVERZ" ] && [ -n "$(ls -A "$QUELLVERZ" 2>/dev/null || true)" ]; then
            fehler "$QUELLVERZ exists but is not a working copy. Please rename it or pass --quelle."
        fi
        meldung "Fetching the project: $REPO (branch $ZWEIG)"
        mkdir -p "$(dirname "$QUELLVERZ")"
        if ! git clone --depth 1 --branch "$ZWEIG" "$REPO" "$QUELLVERZ" >/dev/null 2>&1; then
            rm -rf "$QUELLVERZ"
            fehler "The project could not be cloned: $REPO (branch $ZWEIG)"
        fi
    fi

    [ -f "$QUELLVERZ/install.sh" ] \
        || fehler "$QUELLVERZ/install.sh is missing - is the project address correct?"
    chmod 0755 "$QUELLVERZ/install.sh" 2>/dev/null || true
    meldung "State: $(git -C "$QUELLVERZ" log -1 --format='%h %ad' --date=short 2>/dev/null || printf 'unknown')"
}

# --------------------------------------------------------------------- flow --

pruefe_platzhalter
installiere_git
hole_projekt

meldung "Starting install.sh ..."
if [ $# -gt 0 ]; then
    meldung "Parameters: $*"
fi
printf '\n'

cd "$QUELLVERZ"
# Without "|| ergebnis=$?" set -e would abort right here.
ergebnis=0
sh "$QUELLVERZ/install.sh" "$@" || ergebnis=$?

if [ "$ergebnis" = "0" ]; then
    meldung "Working copy for later updates: $QUELLVERZ"
    meldung "Update with: sudo sh $QUELLVERZ/netz-installation.sh"
fi
exit "$ergebnis"
