"""Admin-Server von CamGrid.

Liefert das Dashboard und eine kleine JSON-Schnittstelle. Bewusst nur mit der
Python-Standardbibliothek gebaut, damit auf einem frischen System nichts
nachinstalliert werden muss.

Start:
    python3 app/server.py --config /etc/camgrid/config.json --port 8080
"""

from __future__ import annotations

import argparse
import base64
import hmac
import json
import mimetypes
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config as konfig  # noqa: E402
from app import kamerabild  # noqa: E402
from app import kioskinfo  # noqa: E402
from app import rtsp  # noqa: E402
from app import scan  # noqa: E402
from app import streams  # noqa: E402

WURZEL = Path(__file__).resolve().parent.parent
ADMIN_DATEIEN = (WURZEL / "web" / "admin").resolve()
ANZEIGE_DATEIEN = (WURZEL / "web" / "public").resolve()

# Laufender Netzwerk-Suchlauf (nur einer gleichzeitig).
_scan_zustand: dict = {"laeuft": False, "fertig": 0, "gesamt": 0, "ip": "",
                       "treffer": [], "fehler": None, "netz": ""}
_scan_sperre = threading.Lock()


# --------------------------------------------------------------------------
# Hilfen
# --------------------------------------------------------------------------

def eigene_adresse() -> str:
    """IP-Adresse, unter der dieser Rechner im Netz erreichbar ist.

    Der UDP-Verbindungsaufbau schickt kein einziges Paket; er sagt dem
    Betriebssystem nur, welche eigene Adresse für den Weg nach draußen
    benutzt würde. Das Ziel ist deshalb bewusst eine Adresse aus dem für
    Beispiele reservierten Bereich (RFC 5737) - dort steht garantiert nichts.
    """
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 1))
            return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def dienst_zustand(name: str) -> str:
    """Zustand eines systemd-Dienstes, oder 'unbekannt' auf Systemen ohne systemd."""
    if not shutil.which("systemctl"):
        return "unbekannt"
    try:
        ergebnis = subprocess.run(
            ["systemctl", "is-active", name], capture_output=True, text=True, timeout=5, check=False
        )
        return ergebnis.stdout.strip() or "unbekannt"
    except (OSError, subprocess.SubprocessError):
        return "unbekannt"


def go2rtc_streams(port: int) -> dict:
    """Welche Streams kennt go2rtc gerade und wie viele Zuschauer haben sie?"""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/streams", timeout=3) as antwort:
            daten = json.loads(antwort.read(4_000_000).decode("utf-8", "replace") or "{}")
    except (OSError, ValueError):
        return {}
    # Antwortet auf dem Port etwas anderes als go2rtc, ist das kein Grund für
    # einen Serverfehler - dann sind eben keine Streams bekannt.
    return daten if isinstance(daten, dict) else {}


# --------------------------------------------------------------------------
# Wächter: prüft im Hintergrund, ob die Kameras antworten
# --------------------------------------------------------------------------

_erreichbarkeit: dict = {}           # Kamera-ID -> {"erreichbar": bool, "geprueft": float}
_erreichbar_sperre = threading.Lock()
PRUEFTAKT = 20                       # Sekunden zwischen zwei Durchläufen


def kamera_erreichbar(ip: str, timeout: float = 1.5) -> bool:
    """Antwortet die Kamera auf dem RTSP-Port? Bewusst nur ein kurzer
    Verbindungsversuch - das kostet fast nichts und sagt genug."""
    try:
        with socket.create_connection((ip, 554), timeout=timeout):
            return True
    except OSError:
        return False


def _waechter_lauf(dienst) -> None:
    """Prüft alle Kameras der Reihe nach, immer wieder.

    Wichtig für die Anzeige im Dashboard: go2rtc verbindet sich mit einer
    Kamera erst, wenn jemand zuschaut. Ohne diesen Wächter sähe jede Kamera
    nach "kein Bild" aus, solange keine Anzeigeseite offen ist.
    """
    while True:
        try:
            daten = dienst.konfiguration()
            kameras = [k for k in daten["kameras"] if k.get("ip")]
            ergebnisse = []
            if kameras:
                with ThreadPoolExecutor(max_workers=min(16, len(kameras))) as pool:
                    ergebnisse = list(pool.map(
                        lambda k: (k["id"], kamera_erreichbar(k["ip"])), kameras))
            jetzt = time.time()
            with _erreichbar_sperre:
                for kamera_id, erreichbar in ergebnisse:
                    _erreichbarkeit[kamera_id] = {"erreichbar": erreichbar, "geprueft": jetzt}
                # Gelöschte Kameras wieder vergessen, sonst wächst die
                # Tabelle mit jeder je eingetragenen Kamera weiter.
                bekannt = {k["id"] for k in daten["kameras"]}
                for veraltet in [i for i in _erreichbarkeit if i not in bekannt]:
                    _erreichbarkeit.pop(veraltet, None)
            _streams_nachziehen(daten)
        except Exception as fehler:            # noqa: BLE001 - der Wächter darf nie sterben
            # Gemeldet wird trotzdem: eine kaputte Konfiguration würde sonst
            # unbemerkt dafür sorgen, dass keine Kamera mehr geprüft wird.
            sys.stderr.write(f"Wächter: Durchlauf fehlgeschlagen ({fehler!r})\n")
        time.sleep(PRUEFTAKT)


