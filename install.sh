#!/bin/sh
# CamGrid - installation script for Linux (Debian/Raspberry Pi OS/Ubuntu,
# Fedora, Arch, openSUSE) and macOS.
#
# Sets up the admin server, the streaming service (go2rtc) and - if a
# graphical desktop is present - the kiosk display.
#
# Usage: sudo ./install.sh [--user NAME] [--no-kiosk] [--port N] [--help]
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

# Fixed initial credentials. They are deliberately well known and must be
# changed at the first login - see the note in the summary.
STANDARDBENUTZER="admin"
STANDARDPASSWORT="camgrid"

SKRIPTVERZ=$(cd "$(dirname "$0")" && pwd)
QUELLVERZ="$SKRIPTVERZ"        # this is where vendor/ and web/ live
TROCKEN="nein"                 # --dry-run: only show, change nothing

SYSTEM="unbekannt"             # linux or macos
PAKETVERWALTER="keiner"        # apt, dnf, pacman, zypper, brew, keiner
HAT_SYSTEMD="nein"
HAT_LAUNCHD="nein"
HAT_GRAFIK="unbekannt"
DIENSTART="keiner"             # systemd, launchd or keiner
CHROMIUM=""
GO2RTC_BEREIT="nein"
FEHLENDE_PAKETE=""
PROJEKTVERSION="unknown"
SCHRITT="start"

# ------------------------------------------------------------------ output ---

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

# Called on every unexpected abort (set -e or Ctrl+C), so that the user knows
# where it stopped and how to carry on.
abbruchhinweis() {
    code="$?"
    if [ "$code" != "0" ]; then
        printf '\n[camgrid] Aborted in step: %s\n' "$SCHRITT" >&2
        printf '[camgrid] The script can be run repeatedly - just start it again.\n' >&2
        printf '[camgrid] Remove everything again: sudo %s/uninstall.sh\n' "$SKRIPTVERZ" >&2
    fi
}

schritt() {
    SCHRITT="$1"
}

lies_projektversion() {
    for kandidat in "$SKRIPTVERZ/VERSION" "$ZIELVERZ/VERSION"; do
        if [ -r "$kandidat" ]; then
            PROJEKTVERSION=$(head -n 1 "$kandidat" | tr -d ' \t\r\n')
            [ -n "$PROJEKTVERSION" ] || PROJEKTVERSION="unknown"
            return 0
        fi
    done
    PROJEKTVERSION="unknown"
}

hilfe() {
    printf '%s\n' \
"CamGrid - installation (version $PROJEKTVERSION)" \
"" \
"Usage:" \
"  sudo ./install.sh [options]                (Linux, Raspberry Pi OS, macOS)" \
"" \
"Options:" \
"  --user NAME        Service user (default: user of the graphical session)" \
"  --no-kiosk         Only set up the services, no Chromium autostart" \
"  --port N           Port of the admin server (default: 8080)" \
"  --dry-run          Only show what would be done - changes nothing" \
"  --deinstallieren   Show how to remove it (see uninstall.sh)" \
"  --version          Show the project version" \
"  --help             Show this help" \
"" \
"The script can be run repeatedly. An existing configuration in" \
"$CONFVERZ/config.json is never overwritten." \
"" \
"Without a graphical desktop (server) the kiosk display is left out, the" \
"services are set up anyway. On macOS launchd services are used instead of" \
"systemd and there is no kiosk autostart."
}

deinstallationshinweis() {
    printf '%s\n' \
"CamGrid - uninstall" \
"" \
"uninstall.sh takes care of this:" \
"  sudo $SKRIPTVERZ/uninstall.sh              (you are asked about the configuration)" \
"  sudo $SKRIPTVERZ/uninstall.sh --behalten   (keep the configuration)" \
"  sudo $SKRIPTVERZ/uninstall.sh --alles      (delete $CONFVERZ as well)" \
"" \
"On Windows: powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall"
}

# -------------------------------------------------------------- parameters ---

lies_projektversion

