"""Startet und überwacht den Streaming-Dienst go2rtc.

Auf einem installierten System übernimmt das systemd. Zum Ausprobieren und
Entwickeln startet dieses Modul go2rtc selbst - mit dem mitgelieferten Binary
aus vendor/, ohne Installation und ohne Internet.

    python3 -m app.dienst --mit-server     Streaming-Dienst und Dashboard starten
    python3 -m app.dienst --nur-go2rtc     nur den Streaming-Dienst
"""

from __future__ import annotations

import argparse
import atexit
import os
import platform
import shutil
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config as konfig  # noqa: E402
from app import streams  # noqa: E402

WURZEL = Path(__file__).resolve().parent.parent
VENDOR = WURZEL / "vendor" / "go2rtc"
INSTALLIERT = Path("/opt/camgrid/bin/go2rtc")

_prozess: subprocess.Popen | None = None
_sperre = threading.Lock()


# --------------------------------------------------------------------------
# Programmdatei finden
# --------------------------------------------------------------------------

def binary_pfad() -> Path | None:
    """Das zum System passende go2rtc-Programm, oder None."""
    if INSTALLIERT.is_file():
        return INSTALLIERT

    system = platform.system().lower()
    maschine = platform.machine().lower()

    if system == "windows":
        kandidaten = ["go2rtc.exe"]
    elif maschine in ("aarch64", "arm64"):
        kandidaten = ["go2rtc_linux_arm64"]
    elif maschine.startswith("arm"):
        kandidaten = ["go2rtc_linux_arm"]
    elif maschine in ("x86_64", "amd64"):
        kandidaten = ["go2rtc_linux_amd64"]
    else:
        kandidaten = []

    for name in kandidaten:
        pfad = VENDOR / name
        if pfad.is_file():
            return pfad

    gefunden = shutil.which("go2rtc")
    return Path(gefunden) if gefunden else None


def version() -> str:
    datei = VENDOR / "VERSION"
    try:
        return datei.read_text(encoding="utf-8").strip() or "unbekannt"
    except OSError:
        return "unbekannt"


# --------------------------------------------------------------------------
# Zustand
# --------------------------------------------------------------------------

def _port(wert, vorgabe: int = 1984) -> int:
    """Portnummer aus der Konfiguration, notfalls die Vorgabe."""
    try:
        zahl = int(wert)
    except (TypeError, ValueError, OverflowError):
        return vorgabe
    return zahl if 1 <= zahl <= 65535 else vorgabe


