"""Bedient das Dashboard in einem echten Browser und prüft, ob es reagiert.

Startet Chrome oder Edge ohne Fenster, öffnet das Dashboard und klickt sich
durch: Kachel belegen, Raster wechseln, speichern. Geprüft wird danach, was
wirklich in der Konfiguration steht - und ob die Seite JavaScript-Fehler
gemeldet hat.

    python test/browsertest.py                    (erwartet den Server auf 8080)
    python test/browsertest.py http://127.0.0.1:8080

Gedacht für die Entwicklung: ohne Browser auf dem Rechner wird der Test
übersprungen (Rückgabewert 0).
"""

from __future__ import annotations

import base64
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

WURZEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(WURZEL))

BROWSER_KANDIDATEN = [
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/usr/bin/google-chrome",
]

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


# --------------------------------------------------------------------------
# Kleiner WebSocket-Client für das DevTools-Protokoll (nur was hier nötig ist)
# --------------------------------------------------------------------------

class Steuerung:
    """Verbindung zum Browser über das DevTools-Protokoll."""

    def __init__(self, ws_adresse: str):
        import re

        treffer = re.match(r"ws://([^:/]+):(\d+)(/.*)", ws_adresse)
        if not treffer:
            raise ValueError(f"Unbrauchbare Adresse: {ws_adresse}")
        wirt, port, pfad = treffer.group(1), int(treffer.group(2)), treffer.group(3)

        self.buchse = socket.create_connection((wirt, port), timeout=20)
        schluessel = base64.b64encode(os.urandom(16)).decode()
        handschlag = (
            f"GET {pfad} HTTP/1.1\r\nHost: {wirt}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {schluessel}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.buchse.sendall(handschlag.encode())
        antwort = b""
        while b"\r\n\r\n" not in antwort:
            antwort += self.buchse.recv(4096)
        if b"101" not in antwort.split(b"\r\n")[0]:
            raise OSError("Browser hat die Verbindung nicht angenommen")
        self.rest = antwort.split(b"\r\n\r\n", 1)[1]
        self.nummer = 0

    # ---- Rahmen lesen und schreiben (RFC 6455, nur Textnachrichten) ----

    def _senden(self, text: str) -> None:
        daten = text.encode("utf-8")
        kopf = bytearray([0x81])                       # FIN + Textrahmen
        maske = os.urandom(4)
        laenge = len(daten)
        if laenge < 126:
            kopf.append(0x80 | laenge)
        elif laenge < 65536:
            kopf.append(0x80 | 126)
            kopf += laenge.to_bytes(2, "big")
        else:
            kopf.append(0x80 | 127)
            kopf += laenge.to_bytes(8, "big")
        kopf += maske
        kopf += bytes(b ^ maske[i % 4] for i, b in enumerate(daten))
        self.buchse.sendall(bytes(kopf))

    def _lesen_genau(self, anzahl: int) -> bytes:
        while len(self.rest) < anzahl:
            stueck = self.buchse.recv(65536)
            if not stueck:
                raise OSError("Verbindung zum Browser abgebrochen")
            self.rest += stueck
        ergebnis, self.rest = self.rest[:anzahl], self.rest[anzahl:]
        return ergebnis

    def _empfangen(self) -> str:
        while True:
            kopf = self._lesen_genau(2)
            art = kopf[0] & 0x0F
            laenge = kopf[1] & 0x7F
            if laenge == 126:
                laenge = int.from_bytes(self._lesen_genau(2), "big")
            elif laenge == 127:
                laenge = int.from_bytes(self._lesen_genau(8), "big")
            nutzlast = self._lesen_genau(laenge)
            if art == 0x1:
                return nutzlast.decode("utf-8", "replace")
            if art == 0x8:
                raise OSError("Browser hat die Verbindung geschlossen")
            # Ping/Pong und Fortsetzungen überspringen

    def rufen(self, verfahren: str, **parameter):
        self.nummer += 1
        nummer = self.nummer
        self._senden(json.dumps({"id": nummer, "method": verfahren, "params": parameter}))
        ende = time.time() + 30
        while time.time() < ende:
            nachricht = json.loads(self._empfangen())
            if nachricht.get("id") == nummer:
                if "error" in nachricht:
                    raise OSError(nachricht["error"].get("message", "unbekannter Fehler"))
                return nachricht.get("result", {})
        raise TimeoutError(f"Keine Antwort auf {verfahren}")

    def js(self, ausdruck: str):
        """Führt JavaScript in der Seite aus und gibt das Ergebnis zurück."""
        ergebnis = self.rufen("Runtime.evaluate", expression=ausdruck,
                              returnByValue=True, awaitPromise=True)
        if ergebnis.get("exceptionDetails"):
            text = ergebnis["exceptionDetails"].get("exception", {}).get("description", "Fehler")
            raise OSError(text)
        return ergebnis.get("result", {}).get("value")

    def schliessen(self) -> None:
        try:
            self.buchse.close()
        except OSError:
            pass


# --------------------------------------------------------------------------

def browser_finden() -> str | None:
    for pfad in BROWSER_KANDIDATEN:
        if Path(pfad).is_file():
            return pfad
    for name in ("chromium", "google-chrome", "chrome"):
        gefunden = shutil.which(name)
        if gefunden:
            return gefunden
    return None


def seite_oeffnen(port: int) -> str:
    """Wartet auf die DevTools-Schnittstelle und liefert die WebSocket-Adresse."""
    ende = time.time() + 30
    while time.time() < ende:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=3) as antwort:
                ziele = json.loads(antwort.read().decode())
            for ziel in ziele:
                if ziel.get("type") == "page" and ziel.get("webSocketDebuggerUrl"):
                    return ziel["webSocketDebuggerUrl"]
        except (OSError, ValueError):
            pass
        time.sleep(0.5)
    raise TimeoutError("Browser meldet keine Seite")