while [ $# -gt 0 ]; do
    case "$1" in
        --user)
            [ $# -ge 2 ] || fehler "--user needs a user name."
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
            [ $# -ge 2 ] || fehler "--port needs a port number."
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
            fehler "Unknown option: $1 (see --help)"
            ;;
    esac
done

case "$ADMINPORT" in
    ''|*[!0-9]*) fehler "Invalid admin port: $ADMINPORT" ;;
esac
if [ "$ADMINPORT" -lt 1 ] || [ "$ADMINPORT" -gt 65535 ]; then
    fehler "Admin port out of range: $ADMINPORT"
fi
if [ "$ADMINPORT" = "$ANZEIGEPORT" ]; then
    fehler "The admin port must not be $ANZEIGEPORT - that one is used by the display."
fi

trap abbruchhinweis EXIT

# ----------------------------------------------------------- prerequisites ---

erkenne_system() {
    schritt "detect operating system"
    kern=$(uname -s 2>/dev/null || printf 'unknown')
    case "$kern" in
        Linux)  SYSTEM="linux" ;;
        Darwin) SYSTEM="macos" ;;
        *)
            if [ "$TROCKEN" = "ja" ]; then
                # So that the dry run can also be inspected under Git Bash or
                # WSL, Linux is assumed there.
                SYSTEM="linux"
                meldung "[Dry run] Unknown system kernel '$kern' - Linux is assumed."
            else
                fehler "Unsupported operating system: $kern. For Windows please use install.ps1."
            fi
            ;;
    esac

    beschreibung="$kern"
    if [ "$SYSTEM" = "linux" ] && [ -r /etc/os-release ]; then
        # Read it in a subshell, so that ID and VERSION do not overwrite the
        # script's own variables.
        beschreibung=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")
    elif [ "$SYSTEM" = "macos" ]; then
        beschreibung="macOS $(sw_vers -productVersion 2>/dev/null || printf 'unknown')"
    fi
    meldung "Operating system: $beschreibung"

    if [ "$SYSTEM" = "macos" ] && [ "$KIOSK" = "ja" ]; then
        KIOSK="nein"
        meldung "macOS: no kiosk autostart (the note about full screen is at the end)."
    fi
}

pruefe_root() {
    schritt "check rights"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Dry run] The rights are not checked."
        return 0
    fi
    [ "$(id -u)" = "0" ] || fehler "Please run with root rights, for example: sudo ./install.sh"
}

erkenne_dienstverwaltung() {
    schritt "detect service manager"
    if [ "$SYSTEM" = "macos" ]; then
        if command -v launchctl >/dev/null 2>&1; then
            HAT_LAUNCHD="ja"
            DIENSTART="launchd"
            meldung "Service manager: launchd"
        else
            DIENSTART="keiner"
            warnung "launchctl is missing - the services are only set up, not started."
        fi
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        HAT_SYSTEMD="ja"
        DIENSTART="systemd"
        meldung "Service manager: systemd"
    elif command -v systemctl >/dev/null 2>&1; then
        warnung "systemd is installed but not running (/run/systemd/system is missing)."
    else
        warnung "No systemd found - no autostart services are set up."
    fi

    if [ "$DIENSTART" = "keiner" ]; then
        warnung "Start it by hand then: python3 $ZIELVERZ/app/dienst.py --mit-server --config $CONFVERZ/config.json"
    fi
}

erkenne_paketverwalter() {
    schritt "detect package manager"
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
            warnung "No known package manager found (apt, dnf, pacman, zypper, brew)."
            warnung "Missing programs are only named, not installed automatically."
            ;;
        *)
            meldung "Package manager: $PAKETVERWALTER"
            ;;
    esac
}

ermittle_architektur() {
    schritt "detect architecture"
    maschine=$(uname -m)
    if [ "$SYSTEM" = "macos" ]; then
        case "$maschine" in
            arm64|aarch64) GO2RTC_DATEI="go2rtc_mac_arm64" ;;
            x86_64|amd64)  GO2RTC_DATEI="go2rtc_mac_amd64" ;;
            *) fehler "Unsupported architecture on macOS: $maschine" ;;
        esac
    else
        case "$maschine" in
            aarch64|arm64)      GO2RTC_DATEI="go2rtc_linux_arm64" ;;
            armv7l|armv7|armhf) GO2RTC_DATEI="go2rtc_linux_arm" ;;
            armv6l)             GO2RTC_DATEI="go2rtc_linux_armv6" ;;
            x86_64|amd64)       GO2RTC_DATEI="go2rtc_linux_amd64" ;;
            *)
                fehler "Unsupported architecture: $maschine (expected arm64, armv7, armv6 or amd64)."
                ;;
        esac
    fi
    meldung "Architecture: $maschine -> $GO2RTC_DATEI"
}

# On a server without a screen the kiosk part may simply be left out - that is
# not an error.
erkenne_grafik() {
    schritt "check graphical desktop"
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
        meldung "Graphical desktop: present."
    else
        meldung "Graphical desktop: none found - server mode."
        if [ "$KIOSK" = "ja" ]; then
            KIOSK="nein"
            meldung "The kiosk display is therefore left out. The display page stays reachable over the network."
        fi
    fi
}

# ------------------------------------------------------------- service user --