def erreichbar(port: int, host: str = "127.0.0.1", timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def von_systemd_verwaltet() -> bool:
    """Läuft go2rtc bereits als Systemdienst? Dann hier die Finger davon lassen."""
    if not shutil.which("systemctl"):
        return False
    try:
        ergebnis = subprocess.run(
            ["systemctl", "is-active", "camgrid-go2rtc"],
            capture_output=True, text=True, timeout=5, check=False,
        )
        return ergebnis.stdout.strip() in ("active", "activating")
    except (OSError, subprocess.SubprocessError):
        return False


# --------------------------------------------------------------------------
# Starten und Beenden
# --------------------------------------------------------------------------

def starten(daten: dict | None = None, log_pfad: Path | None = None) -> tuple[bool, str]:
    """Startet go2rtc als Kindprozess. Läuft er schon, passiert nichts."""
    global _prozess

    daten = daten if isinstance(daten, dict) else konfig.laden()
    port = _port(daten.get("dienste", {}).get("go2rtc_port"))

    with _sperre:
        if _prozess and _prozess.poll() is None:
            return True, "Streaming-Dienst läuft bereits (von hier gestartet)."
        if von_systemd_verwaltet():
            return True, "Streaming-Dienst läuft als Systemdienst."
        if erreichbar(port):
            return True, f"Auf Port {port} antwortet bereits ein Dienst."

        programm = binary_pfad()
        if not programm:
            return False, (f"Kein go2rtc-Programm für dieses System gefunden "
                           f"({platform.system()} {platform.machine()}). "
                           f"Erwartet in {VENDOR}.")

        yaml_pfad = Path(streams.schreiben(daten)).resolve()

        log_pfad = log_pfad or Path(os.environ.get(
            "CAMGRID_LOG", str(yaml_pfad.parent / "go2rtc.log")))
        log_pfad.parent.mkdir(parents=True, exist_ok=True)
        log = open(log_pfad, "a", encoding="utf-8", errors="replace")  # noqa: SIM115

        try:
            _prozess = subprocess.Popen(
                [str(programm.resolve()), "-config", str(yaml_pfad)],
                stdout=log, stderr=subprocess.STDOUT,
                cwd=str(yaml_pfad.parent),
                start_new_session=(os.name != "nt"),
            )
        except OSError as fehler:
            return False, f"Start fehlgeschlagen: {fehler}"
        finally:
            # Der Kindprozess hat seine eigene Kopie der Datei; unsere wird
            # nicht mehr gebraucht. Ohne dieses Schließen bleibt bei jedem
            # Startversuch eine offene Datei zurück.
            log.close()
        eigener = _prozess

    for _ in range(50):                       # bis zu 10 Sekunden auf den Port warten
        if erreichbar(port):
            return True, f"Streaming-Dienst gestartet ({programm.name}, Port {port})."
        # Bewusst die eigene Kopie: ein gleichzeitiges stoppen() setzt
        # _prozess auf None, und _prozess.poll() wäre dann ein Fehler.
        if eigener.poll() is not None:
            return False, f"Streaming-Dienst sofort beendet - siehe {log_pfad}"
        time.sleep(0.2)
    return False, f"Streaming-Dienst antwortet nicht auf Port {port} - siehe {log_pfad}"


def stoppen() -> None:
    """Beendet einen von hier gestarteten go2rtc-Prozess."""
    global _prozess
    with _sperre:
        if not _prozess or _prozess.poll() is not None:
            _prozess = None
            return
        _prozess.terminate()
        try:
            _prozess.wait(timeout=5)
        except subprocess.TimeoutExpired:
            _prozess.kill()
            try:
                # Noch einmal abwarten, sonst bleibt der beendete Prozess als
                # Eintrag in der Prozessliste stehen (Zombie).
                _prozess.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        _prozess = None


def laeuft_hier() -> bool:
    return bool(_prozess and _prozess.poll() is None)


atexit.register(stoppen)


# --------------------------------------------------------------------------
# Start von der Kommandozeile
# --------------------------------------------------------------------------

def hauptprogramm(argumente=None) -> int:
    zerleger = argparse.ArgumentParser(description="Streaming-Dienst von CamGrid")
    zerleger.add_argument("--config", default=str(konfig.STANDARD_PFAD))
    zerleger.add_argument("--port", type=int, default=0, help="Port des Dashboards")
    zerleger.add_argument("--mit-server", action="store_true",
                          help="zusätzlich das Dashboard starten (Vorgabe)")
    zerleger.add_argument("--nur-go2rtc", action="store_true",
                          help="nur den Streaming-Dienst starten")
    werte = zerleger.parse_args(argumente)

    config_pfad = Path(werte.config)
    daten = konfig.laden(config_pfad)
    if not config_pfad.exists():
        daten = konfig.speichern(daten, config_pfad)
        print(f"Neue Konfiguration angelegt: {config_pfad}")
        print(f"Anmeldung: {daten['zugang']['admin_benutzer']} / {daten['zugang']['admin_passwort']}")

    erfolg, meldung = starten(daten)
    print(meldung)
    if not erfolg:
        return 1

    if werte.nur_go2rtc:
        print("Beenden mit Strg+C")
        try:
            while laeuft_hier():
                time.sleep(1)
        except KeyboardInterrupt:
            pass
        stoppen()
        return 0

    from app import server

    argumente_server = ["--config", str(config_pfad)]
    if werte.port:
        argumente_server += ["--port", str(werte.port)]
    try:
        return server.hauptprogramm(argumente_server)
    finally:
        stoppen()


if __name__ == "__main__":
    raise SystemExit(hauptprogramm())