def hauptlauf(adresse: str) -> int:
    browser = browser_finden()
    if not browser:
        print("Kein Chrome/Edge/Chromium gefunden - Browsertest wird übersprungen.")
        return 0

    # Zugangsdaten aus der lokalen Konfiguration holen, damit der Test auch
    # mit eingeschalteter Anmeldung läuft.
    anmeldung = None
    for pfad in (WURZEL / "test" / "lokal" / "config.json", WURZEL / "test" / "demo" / "config.json"):
        if pfad.is_file():
            try:
                zugang = json.loads(pfad.read_text(encoding="utf-8"))["zugang"]
                if zugang.get("admin_benutzer"):
                    anmeldung = "Basic " + base64.b64encode(
                        f"{zugang['admin_benutzer']}:{zugang['admin_passwort']}".encode()).decode()
            except (OSError, ValueError, KeyError):
                pass
            break

    try:
        anfrage = urllib.request.Request(adresse)
        if anmeldung:
            anfrage.add_header("Authorization", anmeldung)
        with urllib.request.urlopen(anfrage, timeout=5) as antwort:
            if antwort.status != 200:
                raise OSError(f"HTTP {antwort.status}")
    except OSError as f:
        print(f"Dashboard unter {adresse} nicht erreichbar ({f}).")
        print("Erst 'start-lokal.sh' (oder start-lokal.cmd) starten.")
        return 2

    profil = tempfile.mkdtemp(prefix="camgrid-browser-")
    port = 9333
    prozess = subprocess.Popen(
        [browser, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
         f"--user-data-dir={profil}", f"--remote-debugging-port={port}", adresse],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )

    steuerung = None
    try:
        steuerung = Steuerung(seite_oeffnen(port))
        steuerung.rufen("Runtime.enable")
        steuerung.rufen("Page.enable")
        if anmeldung:
            steuerung.rufen("Network.enable")
            steuerung.rufen("Network.setExtraHTTPHeaders", headers={"Authorization": anmeldung})
            steuerung.rufen("Page.navigate", url=adresse)
            time.sleep(2)

        # Warten, bis das Dashboard fertig geladen hat.
        ende = time.time() + 30
        while time.time() < ende:
            if steuerung.js("typeof camgrid !== 'undefined' && camgrid.config !== null && "
                            "document.querySelectorAll('#monitore .zelle').length > 0"):
                break
            time.sleep(0.5)

        # Bekannten Ausgangszustand herstellen, damit der Test nicht davon
        # abhängt, was ein vorheriger Lauf hinterlassen hat.
        steuerung.js("""
            (() => {
              const m = camgrid.config.monitore[0];
              m.spalten = 2; m.zeilen = 2; m.kacheln = [];
              camgrid.neuZeichnen();
            })()""")
        time.sleep(0.4)

        print("Aufbau")
        pruefe(steuerung.js("camgrid.config.kameras.length") > 0, "Kameras sind geladen")
        pruefe(steuerung.js("document.querySelectorAll('#monitore .zelle').length") > 0, "Raster ist gezeichnet")
        pruefe(steuerung.js("document.getElementById('auswahl').hidden") is True,
               "Auswahlfenster ist zu")
        pruefe(steuerung.js("document.querySelector('#monitore .monitor-raster').children.length") == 4,
               "Raster des ersten Monitors steht auf 2x2")

        print("Kachel über Klick belegen")
        steuerung.js("""(() => { const k = [...document.querySelectorAll('.reiter-knopf')]
                          .find(k => k.dataset.ziel === 'wand'); if (k) k.click(); })()""")
        time.sleep(0.5)
        steuerung.js("""
            (() => { const zellen = [...document.querySelectorAll('#monitore .zelle')];
                     const leer = zellen.find(z => !z.classList.contains('belegt')) || zellen[0];
                     leer.click(); })()""")
        time.sleep(0.4)
        pruefe(steuerung.js("document.getElementById('auswahl').hidden") is False,
               "Auswahlfenster geht auf")
        pruefe(steuerung.js("document.querySelectorAll('.auswahl-eintrag').length") > 0,
               "Kameras stehen zur Auswahl")

        vorher = steuerung.js("camgrid.config.monitore[0].kacheln.length")
        steuerung.js("document.querySelector('.auswahl-eintrag').click()")
        time.sleep(0.4)
        nachher = steuerung.js("camgrid.config.monitore[0].kacheln.length")
        pruefe(nachher == vorher + 1, "Kamera sitzt in der Kachel")
        pruefe(steuerung.js("document.getElementById('auswahl').hidden") is True,
               "Auswahlfenster schließt sich wieder")
        pruefe(steuerung.js("document.getElementById('speichern').disabled") is False,
               "Speichern wird scharf")
        pruefe(steuerung.js("document.querySelectorAll('#monitore .zelle.belegt').length") > 0,
               "Kachel wird als belegt gezeichnet")

        print("Raster wechseln")
        steuerung.js("""
            (() => { const knopf = [...document.querySelectorAll('.vorlage-knopf')]
                       .find(k => k.dataset.spalten === '3' && k.dataset.zeilen === '3');
                     knopf.click(); })()""")
        time.sleep(0.4)
        pruefe(steuerung.js("camgrid.config.monitore[0].spalten") == 3 and
               steuerung.js("camgrid.config.monitore[0].zeilen") == 3, "Vorlage 3×3 wird übernommen")
        pruefe(steuerung.js("document.querySelector('#monitore .monitor-raster').children.length") == 9,
               "Raster zeigt neun Plätze")

        print("Mehrfach hintereinander (hier hakte es früher)")
        for durchgang in range(3):
            steuerung.js("""
                (() => { const zellen = [...document.querySelectorAll('#monitore .zelle')];
                         const leer = zellen.find(z => !z.classList.contains('belegt'));
                         if (leer) leer.click(); })()""")
            time.sleep(0.3)
            steuerung.js("(() => { const e = document.querySelector('.auswahl-eintrag');"
                         " if (e) e.click(); })()")
            time.sleep(0.3)
        pruefe(steuerung.js("camgrid.config.monitore[0].kacheln.length") >= 4,
               "vier Kacheln nacheinander belegt")

        print("Speichern")
        steuerung.js("document.getElementById('speichern').click()")
        time.sleep(2.0)
        pruefe(steuerung.js("document.getElementById('speichern').disabled") is True,
               "Speichern-Knopf ist danach wieder aus")
        pruefe(steuerung.js("document.getElementById('speicherstand').textContent") == "gespeichert",
               "Anzeige meldet gespeichert")

        gespeichert = steuerung.js("""
            fetch('/api/config').then(a => a.json()).then(c =>
              c.monitore[0].kacheln.length + '/' + c.monitore[0].spalten)""")
        erwartet = steuerung.js("camgrid.config.monitore[0].kacheln.length + '/' + camgrid.config.monitore[0].spalten")
        pruefe(gespeichert == erwartet, f"Server hat dasselbe gespeichert ({gespeichert})")

        print("Nach dem Speichern weiterarbeiten")
        steuerung.js("""
            (() => { const zellen = [...document.querySelectorAll('#monitore .zelle')];
                     const leer = zellen.find(z => !z.classList.contains('belegt'));
                     if (leer) leer.click(); })()""")
        time.sleep(0.3)
        steuerung.js("(() => { const e = document.querySelector('.auswahl-eintrag');"
                     " if (e) e.click(); })()")
        time.sleep(0.4)
        pruefe(steuerung.js("document.getElementById('speichern').disabled") is False,
               "Änderung nach dem Speichern wird erkannt")

        print("Ziehen und Ablegen")
        # Erst Platz schaffen: großes Raster, alle Kacheln weg.
        steuerung.js("""
            (() => {
              const m = camgrid.config.monitore[0];
              m.spalten = 4; m.zeilen = 3; m.kacheln = [];
              camgrid.neuZeichnen();
            })()""")
        time.sleep(0.4)

        ergebnis = steuerung.js("""
            (() => {
              const quelle = document.querySelectorAll('.zieh-kamera')[1]
                          || document.querySelector('.zieh-kamera');
              const gezogen = quelle.dataset.kameraId;
              const zellen = [...document.querySelectorAll('#monitore .monitor:first-child .zelle')];
              const ziel = zellen[5];
              const daten = new DataTransfer();
              quelle.dispatchEvent(new DragEvent('dragstart',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              ziel.dispatchEvent(new DragEvent('dragover',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              const markiert = ziel.classList.contains('ziel');
              ziel.dispatchEvent(new DragEvent('drop',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              quelle.dispatchEvent(new DragEvent('dragend',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              const kachel = camgrid.config.monitore[0].kacheln.find(k => k.platz === 6);
              return JSON.stringify({ markiert, gezogen, gelandet: kachel ? kachel.kamera_id : null });
            })()""")
        gemessen = json.loads(ergebnis)
        pruefe(gemessen["markiert"] is True, "Zielkachel wird beim Darüberziehen hervorgehoben")
        pruefe(gemessen["gelandet"] == gemessen["gezogen"],
               "gezogene Kamera landet genau auf der Zielkachel")

        # Zweite Kamera auf einen anderen Platz ziehen, dann beide tauschen.
        tausch = steuerung.js("""
            (() => {
              const zweite = [...document.querySelectorAll('.zieh-kamera')]
                .find(e => e.dataset.kameraId !== camgrid.config.monitore[0].kacheln[0].kamera_id);
              const zellen = [...document.querySelectorAll('#monitore .monitor:first-child .zelle')];
              const leer = zellen.find(z => !z.classList.contains('belegt'));
              let daten = new DataTransfer();
              zweite.dispatchEvent(new DragEvent('dragstart',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              leer.dispatchEvent(new DragEvent('dragover',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              leer.dispatchEvent(new DragEvent('drop',
                { bubbles: true, cancelable: true, dataTransfer: daten }));

              const kacheln = camgrid.config.monitore[0].kacheln;
              const vorher = kacheln.map(k => k.platz + ':' + k.kamera_id).sort().join('|');
              const belegte = [...document.querySelectorAll('#monitore .monitor:first-child .zelle.belegt')];
              daten = new DataTransfer();
              belegte[0].dispatchEvent(new DragEvent('dragstart',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              belegte[1].dispatchEvent(new DragEvent('dragover',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              belegte[1].dispatchEvent(new DragEvent('drop',
                { bubbles: true, cancelable: true, dataTransfer: daten }));
              const nachher = camgrid.config.monitore[0].kacheln
                .map(k => k.platz + ':' + k.kamera_id).sort().join('|');
              return JSON.stringify({ anzahl: kacheln.length, vorher, nachher });
            })()""")
        tauschdaten = json.loads(tausch)
        pruefe(tauschdaten["anzahl"] == 2, "zweite Kamera per Ziehen abgelegt")
        pruefe(tauschdaten["vorher"] != tauschdaten["nachher"],
               "zwei Kacheln lassen sich per Ziehen tauschen")

        print("JavaScript-Fehler")
        meldungen = steuerung.js("window.__fehler ? window.__fehler.length : 0")
        pruefe(meldungen in (0, None), "keine Fehler im Fenster gemeldet")

    finally:
        if steuerung:
            steuerung.schliessen()
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
    ziel = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080/"
    raise SystemExit(hauptlauf(ziel))