# Home directory of a user; getent does not exist on macOS.
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
    schritt "determine service user"
    if [ "$TROCKEN" = "ja" ]; then
        if [ -z "$DIENSTBENUTZER" ]; then DIENSTBENUTZER="$(id -un 2>/dev/null || echo pi)"; fi
        BENUTZERHEIM="${HOME:-/home/$DIENSTBENUTZER}"
        BENUTZERGRUPPE="$DIENSTBENUTZER"
        meldung "[Dry run] The service user would be: $DIENSTBENUTZER"
        return 0
    fi
    if [ -n "$DIENSTBENUTZER" ]; then
        return 0
    fi

    # 1. Owner of a graphical session
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

    # 2. Calling user
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

    # 3. First regular user of the system
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

    # 4. Last resort on a pure server: create a dedicated system user.
    if [ "$SYSTEM" = "linux" ] && command -v useradd >/dev/null 2>&1; then
        meldung "No regular user found - the system user 'camgrid' is created."
        useradd --system --create-home --home-dir /var/lib/camgrid-heim \
                --shell /bin/sh camgrid >/dev/null 2>&1 \
            || useradd -r -m -d /var/lib/camgrid-heim camgrid >/dev/null 2>&1 \
            || fehler "The user 'camgrid' could not be created. Please pass --user NAME."
        DIENSTBENUTZER="camgrid"
        return 0
    fi

    fehler "The service user cannot be determined. Please pass --user NAME."
}

pruefe_dienstbenutzer() {
    schritt "check service user"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Dry run] The service user is not checked."
        return 0
    fi
    id "$DIENSTBENUTZER" >/dev/null 2>&1 \
        || fehler "The user '$DIENSTBENUTZER' does not exist."
    [ "$DIENSTBENUTZER" != "root" ] \
        || fehler "root is not allowed as the service user. Please pass --user NAME."
    BENUTZERGRUPPE=$(id -gn "$DIENSTBENUTZER")
    BENUTZERHEIM=$(heimatverzeichnis "$DIENSTBENUTZER")
    if [ -z "$BENUTZERHEIM" ] || [ ! -d "$BENUTZERHEIM" ]; then
        fehler "The home directory of '$DIENSTBENUTZER' was not found."
    fi
    meldung "Service user: $DIENSTBENUTZER (group $BENUTZERGRUPPE, home $BENUTZERHEIM)"
}

# ---------------------------------------------------------------- packages ---

# Package name for a command - different per package manager.
# Empty output means: no package is known for it.
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

# Can this package manager install without asking?
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
        *)      printf 'install with the package manager of the system:' ;;
    esac
}

LISTEN_AKTUELL="nein"

listen_aktualisieren() {
    [ "$LISTEN_AKTUELL" = "nein" ] || return 0
    LISTEN_AKTUELL="ja"
    case "$PAKETVERWALTER" in
        apt)
            meldung "Updating the package lists ..."
            DEBIAN_FRONTEND=noninteractive apt-get update -qq \
                || warnung "apt-get update was not successful - the installation is attempted anyway."
            ;;
        pacman)
            meldung "Updating the package lists ..."
            pacman -Sy --noconfirm >/dev/null 2>&1 \
                || warnung "pacman -Sy was not successful - the installation is attempted anyway."
            ;;
    esac
}

# Installs the package for a command. Return value 0 = the command is there now.
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
    meldung "Installing package: $paket"
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
    schritt "check packages"
    if [ "$TROCKEN" = "ja" ]; then
        if kann_installieren; then
            meldung "[Dry run] Missing packages would be installed with $PAKETVERWALTER."
        elif [ "$PAKETVERWALTER" = "keiner" ]; then
            meldung "[Dry run] Missing packages would only be named (no known package manager)."
        else
            meldung "[Dry run] Missing packages would only be named (package manager: $PAKETVERWALTER)."
        fi
        return 0
    fi
    meldung "Checking the programs ..."

    # Mandatory: nothing runs without Python 3.
    if ! command -v python3 >/dev/null 2>&1; then
        paket_installieren python3 || true
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        paket=$(paketname python3)
        fehler "Python 3 is missing. Please install it: $(installationsbefehl) ${paket:-python3}"
    fi

    # Useful, but not strictly required.
    for befehl in curl ffmpeg; do
        command -v "$befehl" >/dev/null 2>&1 && continue
        paket_installieren "$befehl" || true
        command -v "$befehl" >/dev/null 2>&1 \
            || warnung "'$befehl' is missing. Without curl there is no download, without ffmpeg no transcoding."
    done

    if [ "$KIOSK" != "ja" ]; then
        meldung "Without the kiosk display, Chromium and the X11 tools are not needed."
        return 0
    fi

    # Only for the kiosk display: X11 tools and Chromium.
    for befehl in xset xrandr ss flock scrot; do
        command -v "$befehl" >/dev/null 2>&1 && continue
        paket_installieren "$befehl" || true
        command -v "$befehl" >/dev/null 2>&1 \
            || warnung "'$befehl' is missing - the kiosk display keeps working with limitations."
    done

    CHROMIUM=$(finde_chromium || true)
    if [ -z "$CHROMIUM" ]; then
        paket_installieren chromium || true
        CHROMIUM=$(finde_chromium || true)
    fi
    if [ -z "$CHROMIUM" ] && [ "$PAKETVERWALTER" = "apt" ]; then
        # On older Debian versions the package has a different name.
        meldung "Installing package: chromium-browser"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            chromium-browser >/dev/null 2>&1 || true
        CHROMIUM=$(finde_chromium || true)
    fi
    if [ -z "$CHROMIUM" ]; then
        KIOSK="nein"
        merke_fehlendes_paket "chromium"
        warnung "Chromium is not present - the kiosk display is skipped."
        warnung "After installing it, just run install.sh again."
    else
        meldung "Chromium: $CHROMIUM"
    fi
}

