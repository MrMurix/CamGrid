"""Selbsttest von CamGrid: startet den Server und ruft alle Wege einmal auf.

Aufruf:  python test/test_server.py
Erwartet nichts weiter als Python - ohne Kameras, ohne go2rtc, ohne systemd.
"""

from __future__ import annotations

import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

WURZEL = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(WURZEL))

PORT = 8123
BASIS = f"http://127.0.0.1:{PORT}"
BENUTZER, PASSWORT = "pruefer", "geheim123"

fehler: list[str] = []
erfolge = 0


def pruefe(bedingung: bool, was: str) -> None:
    global erfolge
    if bedingung:
        erfolge += 1
        print(f"  ok   {was}")
    else:
        fehler.append(was)
        print(f"  FEHL {was}")


def ruf(pfad: str, methode: str = "GET", koerper=None, anmeldung=True, roh=False,
        zugang=None, kopf=None):
    """Ruft die Schnittstelle auf. `zugang` ist (Benutzer, Passwort)."""
    anfrage = urllib.request.Request(f"{BASIS}{pfad}", method=methode)
    if koerper is not None:
        anfrage.data = json.dumps(koerper).encode("utf-8")
        anfrage.add_header("Content-Type", "application/json")
    if anmeldung:
        benutzer, passwort = zugang or (BENUTZER, PASSWORT)
        schluessel = base64.b64encode(f"{benutzer}:{passwort}".encode()).decode()
        anfrage.add_header("Authorization", f"Basic {schluessel}")
    for name, wert in (kopf or {}).items():
        anfrage.add_header(name, wert)
    try:
        with urllib.request.urlopen(anfrage, timeout=30) as antwort:
            inhalt = antwort.read()
            if roh:
                return antwort.status, inhalt
            return antwort.status, json.loads(inhalt.decode("utf-8") or "null")
    except urllib.error.HTTPError as ausnahme:
        return ausnahme.code, None
    except urllib.error.URLError as ausnahme:
        return 0, str(ausnahme)


def roher_pfad(pfad: str) -> int:
    """Schickt einen Pfad wortwörtlich, ohne dass urllib ihn glättet.

    urllib würde "/admin/../x" selbst zusammenfassen - für die Prüfung des
    Pfadausbruchs muss aber genau das ungeglättete Original ankommen.
    """
    schluessel = base64.b64encode(f"{BENUTZER}:{PASSWORT}".encode()).decode()
    anfrage = (f"GET {pfad} HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n"
               f"Authorization: Basic {schluessel}\r\nConnection: close\r\n\r\n")
    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=10) as verbindung:
            verbindung.sendall(anfrage.encode("utf-8"))
            antwort = b""
            while b"\r\n" not in antwort:
                stueck = verbindung.recv(4096)
                if not stueck:
                    break
                antwort += stueck
    except OSError:
        return 0
    teile = antwort.split(b" ")
    return int(teile[1]) if len(teile) > 1 and teile[1].isdigit() else 0


def abgewiesen_und_weiter() -> tuple[int, int]:
    """Prüft, ob eine abgewiesene Anfrage mit Inhalt die Verbindung heil lässt.

    Bei HTTP/1.1 bleibt die Verbindung offen. Liest der Server den Inhalt
    einer mit 401 abgewiesenen Anfrage nicht weg, liegt er noch im Puffer und
    wird als nächste Anfrage gelesen - die zweite Antwort wäre dann Unsinn.
    Rückgabe: (Status der abgewiesenen Anfrage, Status der zweiten Anfrage).
    """
    inhalt = json.dumps({"name": "x" * 500}).encode("utf-8")
    schluessel = base64.b64encode(b"falsch:falsch").decode()
    erste = (f"PUT /api/config HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n"
             f"Authorization: Basic {schluessel}\r\nContent-Type: application/json\r\n"
             f"Content-Length: {len(inhalt)}\r\n\r\n").encode("utf-8") + inhalt
    gut = base64.b64encode(f"{BENUTZER}:{PASSWORT}".encode()).decode()
    zweite = (f"GET /api/status HTTP/1.1\r\nHost: 127.0.0.1:{PORT}\r\n"
              f"Authorization: Basic {gut}\r\nConnection: close\r\n\r\n").encode("utf-8")

    def status(rohdaten: bytes) -> int:
        teile = rohdaten.split(b" ")
        return int(teile[1]) if len(teile) > 1 and teile[1].isdigit() else 0

    try:
        with socket.create_connection(("127.0.0.1", PORT), timeout=30) as verbindung:
            verbindung.sendall(erste)
            verbindung.settimeout(20)
            antwort = b""
            while b"\r\n\r\n" not in antwort:
                stueck = verbindung.recv(4096)
                if not stueck:
                    return 0, 0
                antwort += stueck
            erster_status = status(antwort)
            verbindung.sendall(zweite)
            rest = antwort.partition(b"\r\n\r\n")[2]
            while b"\r\n" not in rest:
                stueck = verbindung.recv(4096)
                if not stueck:
                    break
                rest += stueck
            return erster_status, status(rest)
    except OSError:
        return 0, 0


