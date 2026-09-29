"""Prüft die Anzeigeseite: passen Konfiguration und Streams zusammen, läuft Video?

    python test/anzeigetest.py                       (erwartet go2rtc auf 1984)
    python test/anzeigetest.py http://127.0.0.1:1984/

Ohne erreichbare Kameras wird nur geprüft, dass die Seite aufgebaut wird und
die Kennungen zueinander passen - das ist der Fehler, der in der Praxis am
meisten Zeit kostet ("mse: stream not found").
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

WURZEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(WURZEL))
sys.path.insert(0, str(WURZEL / "test"))

from browsertest import Steuerung, browser_finden, seite_oeffnen  # noqa: E402

fehler: list[str] = []
erfolge = 0


def pruefe(bedingung, was: str) -> None:
    global erfolge
    if bedingung:
        erfolge += 1
        print(f"  ok   {was}")
    else:
        fehler.append(was)
        print(f"  FEHL {was}")


def hauptlauf(adresse: str) -> int:
    adresse = adresse.rstrip("/") + "/"
    try:
        with urllib.request.urlopen(adresse + "anzeige.json", timeout=5) as antwort:
            anzeige = json.loads(antwort.read().decode())
        with urllib.request.urlopen(adresse + "api/streams", timeout=5) as antwort:
            streams = json.loads(antwort.read().decode())
    except OSError as f:
        print(f"Streaming-Dienst unter {adresse} nicht erreichbar ({f}).")
        print("Erst start-lokal starten.")
        return 2

    print("Konfiguration und Streams")
    gebraucht = {kachel["kamera_id"] for monitor in anzeige.get("monitore", [])
                 for kachel in monitor.get("kacheln", []) if kachel.get("kamera_id")}
    eingerichtet = {k["id"] for k in anzeige.get("kameras", []) if k.get("eingerichtet")}
    bekannt = set(streams)

    pruefe(gebraucht <= eingerichtet | {None},
           "jede Kachel zeigt auf eine Kamera aus der Konfiguration")
    fehlend = {kennung for kennung in gebraucht & eingerichtet if kennung not in bekannt}
    pruefe(not fehlend,
           f"jede belegte Kamera ist auch im Streaming-Dienst angemeldet"
           + (f" (fehlt: {', '.join(sorted(fehlend))})" if fehlend else ""))
    pruefe("passwort" not in json.dumps(anzeige), "anzeige.json enthält keine Passwörter")
    pruefe(all("ip" not in k for k in anzeige.get("kameras", [])),
           "anzeige.json enthält keine IP-Adressen")

    browser = browser_finden()
    if not browser:
        print("Kein Browser gefunden - der Rest wird übersprungen.")
    else:
        print("Anzeige im Browser")
        profil = tempfile.mkdtemp(prefix="camgrid-anzeige-")
        port = 9355
        prozess = subprocess.Popen(
            [browser, "--headless=new", "--disable-gpu", "--no-first-run",
             "--autoplay-policy=no-user-gesture-required",
             f"--user-data-dir={profil}", f"--remote-debugging-port={port}",
             adresse + "?monitor=1"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            steuerung = Steuerung(seite_oeffnen(port))
            steuerung.rufen("Runtime.enable")
            stand = {}
            for _ in range(14):
                time.sleep(2.5)
                stand = json.loads(steuerung.js("""(() => {
                    const videos = [...document.querySelectorAll('video')];
                    return JSON.stringify({
                      kacheln: document.querySelectorAll('.kachel').length,
                      laufend: videos.filter(v => v.readyState >= 2).length,
                      fehlertexte: [...document.querySelectorAll('video-stream')]
                        .map(v => v.querySelector('.status')?.innerText || '')
                        .filter(Boolean),
                      hinweise: [...document.querySelectorAll('.hinweis')]
                        .filter(h => !h.hidden).length,
                    });
                  })()"""))
                if stand["laufend"]:
                    break

            pruefe(stand.get("kacheln", 0) > 0, "die Anzeigeseite baut Kacheln auf")
            pruefe(not stand.get("fehlertexte"),
                   "keine Fehlermeldung im Spieler"
                   + (f" ({'; '.join(stand.get('fehlertexte', [])[:2])})"
                      if stand.get("fehlertexte") else ""))
            if gebraucht & bekannt:
                pruefe(stand.get("laufend", 0) > 0, "mindestens ein Video läuft")
                pruefe(stand.get("hinweise", 0) < stand.get("kacheln", 1),
                       "„Kein Signal“ verschwindet, wo Bild läuft")
            else:
                print("  (keine belegte Kachel mit Stream - Videoprüfung entfällt)")
            steuerung.schliessen()
        finally:
            prozess.terminate()
            try:
                prozess.wait(timeout=5)
            except subprocess.TimeoutExpired:
                prozess.kill()
            shutil.rmtree(profil, ignore_errors=True)

    print()
    if fehler:
        print(f"{len(fehler)} von {len(fehler) + erfolge} Prüfungen fehlgeschlagen:")
        for eintrag in fehler:
            print(f"  - {eintrag}")
        return 1
    print(f"Alle {erfolge} Prüfungen bestanden.")
    return 0


if __name__ == "__main__":
    raise SystemExit(hauptlauf(sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:1984/"))