# ------------------------------------------------------------- directories ---

lege_verzeichnisse_an() {
    schritt "create directories"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Dry run] These directories would be created: $ZIELVERZ $CONFVERZ $LOGVERZ $DATAVERZ"
        return 0
    fi
    meldung "Creating the directories ..."

    mkdir -p "$ZIELVERZ" "$ZIELVERZ/bin" "$ZIELVERZ/web/public"
    mkdir -p "$CONFVERZ" "$LOGVERZ" "$DATAVERZ"

    chown root:"$(id -gn root 2>/dev/null || printf 'root')" "$ZIELVERZ" 2>/dev/null \
        || chown root "$ZIELVERZ" 2>/dev/null || true
    chmod 0755 "$ZIELVERZ"

    chown -R "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$CONFVERZ" "$LOGVERZ" "$DATAVERZ"
    chmod 0750 "$CONFVERZ"
    chmod 0755 "$LOGVERZ" "$DATAVERZ"

    # Prepare the log file of the kiosk display
    if [ ! -f "$LOGVERZ/kiosk.log" ]; then
        : > "$LOGVERZ/kiosk.log"
    fi
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$LOGVERZ/kiosk.log"
    chmod 0644 "$LOGVERZ/kiosk.log"
}

kopiere_programmdateien() {
    schritt "copy program files"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Dry run] The program files would be copied to $ZIELVERZ."
        return 0
    fi
    if [ "$SKRIPTVERZ" = "$ZIELVERZ" ]; then
        meldung "The program files are already in $ZIELVERZ - no copying needed."
        return 0
    fi

    meldung "Copying the program files to $ZIELVERZ ..."
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

    # app/streams.py puts anzeige.json next to the display page; that
    # directory has to belong to the service user.
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
            warnung "The latest go2rtc version cannot be determined - falling back to $GO2RTC_FESTVERSION."
            printf '%s' "$GO2RTC_FESTVERSION"
            ;;
    esac
}

# Asks only when input is possible. With 'curl ... | sudo sh' there is no
# terminal - then it downloads, because that is exactly what was wanted.
frage_ja() {
    if [ ! -t 0 ]; then
        meldung "$1 (no input possible - it is downloaded)"
        return 0
    fi
    printf '[camgrid] %s [Y/n] ' "$1"
    read -r antwort || antwort=""
    case "$antwort" in
        n|N|no|No|NO|nein|Nein|NEIN) return 1 ;;
        *) return 0 ;;
    esac
}

# Downloads go2rtc from GitHub. For macOS it is a ZIP archive there.
lade_go2rtc_aus_netz() {
    ziel="$1"
    command -v curl >/dev/null 2>&1 || { warnung "curl is missing - go2rtc cannot be downloaded."; return 1; }
    GO2RTC_VERSION=$(ermittle_go2rtc_version)
    zwischen="$ZIELVERZ/bin/go2rtc.neu.$$"
    rm -f "$zwischen" "$zwischen.zip"

    if [ "$SYSTEM" = "macos" ]; then
        quelle="https://github.com/$GO2RTC_REPO/releases/download/$GO2RTC_VERSION/$GO2RTC_DATEI.zip"
        meldung "Downloading go2rtc $GO2RTC_VERSION: $quelle"
        if ! curl -fsSL --max-time 300 -o "$zwischen.zip" "$quelle"; then
            rm -f "$zwischen.zip"
            warnung "Download failed: $quelle"
            return 1
        fi
        if ! command -v unzip >/dev/null 2>&1; then
            rm -f "$zwischen.zip"
            warnung "unzip is missing - $GO2RTC_DATEI.zip cannot be extracted."
            return 1
        fi
        entpackt="$ZIELVERZ/bin/entpackt.$$"
        mkdir -p "$entpackt"
        if ! unzip -o -q "$zwischen.zip" -d "$entpackt" 2>/dev/null; then
            rm -rf "$entpackt" "$zwischen.zip"
            warnung "The archive could not be extracted."
            return 1
        fi
        gefunden=$(find "$entpackt" -type f -name 'go2rtc*' | head -n 1)
        if [ -z "$gefunden" ]; then
            rm -rf "$entpackt" "$zwischen.zip"
            warnung "There was no go2rtc program in the archive."
            return 1
        fi
        mv -f "$gefunden" "$zwischen"
        rm -rf "$entpackt" "$zwischen.zip"
    else
        quelle="https://github.com/$GO2RTC_REPO/releases/download/$GO2RTC_VERSION/$GO2RTC_DATEI"
        meldung "Downloading go2rtc $GO2RTC_VERSION: $quelle"
        if ! curl -fsSL --max-time 300 -o "$zwischen" "$quelle"; then
            rm -f "$zwischen"
            warnung "Download failed: $quelle"
            return 1
        fi
    fi

    chmod 0755 "$zwischen"
    if ! "$zwischen" --version >/dev/null 2>&1; then
        rm -f "$zwischen"
        warnung "The downloaded go2rtc does not run on this system (wrong architecture?)."
        return 1
    fi
    mv -f "$zwischen" "$ziel"
    chmod 0755 "$ziel"
    meldung "go2rtc installed: $ziel"
    return 0
}

