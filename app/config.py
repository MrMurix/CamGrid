"""Konfiguration von CamGrid: laden, prüfen, speichern.

Die gesamte Anlage steckt in einer einzigen JSON-Datei (Standard:
/etc/camgrid/config.json). Sie kann von Hand bearbeitet oder über das
Admin-Dashboard geändert werden. Dieses Modul ist die einzige Stelle, die
die Datei liest und schreibt.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import string
import tempfile
import threading
from pathlib import Path

STANDARD_PFAD = Path(os.environ.get("CAMGRID_CONFIG", "/etc/camgrid/config.json"))

# Bei jeder Änderung des Aufbaus hochzählen und in `_migrieren` ergänzen.
AKTUELLE_VERSION = 1

_sperre = threading.RLock()

# --------------------------------------------------------------------------
# Grenzen und erlaubte Zeichen
#
# Aus dieser Datei werden go2rtc.yaml, RTSP-Adressen und die Zeilen für
# kiosk.sh erzeugt. Alles, was von außen hereinkommt (Dashboard, von Hand
# bearbeitete Datei), wird deshalb hier einmal gründlich begradigt - danach
# kann keine Kamera-Angabe mehr eine erzeugte Datei zerreißen.
# --------------------------------------------------------------------------

MAX_TEXT = 200            # Namen, Notizen, Benutzer, Passwörter
MAX_KAMERAS = 512         # mehr Kameras kann ein Anzeigerechner nicht liefern
MAX_MONITORE = 16
MAX_PIXEL = 16384         # größer ist keine Auflösung eines Videostroms

# Steuerzeichen haben in keinem Textfeld etwas zu suchen: sie würden
# go2rtc.yaml, die Zeilen für kiosk.sh oder HTTP-Kopfzeilen zerreißen.
_STEUERZEICHEN = re.compile(r"[\x00-\x1f\x7f]")

# Kamera-IDs werden zu Stream-Namen in go2rtc (YAML-Schlüssel und Teil einer
# Adresse), Ausgangsnamen gehen als Variable an xrandr in kiosk.sh.
_ID_VERBOTEN = re.compile(r"[^0-9A-Za-z_-]")
# Ausgangsnamen werden nicht zurechtgeschnitten, sondern ganz verworfen:
# "HDMI-1" ist ein Name, "HDMI-1; rm -rf /" ist keiner.
_AUSGANG_MUSTER = re.compile(r"^[0-9A-Za-z._-]{1,32}$")

# IP oder Hostname der Kamera - nur das, was in einer RTSP-Adresse stehen darf.
_IP_MUSTER = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.\-]{0,252}$")

# Im RTSP-Pfad sind genau die Zeichen erlaubt, die eine Adresse nach RFC 3986
# vertragen kann. Leerzeichen, Zeilenumbrüche, Anführungszeichen und
# Backslash fallen damit weg - genau die Zeichen, mit denen sich sonst etwas
# in die go2rtc.yaml oder in die RTSP-Adresse einschleusen ließe.
_PFAD_VERBOTEN = re.compile(r"[^0-9A-Za-z._~:/?#\[\]@!$&'()*+,;=%-]")

# Hintergrundfarbe der Anzeigeseite: Kürzel (#0e1116) oder CSS-Farbwort.
_FARBE_MUSTER = re.compile(r"^(#[0-9A-Fa-f]{3,8}|[A-Za-z]{1,20})$")
_AUFLOESUNG_MUSTER = re.compile(r"^[0-9]{2,5}x[0-9]{2,5}$")


# --------------------------------------------------------------------------
# Vorgaben
# --------------------------------------------------------------------------

# Zugangsdaten beim ersten Start. Bewusst fest und dokumentiert - ein
# zufälliges Passwort hilft niemandem, der das Gerät ohne Bildschirm aufsetzt.
STANDARD_BENUTZER = "admin"
STANDARD_PASSWORT = "camgrid"


def passwort_erzeugen(laenge: int = 12) -> str:
    """Erzeugt ein zufälliges Passwort ohne leicht verwechselbare Zeichen."""
    zeichen = string.ascii_letters + string.digits
    for unklar in "lI1O0":
        zeichen = zeichen.replace(unklar, "")
    return "".join(secrets.choice(zeichen) for _ in range(laenge))


def standard_konfiguration() -> dict:
    """Startkonfiguration für eine frische Installation."""
    return {
        "version": AKTUELLE_VERSION,
        "anlage": {
            "name": "CamGrid",
        },
        "anzeige": {
            # Sprache der Anzeigeseite auf den Monitoren ("de" oder "en").
            "sprache": "de",
            "aufloesung": "1920x1080",   # je Monitor, xrandr-Schreibweise
            "bildrate": 60,
            "rand": True,                # Rahmen um jede Kachel
            "beschriftung": True,        # Kameraname einblenden
            "abstand": 14,               # Abstand zwischen den Kacheln in Pixeln
            "hintergrund": "#0e1116",
        },
        "monitore": [
            {
                "id": 1,
                "name": "Monitor 1",
                "ausgang": "",           # leer = automatisch (Reihenfolge aus xrandr)
                "spalten": 2,
                "zeilen": 2,
                "kacheln": [],
            }
        ],
        "kameras": [],
        "zugang": {
            "admin_benutzer": STANDARD_BENUTZER,
            # Feste Vorgabe, damit die Anleitung überall stimmt. Das Dashboard
            # weist so lange auf das Ändern hin, wie sie unverändert ist.
            "admin_passwort": STANDARD_PASSWORT,
            # Zugang für die Anzeigeseite von außen; leer = nur lokal ohne Login
            "anzeige_benutzer": "anzeige",
            "anzeige_passwort": STANDARD_PASSWORT,
        },
        "scan": {
            "netz": "",
            "zugangsdaten": [{"benutzer": "admin", "passwort": ""}],
        },
        "dienste": {
            "go2rtc_port": 1984,
            "admin_port": 8080,
        },
    }


def standard_kamera(ip: str = "", name: str = "") -> dict:
    return {
        "id": neue_id("k"),
        "name": name or "Neue Kamera",
        "ip": ip,
        "benutzer": "",
        "passwort": "",
        "pfad": "stream2",       # RTSP-Pfad hinter der IP
        # Manche Kameras können kein RTSP (z. B. klassische Mobotix) und
        # liefern stattdessen MJPEG über HTTP. Dann steht hier die vollständige
        # Adresse, und "art" sagt der Anzeigeseite, wie sie abspielen muss.
        "quelle": "",
        "art": "rtsp",           # "rtsp" oder "mjpeg"
        "breite": 0,             # 0 = unbekannt, wird beim Prüfen gefüllt
        "hoehe": 0,
        "aktiv": True,
        "notiz": "",
    }


def neue_id(praefix: str) -> str:
    return f"{praefix}{secrets.token_hex(4)}"


# --------------------------------------------------------------------------
# Laden und Speichern
# --------------------------------------------------------------------------

def laden(pfad: Path | str = STANDARD_PFAD) -> dict:
    """Liest die Konfiguration. Fehlt die Datei, kommt die Standardvorgabe."""
    pfad = Path(pfad)
    with _sperre:
        if not pfad.exists():
            return standard_konfiguration()
        text = pfad.read_text(encoding="utf-8")
        try:
            daten = json.loads(text)
        except json.JSONDecodeError as fehler:
            raise ValueError(
                f"{pfad} ist keine gültige JSON-Datei (Zeile {fehler.lineno}): {fehler.msg}"
            ) from fehler
        return aufbereiten(daten)


def speichern(daten: dict, pfad: Path | str = STANDARD_PFAD) -> dict:
    """Schreibt die Konfiguration unteilbar (erst temporär, dann umbenennen)."""
    pfad = Path(pfad)
    daten = aufbereiten(daten)
    with _sperre:
        pfad.parent.mkdir(parents=True, exist_ok=True)
        temp = None
        try:
            with tempfile.NamedTemporaryFile(
                "w", encoding="utf-8", dir=pfad.parent, delete=False, suffix=".tmp"
            ) as datei:
                temp = Path(datei.name)
                json.dump(daten, datei, indent=2, ensure_ascii=False)
                datei.write("\n")
                datei.flush()
                os.fsync(datei.fileno())
            # Rechte der bestehenden Datei behalten, sonst 600 (enthält Passwörter).
            try:
                temp.chmod(pfad.stat().st_mode & 0o777 if pfad.exists() else 0o600)
            except OSError:
                pass
            temp.replace(pfad)
            temp = None
        finally:
            # Bleibt bei einem Fehler (Platte voll, Rechte) kein halb
            # geschriebener Rest liegen.
            if temp is not None:
                try:
                    temp.unlink()
                except OSError:
                    pass
    return daten


# --------------------------------------------------------------------------
# Prüfen und Ergänzen
# --------------------------------------------------------------------------

def aufbereiten(daten: dict) -> dict:
    """Ergänzt fehlende Felder, wirft bei echten Fehlern eine Ausnahme.

    Damit eine von Hand bearbeitete Datei nie den Dienst blockiert, werden
    unbekannte oder fehlende Werte durch Vorgaben ersetzt statt abzulehnen.
    """
    if not isinstance(daten, dict):
        raise ValueError("Die Konfiguration muss ein JSON-Objekt sein.")

    daten = _migrieren(daten)
    vorgabe = standard_konfiguration()

    for bereich in ("anlage", "anzeige", "zugang", "scan", "dienste"):
        werte = daten.get(bereich)
        daten[bereich] = {**vorgabe[bereich], **(werte if isinstance(werte, dict) else {})}

    sprache = str(daten["anzeige"].get("sprache", "de")).lower()
    daten["anzeige"]["sprache"] = sprache if sprache in ("de", "en") else "de"

    daten["version"] = AKTUELLE_VERSION
    _anlage_aufbereiten(daten["anlage"], vorgabe["anlage"])
    _anzeige_aufbereiten(daten["anzeige"], vorgabe["anzeige"])
    _zugang_aufbereiten(daten["zugang"])
    _scan_aufbereiten(daten["scan"])
    _dienste_aufbereiten(daten["dienste"], vorgabe["dienste"])

    kameras = [k for k in _liste(daten.get("kameras")) if isinstance(k, dict)]
    daten["kameras"] = [_kamera_aufbereiten(k) for k in kameras[:MAX_KAMERAS]]
    _ids_eindeutig_machen(daten["kameras"], "k")

    monitore = [m for m in _liste(daten.get("monitore")) if isinstance(m, dict)]
    daten["monitore"] = [
        _monitor_aufbereiten(m, nummer)
        for nummer, m in enumerate(monitore[:MAX_MONITORE], start=1)
    ]
    if not daten["monitore"]:
        daten["monitore"] = vorgabe["monitore"]
    _monitor_ids_eindeutig_machen(daten["monitore"])

    _kacheln_bereinigen(daten)
    return daten


def _liste(wert) -> list:
    """Nur echte Listen gelten als Liste - eine Zeichenkette ist keine."""
    return wert if isinstance(wert, list) else []


def _text(wert, laenge: int = MAX_TEXT, strippen: bool = True) -> str:
    """Macht aus beliebiger Eingabe einen kurzen, harmlosen Text.

    Steuerzeichen (auch Zeilenumbrüche) fallen weg, die Länge wird begrenzt.
    Ohne das könnte ein langer oder mehrzeiliger Wert die erzeugten Dateien
    zerreißen oder die Konfiguration unbegrenzt wachsen lassen.
    """
    if isinstance(wert, bool) or wert is None:
        return ""
    if not isinstance(wert, str):
        wert = str(wert)
    saubere = _STEUERZEICHEN.sub("", wert)[:laenge]
    return saubere.strip() if strippen else saubere


def _geheimnis(wert) -> str:
    """Benutzername oder Passwort: wie _text, aber ohne Abschneiden von
    Leerzeichen am Rand - die können Teil des Passworts sein."""
    return _text(wert, MAX_TEXT, strippen=False)


def _anlage_aufbereiten(anlage: dict, vorgabe: dict) -> None:
    anlage["name"] = _text(anlage.get("name")) or vorgabe["name"]


def _anzeige_aufbereiten(anzeige: dict, vorgabe: dict) -> None:
    aufloesung = _text(anzeige.get("aufloesung"), 16).replace(" ", "")
    anzeige["aufloesung"] = (
        aufloesung if _AUFLOESUNG_MUSTER.match(aufloesung) else vorgabe["aufloesung"]
    )
    anzeige["bildrate"] = _begrenzen(anzeige.get("bildrate", 60), 1, 240)
    anzeige["abstand"] = _begrenzen(anzeige.get("abstand", 14), 0, 200)
    anzeige["rand"] = bool(anzeige.get("rand", True))
    anzeige["beschriftung"] = bool(anzeige.get("beschriftung", True))
    # Die Farbe landet unverändert im Stilblatt der Anzeigeseite; nur ein
    # echter Farbwert darf durch.
    farbe = _text(anzeige.get("hintergrund"), 24).replace(" ", "")
    anzeige["hintergrund"] = farbe if _FARBE_MUSTER.match(farbe) else vorgabe["hintergrund"]


def _zugang_aufbereiten(zugang: dict) -> None:
    for schluessel in ("admin_benutzer", "admin_passwort",
                       "anzeige_benutzer", "anzeige_passwort"):
        zugang[schluessel] = _geheimnis(zugang.get(schluessel))


def _scan_aufbereiten(bereich: dict) -> None:
    bereich["netz"] = _text(bereich.get("netz"), 64).replace(" ", "")
    zugangsdaten = []
    for satz in _liste(bereich.get("zugangsdaten"))[:32]:
        if not isinstance(satz, dict):
            continue
        zugangsdaten.append({"benutzer": _geheimnis(satz.get("benutzer")),
                             "passwort": _geheimnis(satz.get("passwort"))})
    bereich["zugangsdaten"] = zugangsdaten or [{"benutzer": "admin", "passwort": ""}]


def _dienste_aufbereiten(dienste: dict, vorgabe: dict) -> None:
    # Ohne diese Prüfung reicht ein Port "abc" in der Datei, und jeder
    # spätere int()-Aufruf im Server wirft eine Ausnahme.
    for schluessel in ("go2rtc_port", "admin_port"):
        dienste[schluessel] = _begrenzen(dienste.get(schluessel, vorgabe[schluessel]),
                                         1, 65535, vorgabe[schluessel])


def _ids_eindeutig_machen(kameras: list[dict], praefix: str) -> None:
    """Zwei Kameras mit derselben ID würden sich in go2rtc gegenseitig
    überschreiben und beim Löschen beide verschwinden."""
    gesehen: set[str] = set()
    for kamera in kameras:
        while kamera["id"] in gesehen:
            kamera["id"] = neue_id(praefix)
        gesehen.add(kamera["id"])


def _monitor_ids_eindeutig_machen(monitore: list[dict]) -> None:
    gesehen: set[int] = set()
    naechste = 1
    for monitor in monitore:
        if monitor["id"] in gesehen or monitor["id"] < 1:
            while naechste in gesehen:
                naechste += 1
            monitor["id"] = naechste
        gesehen.add(monitor["id"])


def _migrieren(daten: dict) -> dict:
    """Hebt ältere Dateiversionen auf den aktuellen Stand."""
    version = daten.get("version", 0)
    if version > AKTUELLE_VERSION:
        raise ValueError(
            f"Die Konfiguration stammt aus einer neueren Version ({version}). "
            "Bitte die Software aktualisieren."
        )
    # Version 0 -> 1: es gab noch keine veröffentlichte Vorversion, nichts zu tun.
    return daten


def _kamera_aufbereiten(kamera: dict) -> dict:
    vorgabe = standard_kamera()
    ergebnis = {**vorgabe, **kamera}
    # Die ID wird zum Stream-Namen in go2rtc und steht damit in einer
    # YAML-Zeile und in einer Adresse: nur Buchstaben, Zahlen, _ und -.
    ergebnis["id"] = _ID_VERBOTEN.sub("", _text(ergebnis.get("id"), 64)) or neue_id("k")
    ergebnis["name"] = _text(ergebnis.get("name")) or "Kamera"
    ergebnis["ip"] = _adresse_pruefen(ergebnis.get("ip"))
    ergebnis["pfad"] = _pfad_pruefen(ergebnis.get("pfad"))
    ergebnis["benutzer"] = _geheimnis(ergebnis.get("benutzer"))
    ergebnis["passwort"] = _geheimnis(ergebnis.get("passwort"))
    ergebnis["quelle"] = _quelle_pruefen(ergebnis.get("quelle"))
    ergebnis["art"] = "mjpeg" if str(ergebnis.get("art", "")).lower() == "mjpeg" else "rtsp"
    ergebnis["notiz"] = _text(ergebnis.get("notiz"), 500)
    ergebnis["aktiv"] = bool(ergebnis.get("aktiv", True))
    for zahl in ("breite", "hoehe"):
        ergebnis[zahl] = _begrenzen(ergebnis.get(zahl) or 0, 0, MAX_PIXEL, 0)
    return ergebnis


def _adresse_pruefen(wert) -> str:
    """IP oder Hostname der Kamera - oder leer, wenn unbrauchbar.

    Leer heißt "noch nicht eingerichtet": die Kamera bleibt als Platzhalter
    stehen und kommt nicht in die go2rtc.yaml. Alles andere wäre gefährlich,
    denn dieser Wert wird Teil einer RTSP-Adresse.
    """
    text = _text(wert, 253).replace(" ", "")
    return text if _IP_MUSTER.match(text) else ""


# Zeichen, die in einer Stream-Adresse nichts zu suchen haben.
_UNERWUENSCHT = (chr(13), chr(10), chr(9), " ")


def _quelle_pruefen(wert) -> str:
    """Vollständige Stream-Adresse, falls die Kamera kein RTSP kann.

    Erlaubt sind nur rtsp://, http:// und https://. Alles andere wird
    verworfen: der Wert landet in der go2rtc-Konfiguration, dort hat weder
    eine Datei-Adresse noch ein Befehl etwas zu suchen.
    """
    text = _text(wert, 400).strip()
    if not text:
        return ""
    if any(zeichen in text for zeichen in _UNERWUENSCHT):
        return ""
    if not text.startswith(("rtsp://", "http://", "https://")):
        return ""
    return text


def _pfad_pruefen(wert) -> str:
    """RTSP-Pfad hinter der IP, auf unbedenkliche Zeichen beschränkt."""
    text = _text(wert, MAX_TEXT)
    return _PFAD_VERBOTEN.sub("", text).lstrip("/")


def _ausgang_pruefen(wert) -> str:
    """Name eines Bildschirmausgangs (HDMI-1, DP-2) - oder leer.

    Leer heißt "automatisch vergeben"; kiosk.sh nimmt dann den nächsten
    tatsächlich angeschlossenen Ausgang.
    """
    text = _text(wert, 32).replace(" ", "")
    return text if _AUSGANG_MUSTER.match(text) else ""


def _monitor_aufbereiten(monitor: dict, nummer: int) -> dict:
    ergebnis = {
        "id": _begrenzen(monitor.get("id") or nummer, 1, 999, nummer),
        "name": _text(monitor.get("name")) or f"Monitor {nummer}",
        # Der Ausgang geht als Variable an xrandr in kiosk.sh.
        "ausgang": _ausgang_pruefen(monitor.get("ausgang")),
        "spalten": _begrenzen(monitor.get("spalten", 2), 1, 6),
        "zeilen": _begrenzen(monitor.get("zeilen", 2), 1, 6),
        "kacheln": [],
    }

    for kachel in _liste(monitor.get("kacheln"))[:36]:
        if not isinstance(kachel, dict):
            continue
        kamera_id = _ID_VERBOTEN.sub("", _text(kachel.get("kamera_id"), 64))
        ergebnis["kacheln"].append(
            {
                "kamera_id": kamera_id or None,
                "platz": _begrenzen(kachel.get("platz", 1), 1, 36),
                "breite": _begrenzen(kachel.get("breite", 1), 1, 6),
                "hoehe": _begrenzen(kachel.get("hoehe", 1), 1, 6),
                "name": _text(kachel.get("name")),  # leer = Name der Kamera
            }
        )
    return ergebnis


def _kacheln_bereinigen(daten: dict) -> None:
    """Sorgt dafür, dass jede Kachel auf eine vorhandene Kamera und einen
    gültigen Platz im Raster zeigt."""
    bekannte = {k["id"] for k in daten["kameras"]}
    for monitor in daten["monitore"]:
        plaetze = monitor["spalten"] * monitor["zeilen"]
        belegt: set[int] = set()
        sauber = []
        for kachel in monitor["kacheln"]:
            if kachel["kamera_id"] and kachel["kamera_id"] not in bekannte:
                kachel["kamera_id"] = None      # Kamera gelöscht -> Platzhalter
            if kachel["platz"] > plaetze or kachel["platz"] in belegt:
                continue                        # passt nicht mehr ins Raster
            belegt.add(kachel["platz"])
            sauber.append(kachel)
        monitor["kacheln"] = sorted(sauber, key=lambda k: k["platz"])


def _begrenzen(wert, kleinster: int, groesster: int, vorgabe: int | None = None) -> int:
    """Macht aus beliebiger Eingabe eine Zahl im erlaubten Bereich.

    Unbrauchbare Eingaben (Text, None, riesige Fließkommazahlen) ergeben
    `vorgabe`, sonst den kleinsten erlaubten Wert.
    """
    try:
        zahl = int(wert)
    except (TypeError, ValueError, OverflowError):
        zahl = kleinster if vorgabe is None else vorgabe
    return max(kleinster, min(groesster, zahl))


# --------------------------------------------------------------------------
# Hilfen für andere Module
# --------------------------------------------------------------------------

def kamera_suchen(daten: dict, kamera_id: str) -> dict | None:
    for kamera in _liste(daten.get("kameras")):
        if isinstance(kamera, dict) and kamera.get("id") == kamera_id:
            return kamera
    return None


def monitor_suchen(daten: dict, monitor_id: int) -> dict | None:
    gesucht = _begrenzen(monitor_id, 0, 999, 0)
    for monitor in _liste(daten.get("monitore")):
        if isinstance(monitor, dict) and _begrenzen(monitor.get("id"), 0, 999, 0) == gesucht:
            return monitor
    return None


def stream_name(kamera: dict) -> str:
    """Name des Streams in go2rtc. Bewusst die Kamera-ID, damit ein
    Umbenennen oder ein IP-Wechsel den Stream nicht zerreißt.

    Die ID wird hier noch einmal auf unbedenkliche Zeichen beschränkt: sie
    wird zum Schlüssel einer YAML-Zeile, und ein Doppelpunkt oder ein
    Zeilenumbruch darin würde die erzeugte Datei zerreißen.
    """
    return _ID_VERBOTEN.sub("", _text(kamera.get("id"), 64))


def rtsp_adresse(kamera: dict) -> str:
    """Vollständige RTSP-Adresse einer Kamera, Zugangsdaten prozent-kodiert.

    IP und Pfad werden hier noch einmal geprüft, damit auch eine von Hand
    verbogene Konfiguration keine zweite Adresse und keine weitere YAML-Zeile
    in die erzeugten Dateien schmuggeln kann. Passt etwas nicht, kommt eine
    leere Adresse zurück - die Kamera bleibt dann Platzhalter.
    """
    from urllib.parse import quote

    # Eigene Adresse hat Vorrang - damit laufen auch Kameras ohne RTSP.
    eigene = _quelle_pruefen(kamera.get("quelle"))
    if eigene:
        return eigene

    ip = _adresse_pruefen(kamera.get("ip"))
    if not ip:
        return ""
    zugang = ""
    if kamera.get("benutzer"):
        zugang = quote(_geheimnis(kamera["benutzer"]), safe="")
        if kamera.get("passwort"):
            zugang += ":" + quote(_geheimnis(kamera["passwort"]), safe="")
        zugang += "@"
    pfad = _pfad_pruefen(kamera.get("pfad"))
    return f"rtsp://{zugang}{ip}:554/{pfad}"


def ohne_geheimnisse(daten: dict) -> dict:
    """Kopie der Konfiguration, in der Passwörter durch Platzhalter ersetzt
    sind - für die Anzeigeseite, die jeder im Netz abrufen kann."""
    kopie = json.loads(json.dumps(daten))
    kopie.pop("zugang", None)
    kopie.pop("scan", None)
    for kamera in kopie.get("kameras", []):
        # Zugangsdaten und die IP haben auf der offenen Anzeigeseite nichts zu suchen.
        # Statt der IP nur die Auskunft, ob die Kamera überhaupt eingerichtet ist.
        kamera["eingerichtet"] = bool(kamera.get("ip") or kamera.get("quelle"))
        # "quelle" kann Benutzer und Passwort enthalten - die Anzeigeseite
        # braucht nur die Art (rtsp oder mjpeg), um richtig abzuspielen.
        for geheim in ("passwort", "benutzer", "ip", "notiz", "quelle"):
            kamera.pop(geheim, None)
    return kopie