def _streams_nachziehen(daten: dict) -> None:
    """Sorgt dafür, dass im Streaming-Dienst genau die Kameras stehen, die in
    der Konfiguration stehen.

    Nötig, weil beides auseinanderlaufen kann: go2rtc wurde neu gestartet, war
    beim Speichern kurz nicht erreichbar, oder jemand hat von Hand etwas
    geändert. Ohne das bliebe die Anzeige bei "Kein Signal", obwohl die
    Konfiguration stimmt.
    """
    port = int(daten["dienste"].get("go2rtc_port", 1984))
    vorhanden = set(go2rtc_streams(port))
    if not vorhanden and not _port_offen(port):
        return                                  # Dienst läuft gerade nicht
    gewuenscht = {konfig.stream_name(k) for k in daten["kameras"]
                  if k.get("aktiv", True) and konfig.rtsp_adresse(k)}
    if vorhanden == gewuenscht:
        return
    erfolg, meldung = streams.uebernehmen(daten, port)
    sys.stderr.write(f"Wächter: Streams nachgezogen ({meldung})\n")


def waechter_starten(dienst) -> None:
    threading.Thread(target=_waechter_lauf, args=(dienst,), daemon=True).start()


class Anfrage(Exception):
    """Fehler, der dem Aufrufer als sauberer HTTP-Status gemeldet wird."""

    def __init__(self, status: int, meldung: str):
        super().__init__(meldung)
        self.status = status
        self.meldung = meldung


# --------------------------------------------------------------------------
# Der HTTP-Dienst
# --------------------------------------------------------------------------

class Dienst(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, adresse, handler, config_pfad: Path):
        super().__init__(adresse, handler)
        self.config_pfad = config_pfad
        self.sperre = threading.RLock()

    def konfiguration(self) -> dict:
        with self.sperre:
            return konfig.laden(self.config_pfad)

    def speichern(self, daten: dict) -> dict:
        with self.sperre:
            gespeichert = konfig.speichern(daten, self.config_pfad)
        return gespeichert

    def aendern(self, aenderung):
        """Lädt, ändert und speichert die Konfiguration in einem Zug.

        Der Server bedient mehrere Anfragen gleichzeitig. Würde jede Anfrage
        erst laden, dann ändern und später speichern, ginge bei zwei
        gleichzeitigen Änderungen eine davon verloren (die zweite schreibt
        den alten Stand zurück). Deshalb liegt hier alles unter einer Sperre.

        `aenderung(daten)` darf `daten` verändern; der Rückgabewert wird
        zusammen mit der gespeicherten Konfiguration zurückgegeben. Wirft
        `aenderung` eine Ausnahme, wird nichts gespeichert.
        """
        with self.sperre:
            daten = konfig.laden(self.config_pfad)
            ergebnis = aenderung(daten)
            gespeichert = konfig.speichern(daten, self.config_pfad)
        return gespeichert, ergebnis