lade_go2rtc() {
    schritt "set up go2rtc"
    ziel="$ZIELVERZ/bin/go2rtc"
    mitgeliefert="$QUELLVERZ/vendor/go2rtc/$GO2RTC_DATEI"
    if [ -r "$QUELLVERZ/vendor/go2rtc/VERSION" ]; then
        GO2RTC_VERSION=$(head -n 1 "$QUELLVERZ/vendor/go2rtc/VERSION" | tr -d ' \t\r\n')
    else
        GO2RTC_VERSION="$GO2RTC_FESTVERSION"
    fi

    if [ "$TROCKEN" = "ja" ]; then
        if [ -r "$mitgeliefert" ]; then
            meldung "[Dry run] Copy go2rtc $GO2RTC_VERSION from the project: $mitgeliefert -> $ziel"
        else
            meldung "[Dry run] go2rtc is missing in the project ($mitgeliefert) - it would be downloaded from GitHub."
        fi
        GO2RTC_BEREIT="ja"
        return 0
    fi

    if [ -x "$ziel" ] && "$ziel" --version >/dev/null 2>&1; then
        meldung "go2rtc is already installed."
        GO2RTC_BEREIT="ja"
        return 0
    fi

    # The normal case on Linux: the program is part of the project and is only
    # copied. That way the installation needs no internet connection.
    if [ -r "$mitgeliefert" ]; then
        meldung "Installing go2rtc $GO2RTC_VERSION from the project ($GO2RTC_DATEI) ..."
        cp -f "$mitgeliefert" "$ziel"
        chmod 0755 "$ziel"
        if ! "$ziel" --version >/dev/null 2>&1; then
            rm -f "$ziel"
            warnung "The bundled go2rtc does not run on this system (wrong architecture?)."
        else
            meldung "go2rtc installed: $ziel"
            GO2RTC_BEREIT="ja"
            return 0
        fi
    else
        warnung "go2rtc for this system is not part of the project: $mitgeliefert"
        if [ "$SYSTEM" = "macos" ]; then
            warnung "For macOS go2rtc is not bundled (only Linux and Windows)."
        fi
    fi

    if frage_ja "Download go2rtc from GitHub now ($GO2RTC_DATEI)?"; then
        if lade_go2rtc_aus_netz "$ziel"; then
            GO2RTC_BEREIT="ja"
            return 0
        fi
    else
        meldung "No download - the installation is finished without the streaming service."
    fi

    GO2RTC_BEREIT="nein"
    warnung "Without go2rtc there are no video images. The admin interface still runs."
    warnung "To add it later: get the file $GO2RTC_DATEI from https://github.com/$GO2RTC_REPO/releases,"
    warnung "put it at $ziel, make it executable (chmod +x) and run install.sh again."
}

lade_weboberflaeche() {
    schritt "provide display components"
    # video-rtc.js and video-stream.js are part of the project and are only copied.
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Dry run] Copy the playback components to $ZIELVERZ/web/public"
        return 0
    fi
    mkdir -p "$ZIELVERZ/web/public"
    for datei in video-rtc.js video-stream.js; do
        quelle="$QUELLVERZ/web/public/$datei"
        if [ -r "$quelle" ]; then
            cp -f "$quelle" "$ZIELVERZ/web/public/$datei"
            chmod 0644 "$ZIELVERZ/web/public/$datei"
        elif [ -s "$ZIELVERZ/web/public/$datei" ]; then
            warnung "$datei is missing in the project - the existing version stays."
        else
            fehler "$datei is missing in the project ($quelle) - the display would show no image."
        fi
    done
    meldung "Playback components provided."
}

# ------------------------------------------------------------ configuration -

# The initial configuration is created by app/config.py, so that there is only
# one source for the layout of the file. If that fails, the script writes an
# equivalent minimal version itself.
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

