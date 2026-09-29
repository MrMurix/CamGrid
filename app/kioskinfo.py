"""Gibt die Monitoreinstellungen in einer Form aus, die ein sh-Skript lesen kann.

kiosk.sh kann kein JSON. Dieses Programm liest die Konfiguration und gibt pro
Monitor eine Zeile aus:

    MONITOR=1;AUSGANG=HDMI-1;X=0;BREITE=1920;HOEHE=1080;BILDRATE=60;PORT=1984

Ist in der Konfiguration kein Ausgang eingetragen, werden die tatsächlich
angeschlossenen Ausgänge von xrandr der Reihe nach vergeben.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config as konfig  # noqa: E402

# Erlaubte Ausgangsnamen. Der Name geht als Variable an kiosk.sh und dort an
# xrandr; alles andere (Leerzeichen, Anführungszeichen, Semikolon) hätte dort
# nichts zu suchen und könnte die Zeile zerreißen.
_NAME_MUSTER = re.compile(r"^[0-9A-Za-z._-]{1,32}$")


def angeschlossene_ausgaenge() -> list[str]:
    """Namen aller verbundenen Bildschirmausgänge, in der Reihenfolge von xrandr."""
    try:
        ausgabe = subprocess.run(
            ["xrandr"], capture_output=True, text=True, timeout=10, check=False
        ).stdout or ""
    except (OSError, subprocess.SubprocessError):
        return []
    return [name for name in re.findall(r"^(\S+) connected", ausgabe, flags=re.M)
            if _NAME_MUSTER.match(name)]


def aufloesung_zerlegen(text: str) -> tuple[int, int]:
    treffer = re.match(r"\s*(\d+)\s*[xX*]\s*(\d+)\s*$", str(text or ""))
    if not treffer:
        return 1920, 1080
    return int(treffer.group(1)), int(treffer.group(2))


def _zahl(wert, vorgabe: int, kleinster: int, groesster: int) -> int:
    try:
        zahl = int(wert)
    except (TypeError, ValueError, OverflowError):
        return vorgabe
    return max(kleinster, min(groesster, zahl))


def zeilen(daten: dict | None = None) -> list[str]:
    daten = daten if isinstance(daten, dict) else konfig.laden()
    anzeige = daten.get("anzeige") or {}
    breite, hoehe = aufloesung_zerlegen(anzeige.get("aufloesung"))
    bildrate = _zahl(anzeige.get("bildrate", 60), 60, 1, 240)
    port = _zahl((daten.get("dienste") or {}).get("go2rtc_port", 1984), 1984, 1, 65535)

    monitore = [m for m in (daten.get("monitore") or []) if isinstance(m, dict)]
    # Nur geprüfte Namen weitergeben: die Zeile wird von einem sh-Skript
    # zerlegt, das den Ausgang unverändert an xrandr gibt.
    gewuenscht: dict[int, str] = {}
    for nummer, monitor in enumerate(monitore):
        name = str(monitor.get("ausgang") or "")
        if _NAME_MUSTER.match(name):
            gewuenscht[nummer] = name
    vergeben = set(gewuenscht.values())
    frei = [a for a in angeschlossene_ausgaenge() if a not in vergeben]

    ergebnis = []
    for nummer, monitor in enumerate(monitore):
        ausgang = gewuenscht.get(nummer) or (frei.pop(0) if frei else "")
        ergebnis.append(
            f"MONITOR={_zahl(monitor.get('id'), nummer + 1, 1, 999)};AUSGANG={ausgang};"
            f"X={nummer * breite};"
            f"BREITE={breite};HOEHE={hoehe};BILDRATE={bildrate};PORT={port}"
        )
    return ergebnis


if __name__ == "__main__":
    try:
        for zeile in zeilen():
            print(zeile)
    except Exception as fehler:            # noqa: BLE001 - kiosk.sh braucht einen Notfallwert
        print(f"# Fehler beim Lesen der Konfiguration: {fehler}", file=sys.stderr)
        sys.exit(1)