def hauptlauf() -> int:
    arbeitsverzeichnis = Path(tempfile.mkdtemp(prefix="camgrid-test-"))
    config_pfad = arbeitsverzeichnis / "config.json"
    web = arbeitsverzeichnis / "public"
    web.mkdir()

    from app import config as konfig

    start = konfig.standard_konfiguration()
    start["zugang"]["admin_benutzer"] = BENUTZER
    start["zugang"]["admin_passwort"] = PASSWORT
    # Eigener Port, damit der Test keinen echten Streaming-Dienst auf diesem
    # Rechner anfasst (der lauscht auf 1984).
    start["dienste"]["go2rtc_port"] = 19845
    konfig.speichern(start, config_pfad)

    umgebung = {
        **os.environ,
        "CAMGRID_CONFIG": str(config_pfad),
        "CAMGRID_GO2RTC_YAML": str(arbeitsverzeichnis / "go2rtc.yaml"),
        "CAMGRID_WEB": str(web),
        "PYTHONIOENCODING": "utf-8",
    }
    server = subprocess.Popen(
        [sys.executable, str(WURZEL / "app" / "server.py"),
         "--config", str(config_pfad), "--port", str(PORT), "--adresse", "127.0.0.1"],
        env=umgebung, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )

    try:
        for _ in range(50):                       # auf den Start warten
            zustand, _antwort = ruf("/api/status")
            if zustand == 200:
                break
            time.sleep(0.2)
        else:
            print("Server ist nicht gestartet:")
            print(server.communicate(timeout=5)[0])
            return 1

        print("Anmeldung")
        pruefe(ruf("/api/config", anmeldung=False)[0] == 401, "ohne Anmeldung abgewiesen")
        pruefe(ruf("/api/config")[0] == 200, "mit Anmeldung erlaubt")
        pruefe(ruf("/../app/config.py", roh=True)[0] in (403, 404), "kein Ausbruch aus dem Web-Verzeichnis")

        print("Kameras")
        zustand, antwort = ruf("/api/kameras", "POST", {"name": "Tor Nord", "ip": "192.0.2.10"})
        pruefe(zustand == 200 and antwort["kamera"]["name"] == "Tor Nord", "Kamera anlegen")
        kamera_id = antwort["kamera"]["id"]

        zustand, antwort = ruf(f"/api/kameras/{kamera_id}", "PUT",
                               {"name": "Tor Nord neu", "pfad": "stream1"})
        pruefe(zustand == 200 and antwort["kamera"]["pfad"] == "stream1", "Kamera ändern")

        zustand, antwort = ruf("/api/kameras/gibtsnicht", "PUT", {"name": "x"})
        pruefe(zustand == 404, "unbekannte Kamera meldet 404")

        print("Konfiguration und Kacheln")
        _zustand, config = ruf("/api/config")
        config["monitore"][0]["spalten"] = 3
        config["monitore"][0]["kacheln"] = [
            {"kamera_id": kamera_id, "platz": 1, "breite": 2, "hoehe": 1},
            {"kamera_id": kamera_id, "platz": 99, "breite": 1, "hoehe": 1},   # ungültig
        ]
        zustand, antwort = ruf("/api/config", "PUT", config)
        kacheln = antwort["config"]["monitore"][0]["kacheln"]
        pruefe(zustand == 200 and len(kacheln) == 1, "ungültige Kachel wird verworfen")
        pruefe(kacheln[0]["breite"] == 2, "Kachelbreite bleibt erhalten")

        anzeige = json.loads((web / "anzeige.json").read_text(encoding="utf-8"))
        pruefe("passwort" not in json.dumps(anzeige), "anzeige.json enthält keine Passwörter")
        pruefe(anzeige["kameras"][0].get("ip") is None, "anzeige.json enthält keine IP-Adressen")

        yaml = (arbeitsverzeichnis / "go2rtc.yaml").read_text(encoding="utf-8")
        # Der Wert steht in Anführungszeichen, damit ein Sonderzeichen im Pfad
        # oder im Passwort keine eigene YAML-Zeile erzeugen kann.
        pruefe(f'{kamera_id}: "rtsp://' in yaml, "Stream steht in der go2rtc-Konfiguration")

        print("Kamerasuche")
        zustand, antwort = ruf("/api/scan", "POST", {"netz": "192.0.2.0/30",
                                                     "zugangsdaten": [{"benutzer": "a", "passwort": "b"}]})
        pruefe(zustand == 200, "Suche startet")
        for _ in range(120):
            zustand, stand = ruf("/api/scan")
            if not stand["laeuft"]:
                break
            time.sleep(0.5)
        pruefe(not stand["laeuft"] and stand["fehler"] is None, "Suche läuft durch (ohne Treffer)")

        zustand, antwort = ruf("/api/scan", "POST", {"netz": "unsinn"})
        pruefe(zustand in (400, 500), "unsinniger Netzbereich wird abgelehnt")

        zustand, antwort = ruf("/api/scan/uebernehmen", "POST",
                               {"kameras": [{"ip": "192.0.2.50", "name": "Gefunden",
                                             "stream": {"pfad": "stream2", "breite": 640, "hoehe": 480}}]})
        pruefe(zustand == 200 and antwort["hinzugefuegt"] == 1, "gefundene Kamera übernehmen")
        pruefe(any(k["ip"] == "192.0.2.50" for k in antwort["config"]["kameras"]), "Kamera ist eingetragen")

        print("Böse Eingaben: go2rtc.yaml")
        yaml_pfad = arbeitsverzeichnis / "go2rtc.yaml"
        _zustand, config = ruf("/api/config")
        config["kameras"] += [
            {   # versucht, über die ID einen zweiten YAML-Schlüssel zu setzen
                "id": "boese: nein\n  eingeschleust: rtsp://127.0.0.1/x",
                "name": "Einschleusversuch 1",
                "ip": "192.0.2.77\n  eingeschleust: rtsp://127.0.0.1/x",
                "benutzer": "a\nb", "passwort": "c: d\n  e",
            },
            {   # gültige IP, aber Pfad und Passwort voller Sonderzeichen
                "name": "Einschleusversuch 2",
                "ip": "192.0.2.99",
                "pfad": "stream1\"\n  zweiter: rtsp://127.0.0.1/y\n#",
                "passwort": "p\"a: ss\nwort",
            },
        ]
        zustand, antwort = ruf("/api/config", "PUT", config)
        pruefe(zustand == 200, "Kamera mit Sonderzeichen wird angenommen")
        yaml = yaml_pfad.read_text(encoding="utf-8")
        zeilen = yaml.splitlines()
        # Jede Zeile ist entweder Kommentar, Abschnittskopf ("streams:") oder
        # eingerückter Wert. Eine eingeschleuste Zeile wäre keins davon.
        pruefe(all(not z or z.startswith(("#", "  ")) or z.endswith(":") for z in zeilen),
               "go2rtc.yaml enthält keine eingeschleuste Zeile")
        erwartet = [k for k in antwort["config"]["kameras"] if k["ip"] and k["aktiv"]]
        stroeme = [z for z in zeilen if z.startswith("  ") and '"rtsp://' in z]
        pruefe(len(stroeme) == len(erwartet),
               f"genau {len(erwartet)} Ströme in der go2rtc.yaml (gezählt: {len(stroeme)})")
        pruefe(all(z.count('"') == 2 for z in stroeme),
               "jede Stream-Adresse steht vollständig in Anführungszeichen")

        erster = next(k for k in antwort["config"]["kameras"] if k["name"] == "Einschleusversuch 1")
        pruefe(erster["ip"] == "", "unbrauchbare IP wird verworfen")
        pruefe("\n" not in erster["id"] + erster["benutzer"] + erster["passwort"],
               "Zeilenumbrüche sind aus den Kamerafeldern entfernt")
        zweiter = next(k for k in antwort["config"]["kameras"] if k["name"] == "Einschleusversuch 2")
        pruefe('"' not in zweiter["pfad"] and " " not in zweiter["pfad"],
               "Anführungszeichen und Leerzeichen sind aus dem Pfad entfernt")

        print("Böse Eingaben: Konfigurationswerte")
        _zustand, config = ruf("/api/config")
        config["dienste"]["go2rtc_port"] = "achtzig"
        config["anzeige"]["bildrate"] = -5
        config["anzeige"]["hintergrund"] = "#000; body{display:none}"
        config["anzeige"]["aufloesung"] = "riesig"
        config["monitore"][0]["ausgang"] = "HDMI-1; rm -rf /"
        config["kameras"] += [{"id": "doppelt", "name": "A" * 5000, "breite": -9,
                               "hoehe": 10 ** 12},
                              {"id": "doppelt", "name": "B"}]
        zustand, antwort = ruf("/api/config", "PUT", config)
        neu = antwort["config"] if zustand == 200 else {}
        pruefe(zustand == 200 and neu["dienste"]["go2rtc_port"] == 1984,
               "unsinniger Port wird durch die Vorgabe ersetzt")
        pruefe(neu["anzeige"]["bildrate"] >= 1, "negative Bildrate wird begrenzt")
        pruefe(";" not in neu["anzeige"]["hintergrund"], "Hintergrundfarbe wird geprüft")
        pruefe(neu["anzeige"]["aufloesung"] == "1920x1080", "unsinnige Auflösung wird ersetzt")
        pruefe(neu["monitore"][0]["ausgang"] == "", "unbrauchbarer Ausgangsname wird verworfen")
        gross, doppelt = neu["kameras"][-2], neu["kameras"][-1]
        pruefe(len(gross["name"]) <= 200, "überlanger Name wird gekürzt")
        pruefe(gross["breite"] == 0 and gross["hoehe"] <= 16384,
               "unsinnige Bildgröße wird begrenzt")
        pruefe(gross["id"] != doppelt["id"], "doppelte Kamera-ID wird aufgelöst")
        pruefe(ruf("/api/status")[0] == 200, "Status bleibt nach bösen Werten abrufbar")
        pruefe(ruf("/api/ausgaenge")[0] == 200, "Ausgänge bleiben abrufbar")
        neu["dienste"]["go2rtc_port"] = 19845     # wieder auf den Prüfport
        pruefe(ruf("/api/config", "PUT", neu)[0] == 200, "Prüfport wieder eingetragen")
        zeile = ruf("/api/ausgaenge")[1]["monitore"][0]
        pruefe(bool(re.fullmatch(r"MONITOR=\d+;AUSGANG=[0-9A-Za-z._-]*;X=\d+;BREITE=\d+;"
                                 r"HOEHE=\d+;BILDRATE=\d+;PORT=\d+", zeile)),
               f"Zeile für kiosk.sh enthält nur erwartete Angaben: {zeile}")

        print("Pfadprüfung")
        for versuch in ("/../app/config.py", "/admin/../../app/config.py",
                        "/admin/%2e%2e/%2e%2e/app/config.py",
                        "/%2e%2e%2f%2e%2e%2fapp/config.py",
                        "/admin/..\\..\\app\\config.py",
                        "/anzeige/../../install.sh",
                        "/admin/index.html\x00.txt".replace("\x00", "%00")):
            zustand = roher_pfad(versuch)
            pruefe(zustand in (400, 403, 404), f"kein Ausbruch über {versuch!r} (Status {zustand})")
        pruefe(roher_pfad("/admin/C:/Windows/win.ini") in (400, 403, 404),
               "kein Zugriff über einen Laufwerksbuchstaben")
        # Der Weg aus dem offenen Verzeichnis in das Dashboard ist kein
        # Ausbruch (beide Verzeichnisse werden ausgeliefert), er darf aber
        # nicht an der Anmeldung vorbeiführen.
        pruefe(ruf("/anzeige/../admin/index.html", roh=True, anmeldung=False)[0] in (401, 404),
               "Umweg über /anzeige/ umgeht die Anmeldung nicht")

        print("Anmeldung: Randfälle")
        pruefe(ruf("/api/config", kopf={"Authorization": "Basic ???"},
                   anmeldung=False)[0] == 401, "unlesbare Anmeldung ergibt 401")
        pruefe(ruf("/api/config", kopf={"Authorization": "Bearer abc"},
                   anmeldung=False)[0] == 401, "fremdes Anmeldeverfahren ergibt 401")
        pruefe(ruf("/api/config", zugang=(BENUTZER, ""))[0] == 401, "leeres Passwort ergibt 401")
        pruefe(ruf("/api/config", zugang=("", PASSWORT))[0] == 401, "leerer Benutzer ergibt 401")
        erster, zweiter = abgewiesen_und_weiter()
        pruefe(erster == 401 and zweiter == 200,
               "Verbindung bleibt nach abgewiesener Anfrage mit Inhalt brauchbar")

        # Ein Passwort mit Umlaut darf die Anmeldung nicht mit einem
        # Serverfehler beenden (Vergleich läuft über die UTF-8-Bytes).
        _zustand, config = ruf("/api/config")
        config["zugang"]["admin_passwort"] = "Süßes!23"
        pruefe(ruf("/api/config", "PUT", config)[0] == 200, "Passwort mit Umlaut setzen")
        pruefe(ruf("/api/status", zugang=(BENUTZER, "Süßes!23"))[0] == 200,
               "Anmeldung mit Umlaut im Passwort klappt")
        pruefe(ruf("/api/status", zugang=(BENUTZER, "Süßes!24"))[0] == 401,
               "falsches Passwort mit Umlaut ergibt 401")
        config["zugang"]["admin_passwort"] = PASSWORT
        pruefe(ruf("/api/config", "PUT", config, zugang=(BENUTZER, "Süßes!23"))[0] == 200,
               "Passwort zurücksetzen")

        print("Kaputte Konfiguration")
        gut = config_pfad.read_text(encoding="utf-8")
        config_pfad.write_text("{das ist kein JSON", encoding="utf-8")
        zustand, _antwort = ruf("/api/status")
        pruefe(zustand in (400, 500), "kaputte Datei ergibt einen Fehlerstatus")
        config_pfad.write_text(gut, encoding="utf-8")
        pruefe(ruf("/api/status")[0] == 200, "Server lebt danach weiter")

        print("Gleichzeitige Änderungen")
        _zustand, config = ruf("/api/config")
        vorher = len(config["kameras"])
        ergebnisse: list[int] = []
        sperre = threading.Lock()

        def anlegen(nummer: int) -> None:
            zustand, _antwort = ruf("/api/kameras", "POST",
                                    {"name": f"Gleichzeitig {nummer}"})
            with sperre:
                ergebnisse.append(zustand)

        faeden = [threading.Thread(target=anlegen, args=(nummer,)) for nummer in range(1, 9)]
        for faden in faeden:
            faden.start()
        for faden in faeden:
            faden.join(60)
        _zustand, config = ruf("/api/config")
        namen = {k["name"] for k in config["kameras"]}
        neue = {f"Gleichzeitig {nummer}" for nummer in range(1, 9)}
        pruefe(all(zustand == 200 for zustand in ergebnisse) and len(ergebnisse) == 8,
               "acht gleichzeitige Anfragen werden alle beantwortet")
        pruefe(neue <= namen,
               f"keine Änderung geht verloren ({len(neue & namen)} von 8 sind eingetragen)")
        pruefe(len(config["kameras"]) == vorher + 8, "und keine Kamera zu viel")

        print("Sonstiges")
        pruefe(ruf("/api/ausgaenge")[0] == 200, "Bildschirmausgänge abfragen")
        zustand, antwort = ruf("/api/anwenden", "POST", {})
        pruefe(zustand == 200 and antwort["erfolg"] is False,
               "Anwenden meldet ehrlich, dass go2rtc nicht läuft")
        ohne_ip = next(k["id"] for k in config["kameras"] if not k["ip"])
        pruefe(ruf(f"/api/kameras/{ohne_ip}/bild")[0] == 400,
               "Vorschau ohne Adresse wird sofort abgelehnt")
        pruefe(ruf("/api/status")[1]["kameras"][0]["bekannt"] is False, "Status kennt die Kameras")
        pruefe(ruf("/api/gibtsnicht")[0] == 404, "unbekannter Aufruf meldet 404")
        pruefe(ruf("/", roh=True)[0] == 200, "Dashboard wird ausgeliefert")
        pruefe(ruf("/admin/admin.js", roh=True)[0] == 200, "Dashboard-Programm wird ausgeliefert")

        zustand, antwort = ruf(f"/api/kameras/{kamera_id}", "DELETE")
        pruefe(zustand == 200, "Kamera löschen")
        _zustand, config = ruf("/api/config")
        pruefe(all(k["id"] != kamera_id for k in config["kameras"]), "Kamera ist weg")
        pruefe(all(kachel["kamera_id"] != kamera_id
                   for m in config["monitore"] for kachel in m["kacheln"]),
               "Kacheln der gelöschten Kamera sind bereinigt")

    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
        shutil.rmtree(arbeitsverzeichnis, ignore_errors=True)

    print()
    if fehler:
        print(f"{len(fehler)} von {len(fehler) + erfolge} Prüfungen fehlgeschlagen:")
        for eintrag in fehler:
            print(f"  - {eintrag}")
        return 1
    print(f"Alle {erfolge} Prüfungen bestanden.")
    return 0


if __name__ == "__main__":
    raise SystemExit(hauptlauf())