# Sets the fixed initial credentials in a freshly created file.
# Existing configurations are never touched.
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
    schritt "create configuration"
    if [ "$TROCKEN" = "ja" ]; then
        meldung "[Dry run] The configuration $CONFVERZ/config.json would be created (an existing one stays unchanged)."
        meldung "[Dry run] The initial login would be: $STANDARDBENUTZER / $STANDARDPASSWORT"
        ADMINPASSWORT="$STANDARDPASSWORT"
        return 0
    fi
    ADMINPASSWORT=""
    ziel="$CONFVERZ/config.json"
    if [ -f "$ziel" ]; then
        meldung "The configuration $ziel exists and stays unchanged."
        if [ "$ADMINPORT" != "8080" ]; then
            warnung "--port $ADMINPORT is ignored: the port is taken from the existing configuration."
        fi
        return 0
    fi

    meldung "Creating the initial configuration: $ziel"
    if ! erzeuge_konfiguration_python "$ziel" >/dev/null 2>&1 || [ ! -s "$ziel" ]; then
        warnung "app/config.py could not create the configuration - a minimal version is written."
        rm -f "$ziel"
        erzeuge_konfiguration_notfall "$ziel"
    fi
    [ -s "$ziel" ] || fehler "The configuration $ziel could not be written."

    # Enforce the fixed initial credentials, no matter what app/config.py
    # brings along as its default.
    if ! setze_standardzugang "$ziel" >/dev/null 2>&1; then
        warnung "The initial credentials could not be set - please check $ziel."
    fi
    ADMINPASSWORT="$STANDARDPASSWORT"

    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$ziel"
    chmod 0600 "$ziel"
}

richte_schluesselbund_ein() {
    schritt "check keyring"
    if [ "$TROCKEN" = "ja" ] || [ "$SYSTEM" != "linux" ]; then
        return 0
    fi
    ziel="$CONFVERZ/keyring.pw"
    if [ -f "$ziel" ]; then
        chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$ziel"
        chmod 0600 "$ziel"
        meldung "Password file of the keyring found - permissions set to 600."
    fi
}

# ---------------------------------------------------------------- services --

ermittle_python() {
    PYTHON3=$(command -v python3 2>/dev/null || true)
    if [ -z "$PYTHON3" ]; then
        PYTHON3="/usr/bin/python3"
    fi
}

installiere_dienste_systemd() {
    meldung "Installing the systemd units ..."
    for einheit in camgrid-admin.service camgrid-go2rtc.service; do
        if [ "$einheit" = "camgrid-go2rtc.service" ] && [ "$GO2RTC_BEREIT" != "ja" ]; then
            meldung "camgrid-go2rtc is skipped (go2rtc is missing)."
            # A unit installed earlier would otherwise keep failing.
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
        [ -f "$quelle" ] || fehler "Unit file is missing: systemd/$einheit"
        sed -e "s|__DIENSTBENUTZER__|$DIENSTBENUTZER|g" \
            -e "s|__DIENSTGRUPPE__|$BENUTZERGRUPPE|g" \
            -e "s|__PYTHON__|$PYTHON3|g" \
            "$quelle" > "$SYSTEMDVERZ/$einheit"
        chmod 0644 "$SYSTEMDVERZ/$einheit"
    done

    systemctl daemon-reload
    if [ "$GO2RTC_BEREIT" = "ja" ]; then
        systemctl enable --now camgrid-go2rtc.service \
            || warnung "camgrid-go2rtc is not running (check with: journalctl -u camgrid-go2rtc)."
    fi
    systemctl enable --now camgrid-admin.service \
        || warnung "camgrid-admin is not running (check with: journalctl -u camgrid-admin)."
}

# launchd has no ExecStartPre - that is why go2rtc is started through
# scripts/go2rtc-start.sh, which creates go2rtc.yaml beforehand.
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
        warnung "The user id of $DIENSTBENUTZER cannot be determined - please load $label by hand."
        return 1
    fi
    # Unload first, so that a repeated run does not fail (idempotency).
    sudo -u "$DIENSTBENUTZER" launchctl bootout "gui/$kennung/$label" >/dev/null 2>&1 || true
    sudo -u "$DIENSTBENUTZER" launchctl unload "$plist" >/dev/null 2>&1 || true

    if sudo -u "$DIENSTBENUTZER" launchctl bootstrap "gui/$kennung" "$plist" >/dev/null 2>&1; then
        meldung "launchd service loaded: $label"
        return 0
    fi
    if sudo -u "$DIENSTBENUTZER" launchctl load -w "$plist" >/dev/null 2>&1; then
        meldung "launchd service loaded (load -w): $label"
        return 0
    fi
    warnung "$label could not be loaded. By hand (as $DIENSTBENUTZER):"
    warnung "  launchctl bootstrap gui/\$(id -u) $plist"
    return 1
}

installiere_dienste_launchd() {
    agentverz="$BENUTZERHEIM/Library/LaunchAgents"
    mkdir -p "$agentverz"
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$agentverz" 2>/dev/null || true

    adminplist="$agentverz/de.camgrid.admin.plist"
    go2rtcplist="$agentverz/de.camgrid.go2rtc.plist"

    meldung "Setting up the launchd services: $agentverz"
    schreibe_launchd_plist "de.camgrid.admin" "$adminplist" "$LOGVERZ/admin.log" \
        "$PYTHON3" "$ZIELVERZ/app/server.py" "--config" "$CONFVERZ/config.json"
    launchd_laden "de.camgrid.admin" "$adminplist" || true

    if [ "$GO2RTC_BEREIT" = "ja" ]; then
        schreibe_launchd_plist "de.camgrid.go2rtc" "$go2rtcplist" "$LOGVERZ/go2rtc.log" \
            "/bin/sh" "$ZIELVERZ/scripts/go2rtc-start.sh"
        launchd_laden "de.camgrid.go2rtc" "$go2rtcplist" || true
    else
        meldung "de.camgrid.go2rtc is skipped (go2rtc is missing)."
        rm -f "$go2rtcplist"
    fi
}