class Handler(BaseHTTPRequestHandler):
    server_version = "CamGrid"
    protocol_version = "HTTP/1.1"

    # Zustand der laufenden Anfrage (siehe _bearbeiten).
    _antwort_gesendet = False
    _koerper_gelesen = False

    # ---------------------------------------------------------------- Rahmen

    def log_message(self, format, *args):  # noqa: A002 - Signatur der Basisklasse
        # Zugriffe nur bei Fehlern protokollieren, sonst wird das Journal voll.
        if not str(args[1] if len(args) > 1 else "").startswith(("2", "3")):
            sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))

    def do_GET(self):      # noqa: N802
        self._bearbeiten("GET")

    def do_POST(self):     # noqa: N802
        self._bearbeiten("POST")

    def do_PUT(self):      # noqa: N802
        self._bearbeiten("PUT")

    def do_DELETE(self):   # noqa: N802
        self._bearbeiten("DELETE")

    def _bearbeiten(self, methode: str):
        self._antwort_gesendet = False
        self._koerper_gelesen = False
        pfad, _, abfrage = self.path.partition("?")
        pfad = re.sub(r"/+", "/", pfad)
        try:
            if pfad.startswith("/api/"):
                self._anmeldung_pruefen()
                antwort = self._api(methode, pfad, self._parameter(abfrage))
                if isinstance(antwort, tuple):        # (Bytes, Inhaltstyp)
                    self._senden(200, antwort[0], antwort[1])
                else:
                    self._json(200, antwort)
                return
            if methode != "GET":
                raise Anfrage(405, "Methode nicht erlaubt")
            self._datei(pfad)
        except Anfrage as fehler:
            self._koerper_verwerfen()
            if self._antwort_gesendet:
                return
            if fehler.status == 401:
                self._anmeldung_anfordern()
            elif pfad.startswith("/api/"):
                self._json(fehler.status, {"fehler": fehler.meldung})
            else:
                self._senden(fehler.status, fehler.meldung.encode("utf-8"),
                             "text/plain; charset=utf-8")
        except Exception as fehler:                    # noqa: BLE001
            sys.stderr.write(f"Unerwarteter Fehler bei {methode} {pfad}: {fehler!r}\n")
            self._koerper_verwerfen()
            if self._antwort_gesendet:
                # Der Kopf ist schon unterwegs - eine zweite Antwort würde die
                # Verbindung durcheinanderbringen. Also nur noch schließen.
                self.close_connection = True
                return
            self._json(500, {"fehler": f"Unerwarteter Fehler: {fehler}"})

    def _koerper_verwerfen(self) -> None:
        """Liest einen nicht abgeholten Anfragekörper weg.

        Bei HTTP/1.1 bleibt die Verbindung offen. Wird eine Anfrage vorher
        abgelehnt (etwa 401 bei einem PUT mit Inhalt), liegen die Daten noch
        im Puffer und würden als nächste Anfrage gelesen - die Verbindung
        wäre verloren.
        """
        if self._koerper_gelesen:
            return
        self._koerper_gelesen = True
        if (self.headers.get("Transfer-Encoding") or "").strip().lower() == "chunked":
            self.close_connection = True   # Länge unbekannt, Rest nicht lesbar
            return
        laenge = self._laenge()
        if laenge <= 0:
            return
        if laenge > 4_000_000:
            self.close_connection = True
            return
        try:
            self.rfile.read(laenge)
        except OSError:
            self.close_connection = True

    def _parameter(self, abfrage: str) -> dict:
        return {schluessel: werte[0] for schluessel, werte in parse_qs(abfrage).items()}

    def _laenge(self) -> int:
        """Angekündigte Länge des Anfragekörpers, 0 wenn keine oder unsinnig."""
        try:
            return max(0, int(self.headers.get("Content-Length") or 0))
        except ValueError:
            return 0

    def _koerper(self) -> dict:
        if (self.headers.get("Transfer-Encoding") or "").strip().lower() == "chunked":
            # Stückweise übertragene Körper kann dieser kleine Server nicht
            # lesen; ohne diese Meldung würde der Inhalt stillschweigend fehlen.
            raise Anfrage(411, "Bitte mit Content-Length senden")
        if self.headers.get("Content-Length") and self._laenge() == 0:
            raise Anfrage(400, "Content-Length ist keine Zahl")
        laenge = self._laenge()
        if laenge <= 0:
            self._koerper_gelesen = True
            return {}
        if laenge > 4_000_000:
            raise Anfrage(413, "Anfrage zu groß")
        roh = self.rfile.read(laenge)
        self._koerper_gelesen = True
        if len(roh) < laenge:
            raise Anfrage(400, "Die Anfrage brach mitten im Inhalt ab")
        try:
            daten = json.loads(roh.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as fehler:
            raise Anfrage(400, f"Ungültiges JSON: {fehler}") from fehler
        if not isinstance(daten, dict):
            raise Anfrage(400, "Es wird ein JSON-Objekt erwartet")
        return daten

    # ------------------------------------------------------------ Anmeldung

    def _anmeldung_pruefen(self):
        zugang = self.server.konfiguration()["zugang"]
        benutzer = zugang.get("admin_benutzer") or ""
        passwort = zugang.get("admin_passwort") or ""
        if not benutzer and not passwort:
            return                                     # Anmeldung abgeschaltet
        kopf = self.headers.get("Authorization", "")
        if kopf[:6].lower() != "basic ":
            raise Anfrage(401, "Anmeldung nötig")
        try:
            entschluesselt = base64.b64decode(kopf[6:].strip(), validate=True).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as fehler:
            raise Anfrage(401, "Anmeldung fehlerhaft") from fehler
        gesendet_benutzer, _, gesendet_passwort = entschluesselt.partition(":")
        # Verglichen wird über die UTF-8-Bytes: compare_digest lehnt
        # Zeichenketten mit Sonderzeichen ab (ein Passwort mit Umlaut hätte
        # sonst jede Anmeldung mit einem Serverfehler beendet). Beide
        # Vergleiche werden immer ausgeführt, damit die Antwortzeit nicht
        # verrät, ob schon der Benutzername gepasst hat.
        benutzer_passt = hmac.compare_digest(gesendet_benutzer.encode("utf-8"),
                                             benutzer.encode("utf-8"))
        passwort_passt = hmac.compare_digest(gesendet_passwort.encode("utf-8"),
                                            passwort.encode("utf-8"))
        if not (benutzer_passt & passwort_passt):
            time.sleep(1)                              # Ratenbremse gegen Durchprobieren
            raise Anfrage(401, "Benutzer oder Passwort falsch")

    def _anmeldung_anfordern(self):
        self._antwort_gesendet = True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="CamGrid", charset="UTF-8"')
        self.send_header("Content-Length", "0")
        self.end_headers()

    # --------------------------------------------------------------- Dateien

    def _datei(self, pfad: str):
        """Liefert eine Datei aus web/admin oder web/public - und nur daraus.

        Der angefragte Pfad wird zuerst prozent-entschlüsselt (sonst käme
        "%2e%2e" nie als ".." an, aber auch ein Leerzeichen im Dateinamen
        nicht), danach wird geprüft, dass das Ergebnis wirklich in einem der
        beiden Verzeichnisse liegt.
        """
        pfad = unquote(pfad)
        # Backslash ist unter Windows ein Verzeichnistrenner, unter Linux
        # nicht - ohne diese Zeile wäre die Prüfung auf den beiden Systemen
        # verschieden. Nullbytes und Doppelpunkte (Laufwerksbuchstaben,
        # NTFS-Datenströme) haben in einer Anfrage ebenfalls nichts zu suchen.
        if any(zeichen in pfad for zeichen in ("\\", "\x00", ":")):
            raise Anfrage(400, "Unzulässiger Pfad")

        if pfad in ("/", "/admin", "/admin/"):
            ziel = ADMIN_DATEIEN / "index.html"
        elif pfad.startswith("/admin/"):
            ziel = ADMIN_DATEIEN / pfad[len("/admin/"):]
        elif pfad.startswith("/anzeige/"):
            ziel = ANZEIGE_DATEIEN / pfad[len("/anzeige/"):]
        elif pfad == "/anzeige":
            ziel = ANZEIGE_DATEIEN / "index.html"
        else:
            ziel = ADMIN_DATEIEN / pfad.lstrip("/")

        try:
            ziel = ziel.resolve()
        except OSError as fehler:                  # zu lang, zu viele Symlinks
            raise Anfrage(400, "Unzulässiger Pfad") from fehler

        # is_relative_to vergleicht Pfadteile, nicht Zeichenketten: ein
        # Nachbarverzeichnis wie "web/admin-alt" würde bei einem einfachen
        # startswith() durchrutschen.
        if not any(ziel.is_relative_to(wurzel) for wurzel in (ADMIN_DATEIEN, ANZEIGE_DATEIEN)):
            raise Anfrage(403, "Zugriff verweigert")
        if not ziel.is_file():
            raise Anfrage(404, "Nicht gefunden")

        # Das Dashboard selbst ist geschützt, seine Bausteine ebenso.
        if ziel.is_relative_to(ADMIN_DATEIEN):
            self._anmeldung_pruefen()

        typ = mimetypes.guess_type(ziel.name)[0] or "application/octet-stream"
        if typ.startswith("text/") or typ in ("application/javascript", "application/json"):
            typ += "; charset=utf-8"
        self._senden(200, ziel.read_bytes(), typ)

    # -------------------------------------------------------------- Antworten

    def _json(self, status: int, daten):
        self._senden(status, json.dumps(daten, ensure_ascii=False).encode("utf-8"),
                     "application/json; charset=utf-8")

    def _senden(self, status: int, koerper: bytes, typ: str):
        self._antwort_gesendet = True
        self.send_response(status)
        self.send_header("Content-Type", typ)
        self.send_header("Content-Length", str(len(koerper)))
        # Nichts zwischenspeichern: das Dashboard soll immer den Stand der
        # Konfiguration zeigen, nicht den von vorhin.
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(koerper)
        except (BrokenPipeError, ConnectionResetError):
            pass

    # ------------------------------------------------------------------- API

    def _api(self, methode: str, pfad: str, parameter: dict):
        teile = [t for t in pfad.split("/") if t][1:]   # ohne "api"
        daten = self.server.konfiguration()

        if teile == ["status"] and methode == "GET":
            return self._status(daten)

        if teile == ["config"]:
            if methode == "GET":
                return daten
            if methode == "PUT":
                neu = self._koerper()
                gespeichert = self.server.speichern(neu)
                erfolg, meldung = streams.uebernehmen(gespeichert)
                return {"gespeichert": True, "streams_uebernommen": erfolg, "meldung": meldung,
                        "config": gespeichert}

        if teile == ["kameras"] and methode == "POST":
            return self._kamera_anlegen(self._koerper())

        if len(teile) >= 2 and teile[0] == "kameras":
            kamera_id = teile[1]
            kamera = konfig.kamera_suchen(daten, kamera_id)
            if not kamera:
                raise Anfrage(404, "Kamera nicht gefunden")
            if len(teile) == 2 and methode == "PUT":
                return self._kamera_aendern(kamera_id, self._koerper())
            if len(teile) == 2 and methode == "DELETE":
                return self._kamera_loeschen(kamera_id)
            if teile[2:] == ["pruefen"] and methode == "POST":
                return self._kamera_pruefen(kamera)
            if teile[2:] == ["bild"] and methode == "GET":
                return self._kamera_bild(daten, kamera)

        if teile == ["scan"]:
            if methode == "GET":
                with _scan_sperre:
                    return dict(_scan_zustand)
            if methode == "POST":
                return self._scan_starten(self._koerper())

        if teile == ["scan", "uebernehmen"] and methode == "POST":
            return self._scan_uebernehmen(self._koerper())

        if teile == ["anwenden"] and methode == "POST":
            erfolg, meldung = streams.uebernehmen(daten)
            if not erfolg and self._dienst_neustarten("camgrid-go2rtc"):
                erfolg = True
                meldung += " - Dienst neu gestartet"
            return {"erfolg": erfolg, "meldung": meldung}

        if teile == ["kiosk", "neustart"] and methode == "POST":
            return self._kiosk_neustarten()

        if teile == ["ausgaenge"] and methode == "GET":
            return {"ausgaenge": kioskinfo.angeschlossene_ausgaenge(),
                    "monitore": kioskinfo.zeilen(daten)}

        raise Anfrage(404, f"Unbekannter Aufruf: {methode} {pfad}")

    # ------------------------------------------------------------- Teilstücke

    def _status(self, daten: dict) -> dict:
        port = _port(daten["dienste"].get("go2rtc_port"))
        vorhandene = go2rtc_streams(port)
        self._erstmessung(daten["kameras"])
        kameras = []
        for kamera in daten["kameras"]:
            name = konfig.stream_name(kamera)
            eintrag = vorhandene.get(name) or {}
            erzeuger = eintrag.get("producers") or []
            with _erreichbar_sperre:
                gemessen = _erreichbarkeit.get(kamera["id"])

            kameras.append({
                "id": kamera["id"],
                "name": kamera["name"],
                "ip": kamera["ip"],
                "bekannt": name in vorhandene,
                # None heißt "noch nicht gemessen" (oder keine Adresse
                # eingetragen) - das Dashboard zeigt dann keinen Zustand an.
                "erreichbar": bool(gemessen["erreichbar"]) if gemessen else None,
                # "verbunden" heißt: es schaut gerade jemand zu und das Bild läuft.
                "verbunden": bool(erzeuger and any(p.get("state") == "connected" for p in erzeuger
                                                   if isinstance(p, dict))),
            })
        return {
            "anlage": daten["anlage"]["name"],
            "adresse": eigene_adresse(),
            "dienste": {
                "go2rtc": dienst_zustand("camgrid-go2rtc"),
                "admin": dienst_zustand("camgrid-admin"),
            },
            "go2rtc_erreichbar": bool(vorhandene) or _port_offen(port),
            "kameras": kameras,
            "ausgaenge": kioskinfo.angeschlossene_ausgaenge(),
            "zeit": time.strftime("%Y-%m-%d %H:%M:%S"),
        }

    # So viele Kameras werden höchstens sofort geprüft (siehe _erstmessung).
    ERSTMESSUNG_MAX = 16

    def _erstmessung(self, kameras: list[dict]) -> None:
        """Prüft noch nie gemessene Kameras, damit das Dashboard sofort etwas
        anzeigen kann.

        Der Wächter tut das alle 20 Sekunden von sich aus; beim ersten Aufruf
        nach dem Start liegt aber noch nichts vor. Geprüft wird gleichzeitig
        und nur eine begrenzte Anzahl - sonst würde ein Statusaufruf bei vielen
        Kameras eine Kamera nach der anderen abwarten und minutenlang dauern.
        """
        with _erreichbar_sperre:
            offen = [k for k in kameras if k.get("ip") and k["id"] not in _erreichbarkeit]
        offen = offen[:self.ERSTMESSUNG_MAX]
        if not offen:
            return
        with ThreadPoolExecutor(max_workers=min(16, len(offen))) as pool:
            ergebnisse = list(pool.map(
                lambda k: (k["id"], kamera_erreichbar(k["ip"])), offen))
        jetzt = time.time()
        with _erreichbar_sperre:
            for kamera_id, erreichbar in ergebnisse:
                _erreichbarkeit[kamera_id] = {"erreichbar": erreichbar, "geprueft": jetzt}

    # Felder, die das Dashboard an einer Kamera setzen darf. Alles andere aus
    # der Anfrage wird nicht übernommen.
    KAMERA_FELDER = ("name", "ip", "benutzer", "passwort", "pfad", "breite", "hoehe",
                     "aktiv", "notiz")

    def _kamera_anlegen(self, eingabe: dict) -> dict:
        def aendern(daten: dict) -> str:
            if len(daten["kameras"]) >= konfig.MAX_KAMERAS:
                raise Anfrage(409, f"Mehr als {konfig.MAX_KAMERAS} Kameras sind nicht vorgesehen")
            kamera = konfig.standard_kamera()
            kamera.update({s: eingabe[s] for s in self.KAMERA_FELDER
                           if s in eingabe and s != "aktiv"})
            daten["kameras"].append(kamera)
            return kamera["id"]

        gespeichert, kamera_id = self.server.aendern(aendern)
        streams.uebernehmen(gespeichert)
        return {"kamera": konfig.kamera_suchen(gespeichert, kamera_id), "config": gespeichert}

    def _kamera_aendern(self, kamera_id: str, eingabe: dict) -> dict:
        def aendern(daten: dict) -> None:
            kamera = konfig.kamera_suchen(daten, kamera_id)
            if not kamera:
                raise Anfrage(404, "Kamera nicht gefunden")
            for schluessel in self.KAMERA_FELDER:
                if schluessel in eingabe:
                    kamera[schluessel] = eingabe[schluessel]

        gespeichert, _ = self.server.aendern(aendern)
        streams.uebernehmen(gespeichert)
        return {"kamera": konfig.kamera_suchen(gespeichert, kamera_id), "config": gespeichert}

    def _kamera_loeschen(self, kamera_id: str) -> dict:
        def aendern(daten: dict) -> None:
            if not konfig.kamera_suchen(daten, kamera_id):
                raise Anfrage(404, "Kamera nicht gefunden")
            daten["kameras"] = [k for k in daten["kameras"] if k["id"] != kamera_id]

        # Die Kacheln werden beim Speichern mitbereinigt.
        gespeichert, _ = self.server.aendern(aendern)
        streams.uebernehmen(gespeichert)
        return {"geloescht": kamera_id, "config": gespeichert}

    def _kamera_pruefen(self, kamera: dict) -> dict:
        """Prüft eine Kamera: erst der schnelle eigene RTSP-Test, dann der
        ausführliche Weg über scan.py (Ports, ONVIF, Hersteller)."""
        zugangsdaten = [{"benutzer": kamera.get("benutzer", ""),
                         "passwort": kamera.get("passwort", "")}]

        # Bekannten Pfad zuerst, danach die üblichen Verdächtigen.
        pfade = []
        if kamera.get("pfad"):
            pfade.append(kamera["pfad"])
        pfade += [p for p in getattr(scan, "STANDARD_PFADE", ["stream1", "stream2"])
                  if p not in pfade][:12]

        treffer = rtsp.pfade_testen(kamera["ip"], pfade, zugangsdaten)
        if treffer:
            # Den Strom bevorzugen, den die Kamera schon eingetragen hat, sonst
            # den kleinsten - der belastet die Anzeige am wenigsten.
            passend = next((t for t in treffer if t["pfad"] == kamera.get("pfad")), treffer[-1])
            return {"ergebnis": {
                "ip": kamera["ip"], "erreichbar": True, "ports": [554], "onvif": False,
                "benutzer": passend["benutzer"], "passwort": passend["passwort"],
                "stream": {"pfad": passend["pfad"], "breite": passend["breite"],
                           "hoehe": passend["hoehe"], "codec": passend["codec"],
                           "fps": passend["fps"]},
                "weitere_streams": treffer, "hersteller": None, "fehler": None,
            }}

        ergebnis = scan.kamera_pruefen(kamera["ip"], zugangsdaten, pfade=pfade or None)
        return {"ergebnis": ergebnis}

    def _kamera_bild(self, daten: dict, kamera: dict):
        """Einzelbild der Kamera für die Vorschau im Dashboard.

        Zuerst direkt bei der Kamera (braucht kein ffmpeg und geht am
        schnellsten), sonst über go2rtc.
        """
        if not kamera.get("ip"):
            raise Anfrage(400, "Für diese Kamera ist keine Adresse eingetragen")
        bild, quelle = kamerabild.bild_holen(
            kamera["ip"], kamera.get("benutzer", ""), kamera.get("passwort", ""),
            kamera.get("pfad", ""), gesamt=20.0)
        if bild:
            return bild, "image/jpeg"

        port = _port(daten["dienste"].get("go2rtc_port"))
        name = konfig.stream_name(kamera)
        try:
            adresse = f"http://127.0.0.1:{port}/api/frame.jpeg?src={name}"
            with urllib.request.urlopen(adresse, timeout=12) as antwort:
                ueber_dienst = antwort.read()
            if kamerabild.bild_pruefen(ueber_dienst):
                return ueber_dienst, "image/jpeg"
        except (OSError, urllib.error.URLError):
            pass

        raise Anfrage(503, quelle or "Kein Bild verfügbar")

    # ----------------------------------------------------------------- Suche

    def _scan_starten(self, eingabe: dict) -> dict:
        daten = self.server.konfiguration()
        netz = str(eingabe.get("netz") or daten["scan"].get("netz") or "").strip()
        if not netz:
            raise Anfrage(400, "Bitte einen Netzbereich angeben, z. B. 192.168.1.0/24")
        eigene = eingabe.get("zugangsdaten")
        zugangsdaten = eigene if isinstance(eigene, list) else daten["scan"].get("zugangsdaten") or []
        zugangsdaten = [z for z in zugangsdaten if isinstance(z, dict)][:32]

        # Den Bereich sofort prüfen, damit ein Tippfehler gleich gemeldet wird
        # und nicht erst als Fehler im Hintergrundlauf auftaucht.
        try:
            anzahl = len(scan.netz_hosts(netz))
        except ValueError as fehler:
            raise Anfrage(400, str(fehler)) from fehler
        if anzahl == 0:
            raise Anfrage(400, "In diesem Bereich liegt keine einzige Adresse.")

        with _scan_sperre:
            if _scan_zustand["laeuft"]:
                raise Anfrage(409, "Es läuft bereits eine Suche")
            _scan_zustand.update({"laeuft": True, "fertig": 0, "gesamt": 0, "ip": "",
                                  "treffer": [], "fehler": None, "netz": netz})

        try:
            # Netz und Zugangsdaten für das nächste Mal merken.
            def merken(gespeichert: dict) -> None:
                gespeichert["scan"]["netz"] = netz
                if zugangsdaten:
                    gespeichert["scan"]["zugangsdaten"] = zugangsdaten

            self.server.aendern(merken)
        except Exception:                              # noqa: BLE001
            # Lässt sich die Konfiguration nicht schreiben, ist das kein Grund,
            # die Suche zu verweigern - aber der Zustand muss wieder frei
            # werden, sonst behauptet der Server für immer "Suche läuft".
            with _scan_sperre:
                _scan_zustand["laeuft"] = False
            raise

        threading.Thread(target=self._scan_lauf, args=(netz, zugangsdaten), daemon=True).start()
        return {"gestartet": True, "netz": netz}

    @staticmethod
    def _scan_lauf(netz: str, zugangsdaten: list):
        def fortschritt(fertig, gesamt, ip):
            with _scan_sperre:
                _scan_zustand.update({"fertig": fertig, "gesamt": gesamt, "ip": ip})

        try:
            treffer = scan.netz_scannen(netz, zugangsdaten, fortschritt=fortschritt)
            with _scan_sperre:
                _scan_zustand["treffer"] = treffer
        except Exception as fehler:                    # noqa: BLE001
            with _scan_sperre:
                _scan_zustand["fehler"] = str(fehler)
        finally:
            with _scan_sperre:
                _scan_zustand["laeuft"] = False

    def _scan_uebernehmen(self, eingabe: dict) -> dict:
        gefunden = eingabe.get("kameras")
        if not isinstance(gefunden, list):
            raise Anfrage(400, "Es wird eine Liste unter \"kameras\" erwartet")

        def aendern(daten: dict) -> int:
            vorhandene = {k["ip"] for k in daten["kameras"] if k["ip"]}
            anzahl = 0
            for eintrag in gefunden[:konfig.MAX_KAMERAS]:
                if not isinstance(eintrag, dict):
                    continue
                ip = str(eintrag.get("ip") or "").strip()
                if not ip or ip in vorhandene:
                    continue
                if len(daten["kameras"]) >= konfig.MAX_KAMERAS:
                    break
                stream = eintrag.get("stream")
                stream = stream if isinstance(stream, dict) else {}
                kamera = konfig.standard_kamera(ip=ip, name=eintrag.get("name") or f"Kamera {ip}")
                kamera.update({
                    "benutzer": eintrag.get("benutzer") or "",
                    "passwort": eintrag.get("passwort") or "",
                    # Kameras ohne RTSP bringen eine eigene Adresse mit.
                    "quelle": eintrag.get("quelle") or "",
                    "art": "mjpeg" if eintrag.get("art") == "mjpeg" else "rtsp",
                    "pfad": stream.get("pfad") or kamera["pfad"],
                    # Die Zahlen kommen aus einer Fremdantwort: nicht int()
                    # darauf loslassen, das wirft bei "grosz" eine Ausnahme.
                    "breite": stream.get("breite") or 0,
                    "hoehe": stream.get("hoehe") or 0,
                })
                daten["kameras"].append(kamera)
                vorhandene.add(ip)
                anzahl += 1
            return anzahl

        gespeichert, anzahl = self.server.aendern(aendern)
        streams.uebernehmen(gespeichert)
        return {"hinzugefuegt": anzahl, "config": gespeichert}

    # --------------------------------------------------------------- Dienste

    def _dienst_neustarten(self, name: str) -> bool:
        if not shutil.which("systemctl"):
            return False
        befehl = ["systemctl", "restart", name]
        # Als normaler Benutzer geht das nur über sudo (ohne Passwortfrage).
        if hasattr(os, "geteuid") and os.geteuid() != 0:
            befehl = ["sudo", "-n", *befehl]
        try:
            ergebnis = subprocess.run(befehl, capture_output=True, text=True, timeout=30, check=False)
            return ergebnis.returncode == 0
        except (OSError, subprocess.SubprocessError):
            return False

    def _kiosk_neustarten(self) -> dict:
        skript = WURZEL / "scripts" / "kiosk.sh"
        if not skript.exists():
            raise Anfrage(404, "kiosk.sh nicht gefunden")
        try:
            subprocess.Popen(["sh", str(skript), "--neustart"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except (OSError, subprocess.SubprocessError) as fehler:
            raise Anfrage(500, f"Anzeige konnte nicht neu gestartet werden: {fehler}") from fehler
        return {"erfolg": True, "meldung": "Anzeige wird neu gestartet"}


def _port(wert, vorgabe: int = 1984) -> int:
    """Portnummer aus der Konfiguration, notfalls die Vorgabe.

    Ein von Hand eingetragener Unsinn ("achtzig") darf nicht dazu führen,
    dass jeder Statusaufruf mit einem Serverfehler endet.
    """
    try:
        zahl = int(wert)
    except (TypeError, ValueError, OverflowError):
        return vorgabe
    return zahl if 1 <= zahl <= 65535 else vorgabe


def _port_offen(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


# --------------------------------------------------------------------------
# Start
# --------------------------------------------------------------------------

def hauptprogramm(argumente=None) -> int:
    zerleger = argparse.ArgumentParser(description="Admin-Server von CamGrid")
    zerleger.add_argument("--config", default=str(konfig.STANDARD_PFAD),
                          help="Pfad zur Konfigurationsdatei")
    zerleger.add_argument("--port", type=int, default=0,
                          help="Port (Vorgabe: aus der Konfiguration, sonst 8080)")
    zerleger.add_argument("--adresse", default="0.0.0.0", help="Adresse zum Lauschen")
    werte = zerleger.parse_args(argumente)

    config_pfad = Path(werte.config)
    try:
        daten = konfig.laden(config_pfad)
    except (ValueError, OSError) as fehler:
        # Eine kaputte Datei ist ein Bedienfehler, kein Programmfehler: eine
        # Zeile Klartext hilft mehr als eine Rückverfolgung.
        print(f"Konfiguration nicht lesbar: {fehler}", file=sys.stderr)
        return 1
    if not config_pfad.exists():
        konfig.speichern(daten, config_pfad)
        print(f"Neue Konfiguration angelegt: {config_pfad}")
        print(f"Admin-Zugang: {daten['zugang']['admin_benutzer']} / {daten['zugang']['admin_passwort']}")

    # Beim Start einmal alles ableiten, damit Anzeigeseite und Streaming-Dienst
    # auch nach einem Neustart sofort zur Konfiguration passen.
    try:
        streams.schreiben(daten)
    except OSError as fehler:
        print(f"Warnung: abgeleitete Dateien nicht schreibbar: {fehler}", file=sys.stderr)

    port = werte.port or _port(daten["dienste"].get("admin_port"), 8080)
    try:
        dienst = Dienst((werte.adresse, port), Handler, config_pfad)
    except OSError as fehler:
        print(f"Port {port} auf {werte.adresse} ist nicht nutzbar: {fehler}", file=sys.stderr)
        return 1
    waechter_starten(dienst)
    print(f"CamGrid-Dashboard läuft auf http://{eigene_adresse()}:{port}/")
    try:
        dienst.serve_forever()
    except KeyboardInterrupt:
        print("Beendet.")
    finally:
        dienst.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(hauptprogramm())
