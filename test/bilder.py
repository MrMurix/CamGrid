"""Macht Bildschirmfotos vom Dashboard - für die Kontrolle und für das README.

    python test/bilder.py                      alle Ansichten nach test/bilder/
    python test/bilder.py --readme             zusätzlich nach docs/bilder/

Braucht ein laufendes Dashboard (start-lokal) und Chrome oder Edge.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WURZEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(WURZEL))
sys.path.insert(0, str(WURZEL / "test"))

from browsertest import Steuerung, browser_finden, seite_oeffnen  # noqa: E402

# (Name, Reiter, Breite, Höhe, Thema)
ANSICHTEN = [
    ("start-dunkel", "start", 1440, 900, "dunkel"),
    ("kameras-dunkel", "kameras", 1440, 1000, "dunkel"),
    ("raster-dunkel", "wand", 1440, 1000, "dunkel"),
    ("suche-dunkel", "suche", 1440, 800, "dunkel"),
    ("einstellungen-dunkel", "einstellungen", 1440, 900, "dunkel"),
    ("start-hell", "start", 1440, 900, "hell"),
    ("raster-hell", "wand", 1440, 1000, "hell"),
    ("telefon-start", "start", 430, 900, "dunkel"),
    ("telefon-raster", "wand", 430, 950, "dunkel"),
]


def anmeldung_holen(ordner: str = "lokal") -> str | None:
    import base64

    for pfad in (WURZEL / "test" / ordner / "config.json",
                 WURZEL / "test" / "lokal" / "config.json"):
        if pfad.is_file():
            zugang = json.loads(pfad.read_text(encoding="utf-8")).get("zugang", {})
            if zugang.get("admin_benutzer"):
                return "Basic " + base64.b64encode(
                    f"{zugang['admin_benutzer']}:{zugang['admin_passwort']}".encode()).decode()
    return None


def hauptlauf(adresse: str, ziele: list[Path]) -> int:
    browser = browser_finden()
    if not browser:
        print("Kein Browser gefunden.")
        return 1
    for ziel in ziele:
        ziel.mkdir(parents=True, exist_ok=True)

    profil = tempfile.mkdtemp(prefix="camgrid-bilder-")
    port = 9444
    prozess = subprocess.Popen(
        [browser, "--headless=new", "--disable-gpu", "--no-first-run", "--hide-scrollbars",
         f"--user-data-dir={profil}", f"--remote-debugging-port={port}", adresse],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    try:
        steuerung = Steuerung(seite_oeffnen(port))
        steuerung.rufen("Runtime.enable")
        steuerung.rufen("Page.enable")
        anmeldung = anmeldung_holen("demo" if ":8090" in adresse else "lokal")
        if anmeldung:
            steuerung.rufen("Network.enable")
            steuerung.rufen("Network.setExtraHTTPHeaders", headers={"Authorization": anmeldung})
        steuerung.rufen("Page.navigate", url=adresse)
        time.sleep(4)

        for name, reiter, breite, hoehe, thema in ANSICHTEN:
            steuerung.rufen("Emulation.setDeviceMetricsOverride",
                            width=breite, height=hoehe, deviceScaleFactor=1,
                            mobile=breite < 600)
            steuerung.js(f"themaSetzenFuerBild('{thema}')" if False else
                         f"document.documentElement.setAttribute('data-thema', '{thema}')")
            steuerung.js(f"reiterWaehlenFuerBild('{reiter}')" if False else
                         f"""(() => {{
                             const knopf = [...document.querySelectorAll('.reiter-knopf')]
                               .find(k => k.dataset.ziel === '{reiter}');
                             if (knopf) knopf.click();
                             window.scrollTo(0, 0);
                           }})()""")
            time.sleep(1.5)
            bild = steuerung.rufen("Page.captureScreenshot", format="png")
            import base64

            daten = base64.b64decode(bild["data"])
            for ziel in ziele:
                (ziel / f"{name}.png").write_bytes(daten)
            print(f"  {name}.png ({len(daten) // 1024} KB)")

        steuerung.schliessen()
    finally:
        prozess.terminate()
        try:
            prozess.wait(timeout=5)
        except subprocess.TimeoutExpired:
            prozess.kill()
        shutil.rmtree(profil, ignore_errors=True)
    return 0


if __name__ == "__main__":
    adresse = next((a for a in sys.argv[1:] if a.startswith("http")), "http://127.0.0.1:8080/")
    ziele = [WURZEL / "docs" / "bilder"] if "--readme" in sys.argv else [WURZEL / "test" / "bilder"]
    raise SystemExit(hauptlauf(adresse, ziele))