installiere_dienste() {
    schritt "set up services"
    ermittle_python
    if [ "$TROCKEN" = "ja" ]; then
        case "$DIENSTART" in
            systemd) meldung "[Dry run] The systemd services would be set up and started." ;;
            launchd) meldung "[Dry run] The launchd services in ~/Library/LaunchAgents would be set up." ;;
            *)       meldung "[Dry run] No service manager - it would have to be started by hand." ;;
        esac
        return 0
    fi

    case "$DIENSTART" in
        systemd) installiere_dienste_systemd ;;
        launchd) installiere_dienste_launchd ;;
        *)
            warnung "No service manager present - nothing is started automatically."
            meldung "Start it by hand (in the foreground):"
            meldung "  $PYTHON3 $ZIELVERZ/app/dienst.py --mit-server --config $CONFVERZ/config.json"
            ;;
    esac
}

# --------------------------------------------------------------- autostart --

schreibe_autostart() {
    schritt "set up autostart"
    if [ "$SYSTEM" != "linux" ]; then
        return 0
    fi
    if [ "$TROCKEN" = "ja" ]; then
        if [ "$KIOSK" = "ja" ]; then
            meldung "[Dry run] The kiosk autostart in ~/.config/autostart would be created."
        else
            meldung "[Dry run] No kiosk autostart (switched off or no desktop)."
        fi
        return 0
    fi
    if [ "$HAT_GRAFIK" != "ja" ] && [ "$KIOSK" != "ja" ]; then
        meldung "Without a graphical desktop no autostart is created."
        # Clean up leftovers of an earlier installation that had a screen.
        for alt_datei in camgrid-kiosk.desktop camgrid-keyring.desktop; do
            if [ -f "$BENUTZERHEIM/.config/autostart/$alt_datei" ]; then
                rm -f "$BENUTZERHEIM/.config/autostart/$alt_datei"
                meldung "Old autostart entry removed: $alt_datei"
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
            meldung "Kiosk autostart removed."
        else
            meldung "The kiosk autostart is not created."
        fi
    else
        meldung "Autostart of the display: $kioskdatei"
        {
            printf '[Desktop Entry]\n'
            printf 'Type=Application\n'
            printf 'Name=CamGrid Display\n'
            printf 'Comment=Starts the camera wall in kiosk mode\n'
            printf 'Exec=%s/scripts/kiosk.sh\n' "$ZIELVERZ"
            printf 'Terminal=false\n'
            printf 'X-GNOME-Autostart-enabled=true\n'
        } > "$kioskdatei"
        chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$kioskdatei"
        chmod 0644 "$kioskdatei"
    fi

    meldung "Autostart of the keyring: $keyringdatei"
    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=CamGrid Keyring\n'
        printf 'Comment=Unlocks the GNOME keyring without keyboard input\n'
        printf 'Exec=%s/scripts/keyring.sh\n' "$ZIELVERZ"
        printf 'Terminal=false\n'
        printf 'X-GNOME-Autostart-enabled=true\n'
    } > "$keyringdatei"
    chown "$DIENSTBENUTZER:$BENUTZERGRUPPE" "$keyringdatei"
    chmod 0644 "$keyringdatei"
}

# ----------------------------------------------------------------- sudoers --

# The rule only allows the service user to restart its own services and to
# reboot the device - both from the dashboard.
schreibe_sudoers() {
    schritt "create sudoers rule"
    if [ "$TROCKEN" = "ja" ]; then
        if [ "$SYSTEM" = "linux" ] && [ "$DIENSTART" = "systemd" ]; then
            meldung "[Dry run] The sudoers rule $SUDOERSDATEI would be created."
        else
            meldung "[Dry run] No sudoers rule needed (only useful with systemd)."
        fi
        return 0
    fi
    if [ "$SYSTEM" != "linux" ] || [ "$DIENSTART" != "systemd" ]; then
        meldung "No sudoers rule needed (only useful with systemd)."
        return 0
    fi
    if ! command -v visudo >/dev/null 2>&1; then
        warnung "visudo is missing - the sudoers rule is not created."
        warnung "Without it the dashboard cannot restart the services itself."
        return 0
    fi
    meldung "Creating the sudoers rule: $SUDOERSDATEI"

    sicherung=""
    if [ -f "$SUDOERSDATEI" ]; then
        sicherung="$SUDOERSDATEI.sicherung.$$"
        cp -a "$SUDOERSDATEI" "$sicherung"
    fi

    neu="$SUDOERSDATEI.neu.$$"
    {
        printf '# CamGrid - created by install.sh, do not edit by hand.\n'
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
            fehler "The sudoers rule is faulty - the previous version was restored."
        fi
        fehler "The sudoers rule is faulty and was not applied."
    fi

    # Check the whole file, so that a broken sudo shows up right away
    if ! visudo -c >/dev/null 2>&1; then
        rm -f "$SUDOERSDATEI"
        fehler "The overall check of sudoers failed - the rule was removed again."
    fi
    meldung "sudoers rule checked (visudo -c)."
}

# ------------------------------------------------------------------ summary --

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
        adresse="<ip-address>"
    fi
    printf '%s' "$adresse"
}

