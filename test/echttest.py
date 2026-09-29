"""Prüft CamGrid gegen echte Kameras im Netz.

Anders als test_server.py braucht dieser Test erreichbare Kameras. Er geht den
Weg durch, den auch das Dashboard geht: Netz absuchen, Stream prüfen,
Vorschaubild holen, Stream über go2rtc abspielen.

    python test/echttest.py 192.168.1.0/24 admin "GeheimesPasswort!23"
    python test/echttest.py 192.168.1.101            (eine einzelne Kamera)
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

WURZEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(WURZEL))

from app import kamerabild, rtsp, scan  # noqa: E402


def hauptlauf(netz: str, benutzer: str, passwort: str) -> int:
    zugangsdaten = [{"benutzer": benutzer, "passwort": passwort}]
    print(f"Suche in {netz} …")
    start = time.time()
    treffer = scan.netz_scannen(netz, zugangsdaten)
    print(f"{len(treffer)} Adressen mit Antwort in {time.time() - start:.0f} s\n")

    if not treffer:
        print("Nichts gefunden. Stimmen Netzbereich und Zugangsdaten?")
        return 1

    mit_video = 0
    mit_bild = 0
    print(f"{'IP':16}{'Hersteller':12}{'Stream':28}{'Vorschaubild'}")
    print("-" * 74)
    for fund in treffer:
        strom = fund["stream"]
        if strom:
            mit_video += 1
            beschreibung = f"{strom['breite']}x{strom['hoehe']} {strom['codec']} · {strom['pfad']}"
        else:
            beschreibung = fund["fehler"] or "kein Video"

        bild, quelle = kamerabild.bild_holen(
            fund["ip"], fund["benutzer"] or benutzer, fund["passwort"] or passwort,
            (strom or {}).get("pfad", ""))
        if bild:
            mit_bild += 1
            bildtext = f"{len(bild) // 1024} KB ({quelle})"
        else:
            bildtext = "keins"

        print(f"{fund['ip']:16}{(fund['hersteller'] or '-'):12}{beschreibung:28}{bildtext}")

    print()
    print(f"Ergebnis: {mit_video} von {len(treffer)} mit Videostrom, {mit_bild} mit Vorschaubild.")

    # Zusatzprobe: beide Ströme der ersten gefundenen Kamera anzeigen.
    erste = next((t for t in treffer if t["stream"]), None)
    if erste:
        print(f"\nAlle Ströme von {erste['ip']}:")
        for strom in rtsp.pfade_testen(erste["ip"], list(scan.STANDARD_PFADE)[:8],
                                       [{"benutzer": erste["benutzer"] or benutzer,
                                         "passwort": erste["passwort"] or passwort}]):
            print(f"  {strom['pfad']:24} {strom['breite']}x{strom['hoehe']} "
                  f"{strom['codec']} {strom['fps'] or '?'} Bilder/s")

    return 0 if mit_video else 1


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(hauptlauf(sys.argv[1],
                               sys.argv[2] if len(sys.argv) > 2 else "",
                               sys.argv[3] if len(sys.argv) > 3 else ""))
