"""Startet CamGrid zum Ausprobieren auf diesem Rechner.

Legt eine Beispielkonfiguration in einem eigenen Ordner an (test/demo), startet
den Admin-Server und öffnet das Dashboard im Browser. Es wird nichts am System
verändert, kein Dienst eingerichtet, nichts installiert.

    python demo.py            Dashboard auf Port 8080
    python demo.py --port 9000
    python demo.py --neu      vorhandene Demo-Daten verwerfen
"""

from __future__ import annotations

import argparse
import shutil
import sys
import threading
import webbrowser
from pathlib import Path

WURZEL = Path(__file__).resolve().parent
sys.path.insert(0, str(WURZEL))

DEMOVERZEICHNIS = WURZEL / "test" / "demo"


def beispiel_anlegen(pfad: Path) -> dict:
    from app import config as konfig

    daten = konfig.standard_konfiguration()
    daten["anlage"]["name"] = "Beispielanlage"
    # Eigene Ports, damit die Demo einer laufenden CamGrid-Anlage auf demselben
    # Rechner nicht die Streams wegnimmt.
    daten["dienste"]["admin_port"] = 8090
    daten["dienste"]["go2rtc_port"] = 1985
    daten["zugang"]["admin_benutzer"] = "admin"
    daten["zugang"]["admin_passwort"] = "demo"
    daten["scan"]["netz"] = "192.168.1.0/24"

    namen = ["Halle Nord", "Halle Süd", "Waage", "Tor 1", "Förderband", "Schere"]
    for nummer, name in enumerate(namen, start=1):
        kamera = konfig.standard_kamera(ip=f"192.168.1.{100 + nummer}", name=name)
        kamera.update(benutzer="admin", passwort="beispiel", breite=640, hoehe=480)
        daten["kameras"].append(kamera)

    daten["monitore"] = [
        {"id": 1, "name": "Monitor links", "ausgang": "", "spalten": 2, "zeilen": 2,
         "kacheln": [{"kamera_id": daten["kameras"][i]["id"], "platz": i + 1,
                      "breite": 1, "hoehe": 1, "name": ""} for i in range(4)]},
        {"id": 2, "name": "Monitor rechts", "ausgang": "", "spalten": 3, "zeilen": 2,
         "kacheln": [{"kamera_id": daten["kameras"][4]["id"], "platz": 1,
                      "breite": 2, "hoehe": 2, "name": ""},
                     {"kamera_id": daten["kameras"][5]["id"], "platz": 3,
                      "breite": 1, "hoehe": 1, "name": ""}]},
    ]
    return konfig.speichern(daten, pfad)


def hauptprogramm() -> int:
    zerleger = argparse.ArgumentParser(description="CamGrid zum Ausprobieren starten")
    zerleger.add_argument("--port", type=int, default=8090)
    zerleger.add_argument("--neu", action="store_true", help="Demo-Daten zurücksetzen")
    werte = zerleger.parse_args()

    if werte.neu and DEMOVERZEICHNIS.exists():
        shutil.rmtree(DEMOVERZEICHNIS)
    DEMOVERZEICHNIS.mkdir(parents=True, exist_ok=True)

    # Die Ablageorte auf den Demo-Ordner umbiegen, bevor die Module geladen werden.
    import os

    os.environ["CAMGRID_CONFIG"] = str(DEMOVERZEICHNIS / "config.json")
    os.environ["CAMGRID_GO2RTC_YAML"] = str(DEMOVERZEICHNIS / "go2rtc.yaml")
    # Eigenes Web-Verzeichnis: sonst überschreibt die Demo die anzeige.json
    # einer laufenden Installation im selben Projektordner.
    web = DEMOVERZEICHNIS / "web"
    web.mkdir(parents=True, exist_ok=True)
    for datei in (WURZEL / "web" / "public").glob("*"):
        if datei.is_file() and datei.name != "anzeige.json":
            shutil.copy2(datei, web / datei.name)
    os.environ["CAMGRID_WEB"] = str(web)

    config_pfad = Path(os.environ["CAMGRID_CONFIG"])
    if not config_pfad.exists():
        beispiel_anlegen(config_pfad)

    from app import server

    adresse = f"http://127.0.0.1:{werte.port}/"
    print("Demo von CamGrid")
    print(f"  Dashboard:  {adresse}")
    print("  Anmeldung:  admin / demo")
    print(f"  Daten:      {DEMOVERZEICHNIS}")
    print("  Beenden mit Strg+C")
    print()
    print("Ohne go2rtc und ohne echte Kameras bleiben die Bilder leer -")
    print("Kameraliste, Raster, Einstellungen und die Suche lassen sich trotzdem bedienen.")

    threading.Timer(1.0, lambda: webbrowser.open(adresse)).start()
    return server.hauptprogramm(["--config", str(config_pfad), "--port", str(werte.port),
                                 "--adresse", "127.0.0.1"])


if __name__ == "__main__":
    raise SystemExit(hauptprogramm())