lies_port() {
    # lies_port <key> <fallback>
    wert=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "$CONFVERZ/config.json" 2>/dev/null | head -n 1 || true)
    case "${wert:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$wert" ;;
    esac
}

zusammenfassung() {
    schritt "summary"
    ip=$(ermittle_ip)
    port=$(lies_port admin_port "$ADMINPORT")
    ANZEIGEPORT=$(lies_port go2rtc_port "$ANZEIGEPORT")

    printf '\n'
    printf '========================================================\n'
    if [ "$TROCKEN" = "ja" ]; then
        printf ' CamGrid %s - dry run finished (nothing changed)\n' "$PROJEKTVERSION"
    else
        printf ' CamGrid %s - installation finished\n' "$PROJEKTVERSION"
    fi
    printf '========================================================\n'
    printf '\n'
    printf ' Addresses\n'
    printf '   Admin   : http://%s:%s\n' "$ip" "$port"
    printf '   Display : http://%s:%s/?monitor=1\n' "$ip" "$ANZEIGEPORT"
    printf '\n'
    printf ' Credentials\n'
    if [ -n "${ADMINPASSWORT:-}" ]; then
        printf '   User     : %s\n' "$STANDARDBENUTZER"
        printf '   Password : %s\n' "$ADMINPASSWORT"
        printf '   >>> This is the well-known default. Please set your own password\n'
        printf '   >>> in the admin interface IMMEDIATELY after the first login.\n'
    else
        printf '   Unchanged (the existing configuration was kept).\n'
        printf '   Default for a fresh installation: %s / %s\n' "$STANDARDBENUTZER" "$STANDARDPASSWORT"
    fi
    printf '\n'
    printf ' Paths\n'
    printf '   Program        : %s\n' "$ZIELVERZ"
    printf '   Configuration  : %s/config.json\n' "$CONFVERZ"
    printf '   Logs           : %s\n' "$LOGVERZ"
    printf '   Runtime data   : %s (go2rtc.yaml)\n' "$DATAVERZ"
    printf '   Service user   : %s\n' "$DIENSTBENUTZER"
    printf '\n'
    if [ -n "$FEHLENDE_PAKETE" ]; then
        printf ' Please install the missing packages\n'
        printf '   %s%s\n' "$(installationsbefehl)" "$FEHLENDE_PAKETE"
        printf '   After that, just run install.sh again.\n'
        printf '\n'
    fi
    if [ "$GO2RTC_BEREIT" != "ja" ]; then
        printf ' Installed without the streaming service\n'
        printf '   go2rtc is missing. Get the file %s from\n' "$GO2RTC_DATEI"
        printf '   https://github.com/%s/releases, put it at\n' "$GO2RTC_REPO"
        printf '   %s/bin/go2rtc, run chmod +x on it and start install.sh again.\n' "$ZIELVERZ"
        printf '\n'
    fi
    printf ' Next steps\n'
    printf '   1. Open the admin interface in a browser, change the password, add cameras.\n'
    printf '   2. Set the monitors, the outputs and the tile grid.\n'
    if [ "$SYSTEM" = "macos" ]; then
        printf '   3. Open the display full screen (no autostart on macOS):\n'
        printf '      open -a "Google Chrome" --args --kiosk "http://127.0.0.1:%s/?monitor=1"\n' "$ANZEIGEPORT"
        printf '      or open Safari and switch to full screen with Ctrl+Cmd+F.\n'
    elif [ "$KIOSK" = "ja" ]; then
        printf '   3. Reboot the device (sudo reboot) - the display then starts on its own.\n'
        printf '      Check it right away: %s/scripts/kiosk.sh --neustart\n' "$ZIELVERZ"
    else
        printf '   3. No kiosk display was set up.\n'
        printf '      Display over the network: http://%s:%s/?monitor=1\n' "$ip" "$ANZEIGEPORT"
        printf '      Start it by hand: %s/scripts/kiosk.sh\n' "$ZIELVERZ"
    fi
    printf '\n'
    printf ' Check the services\n'
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
    printf ' Remove\n'
    printf '   sudo %s/uninstall.sh\n' "$ZIELVERZ"
    printf '\n'
}

# --------------------------------------------------------------------- flow --

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
