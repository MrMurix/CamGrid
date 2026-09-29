"""Holt ein Einzelbild (JPEG) von einer Kamera - für die Vorschau im Dashboard.

Drei Wege, in dieser Reihenfolge:
  1. Die Schnappschuss-Adresse der Kamera über HTTP (Basic oder Digest).
     Das ist der schnellste Weg und braucht keine Fremdprogramme.
  2. ffmpeg, falls vorhanden (auf dem Pi ist es installiert).
  3. Aufgeben - der Aufrufer zeigt dann einen Platzhalter.

Die gefundene Adresse wird je Kamera gemerkt, damit die Vorschau beim zweiten
Mal sofort kommt und nicht wieder alle Adressen durchprobiert werden.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

# Übliche Schnappschuss-Adressen verschiedener Hersteller, in der
# Reihenfolge, in der sie durchprobiert werden. Vorn stehen die Adressen der
# Mobotix-MOVE-Reihe, für die dieses Projekt zuerst gebaut wurde.
ADRESSEN = [
    "/cgi-bin/snapshot.cgi",
    "/cgi-bin/viewer/video.jpg",
    "/cgi-bin/faststream.jpg?stream=full&fps=0&noaudio",
    "/axis-cgi/jpg/image.cgi",
    "/ISAPI/Streaming/channels/101/picture",
    "/cgi-bin/api.cgi?cmd=Snap&channel=0",
    "/onvif-http/snapshot",
    "/snapshot.jpg",
    "/jpg/image.jpg",
    "/image/jpeg.cgi",
    "/tmpfs/auto.jpg",
    "/record/current.jpg",
]

JPEG_KENNUNG = b"\xff\xd8\xff"

_gemerkt: dict[str, str] = {}       # "ip" -> Adresse, die funktioniert hat
_sperre = threading.Lock()


# --------------------------------------------------------------------------
# Öffentlich
# --------------------------------------------------------------------------

def bild_pruefen(daten: bytes | None) -> bool:
    """Sind das wirklich JPEG-Daten?"""
    return bool(daten) and daten[:3] == JPEG_KENNUNG and len(daten) > 1000


def bild_holen(ip: str, benutzer: str = "", passwort: str = "", pfad: str = "",
               timeout: float = 8.0, gesamt: float = 0.0) -> tuple[bytes | None, str | None]:
    """Liefert (JPEG-Daten, Quelle) oder (None, Grund).

    `timeout` gilt je Versuch, `gesamt` für alle Versuche zusammen (0 heißt:
    das Dreifache von `timeout`). Ohne diese Gesamtgrenze könnte ein Gerät,
    das auf jeder der Adressen in die Zeitgrenze läuft, die Anfrage minutenlang
    hinhalten - und damit einen Thread des Dashboards blockieren.
    """
    if not ip:
        return None, "keine IP-Adresse"
    einzel = max(0.5, float(timeout))
    ende = time.monotonic() + (float(gesamt) if gesamt > 0 else einzel * 3)

    with _sperre:
        bevorzugt = _gemerkt.get(ip)

    # Die zuletzt erfolgreiche Adresse zuerst: dann ist die Vorschau beim
    # zweiten Mal nach einem Versuch da.
    adressen = ADRESSEN if not bevorzugt else [bevorzugt] + [a for a in ADRESSEN if a != bevorzugt]

    versucht = 0
    for adresse in adressen:
        for schema in ("http", "https"):
            rest = ende - time.monotonic()
            if rest <= 0.5:
                break
            versucht += 1
            daten = _http_bild(f"{schema}://{ip}{adresse}", benutzer, passwort,
                               min(einzel, rest))
            if bild_pruefen(daten):
                with _sperre:
                    _gemerkt[ip] = adresse
                return daten, f"{schema}:{adresse}"
        else:
            continue
        break                           # Zeitgrenze erreicht, nicht weitersuchen

    # ffmpeg braucht eine eigene Zeitspanne; die Gesamtgrenze gilt nur für die
    # HTTP-Versuche, sonst käme dieser Weg bei einer stummen Kamera nie dran.
    daten = _ffmpeg_bild(ip, benutzer, passwort, pfad, einzel)
    if bild_pruefen(daten):
        return daten, "ffmpeg"

    grund = "Kamera liefert kein Einzelbild über HTTP"
    if versucht < len(adressen):
        grund += f" (Zeitgrenze nach {versucht} von {2 * len(adressen)} Adressen)"
    if not shutil.which("ffmpeg"):
        grund += " und ffmpeg ist nicht installiert"
    return None, grund


# --------------------------------------------------------------------------
# Weg 1: HTTP mit Basic- oder Digest-Anmeldung
# --------------------------------------------------------------------------

def _http_bild(adresse: str, benutzer: str, passwort: str, timeout: float) -> bytes | None:
    kontext = ssl._create_unverified_context() if adresse.startswith("https") else None

    antwort = _anfragen(adresse, timeout, kontext)
    if antwort is None:
        return None
    status, kopf, inhalt = antwort

    if status == 401 and benutzer:
        herausforderung = kopf.get("WWW-Authenticate", "")
        kopfzeile = _anmeldung_bauen(herausforderung, adresse, benutzer, passwort)
        if not kopfzeile:
            return None
        antwort = _anfragen(adresse, timeout, kontext, kopfzeile)
        if antwort is None:
            return None
        status, kopf, inhalt = antwort

    if status != 200:
        return None
    typ = (kopf.get("Content-Type") or "").lower()
    if "image" not in typ and "multipart" not in typ and not bild_pruefen(inhalt):
        return None
    if "multipart" in typ:
        return _erstes_bild_aus_strom(inhalt)
    return inhalt


def _anfragen(adresse: str, timeout: float, kontext, anmeldung: str | None = None):
    """Eine HTTP-Anfrage ohne Umleitungsmagie. Gibt (Status, Kopf, Inhalt) zurück."""
    anfrage = urllib.request.Request(adresse)
    anfrage.add_header("User-Agent", "CamGrid")
    if anmeldung:
        anfrage.add_header("Authorization", anmeldung)
    try:
        with urllib.request.urlopen(anfrage, timeout=timeout, context=kontext) as antwort:
            return antwort.status, dict(antwort.headers), antwort.read(4_000_000)
    except urllib.error.HTTPError as fehler:
        return fehler.code, dict(fehler.headers), b""
    except (OSError, ValueError, ssl.SSLError):
        return None


def _anmeldung_bauen(herausforderung: str, adresse: str, benutzer: str, passwort: str) -> str | None:
    """Baut die Authorization-Kopfzeile passend zur Aufforderung der Kamera."""
    if herausforderung.lower().startswith("basic"):
        import base64
        schluessel = base64.b64encode(f"{benutzer}:{passwort}".encode()).decode()
        return f"Basic {schluessel}"
    if not herausforderung.lower().startswith("digest"):
        return None

    felder = _digest_felder(herausforderung)
    bereich = felder.get("realm", "")
    nonce = felder.get("nonce", "")
    qop = felder.get("qop", "")
    opaque = felder.get("opaque")
    algorithmus = (felder.get("algorithm") or "MD5").upper()
    if not nonce:
        return None

    teile = urllib.parse.urlsplit(adresse)
    uri = teile.path + (f"?{teile.query}" if teile.query else "")

    def md5(text: str) -> str:
        return hashlib.md5(text.encode("utf-8")).hexdigest()   # noqa: S324 - RFC 2617

    ha1 = md5(f"{benutzer}:{bereich}:{passwort}")
    ha2 = md5(f"GET:{uri}")

    if "auth" in qop:
        cnonce = os.urandom(8).hex()
        nc = "00000001"
        antwort = md5(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}")
        kopf = (f'Digest username="{benutzer}", realm="{bereich}", nonce="{nonce}", uri="{uri}", '
                f'qop=auth, nc={nc}, cnonce="{cnonce}", response="{antwort}", algorithm={algorithmus}')
    else:
        antwort = md5(f"{ha1}:{nonce}:{ha2}")
        kopf = (f'Digest username="{benutzer}", realm="{bereich}", nonce="{nonce}", uri="{uri}", '
                f'response="{antwort}", algorithm={algorithmus}')
    if opaque:
        kopf += f', opaque="{opaque}"'
    return kopf


def _digest_felder(herausforderung: str) -> dict:
    """Zerlegt `Digest realm="x", nonce="y", ...` in ein Wörterbuch."""
    felder = {}
    rest = herausforderung[len("Digest"):].strip()
    for teil in _aufteilen(rest):
        if "=" not in teil:
            continue
        name, _, wert = teil.partition("=")
        felder[name.strip().lower()] = wert.strip().strip('"')
    return felder


def _aufteilen(text: str) -> list[str]:
    """Trennt an Kommas, aber nicht innerhalb von Anführungszeichen."""
    teile, gepuffert, in_zitat = [], "", False
    for zeichen in text:
        if zeichen == '"':
            in_zitat = not in_zitat
        if zeichen == "," and not in_zitat:
            teile.append(gepuffert)
            gepuffert = ""
        else:
            gepuffert += zeichen
    if gepuffert.strip():
        teile.append(gepuffert)
    return teile


def _erstes_bild_aus_strom(daten: bytes) -> bytes | None:
    """Schneidet aus einem MJPEG-Strom das erste vollständige Bild heraus."""
    anfang = daten.find(JPEG_KENNUNG)
    if anfang < 0:
        return None
    ende = daten.find(b"\xff\xd9", anfang)
    return daten[anfang:ende + 2] if ende > 0 else None


# --------------------------------------------------------------------------
# Weg 2: ffmpeg
# --------------------------------------------------------------------------

def _ffmpeg_bild(ip: str, benutzer: str, passwort: str, pfad: str, timeout: float) -> bytes | None:
    programm = shutil.which("ffmpeg")
    if not programm:
        return None

    zugang = ""
    if benutzer:
        zugang = urllib.parse.quote(benutzer, safe="")
        if passwort:
            zugang += ":" + urllib.parse.quote(passwort, safe="")
        zugang += "@"
    adresse = f"rtsp://{zugang}{ip}:554/{pfad.lstrip('/')}"

    ziel = None
    try:
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as datei:
            ziel = datei.name
        subprocess.run(
            [programm, "-v", "error", "-y", "-rtsp_transport", "tcp", "-i", adresse,
             "-frames:v", "1", ziel],
            capture_output=True, timeout=timeout, check=False,
        )
        with open(ziel, "rb") as datei:
            return datei.read()
    except (OSError, subprocess.SubprocessError):
        return None
    finally:
        if ziel and os.path.exists(ziel):
            try:
                os.unlink(ziel)
            except OSError:
                pass


# --------------------------------------------------------------------------
# Kameras ohne RTSP: MJPEG über HTTP
# --------------------------------------------------------------------------

# Adressen, unter denen Kameras einen fortlaufenden MJPEG-Strom liefern.
# Die erste stammt von den klassischen Mobotix-Modellen, die kein RTSP können.
STROM_ADRESSEN = [
    "/cgi-bin/faststream.jpg?stream=full&fps=10&noaudio",
    "/control/faststream.jpg?stream=MxPEG&fps=10",
    "/mjpg/video.mjpg",
    "/cgi-bin/mjpg/video.cgi",
    "/video.mjpg",
    "/videostream.cgi",
    "/cgi-bin/viewer/video.jpg?resolution=640x480",
    "/axis-cgi/mjpg/video.cgi",
]


def _kleine_schluessel(kopfzeilen) -> dict:
    """Kopfzeilen mit kleingeschriebenen Namen - Kameras mischen die
    Schreibweise („Content-type", „CONTENT-TYPE"), Vergleiche werden sonst
    unzuverlässig."""
    return {str(name).lower(): wert for name, wert in kopfzeilen.items()}


def _kopf_holen(adresse: str, timeout: float, kontext, anmeldung: str | None = None):
    """Holt nur Status und Kopfzeilen - und liest den Inhalt bewusst nicht.

    Ein MJPEG-Strom hört nie auf: würde man ihn wie ein Bild lesen, liefe die
    Anfrage bis zur Zeitgrenze. Für die Erkennung reicht der Content-Type.
    """
    anfrage = urllib.request.Request(adresse)
    anfrage.add_header("User-Agent", "CamGrid")
    if anmeldung:
        anfrage.add_header("Authorization", anmeldung)
    antwort = None
    try:
        antwort = urllib.request.urlopen(anfrage, timeout=timeout, context=kontext)
        return antwort.status, _kleine_schluessel(antwort.headers)
    except urllib.error.HTTPError as fehler:
        return fehler.code, _kleine_schluessel(fehler.headers)
    except (OSError, ValueError, ssl.SSLError):
        return None
    finally:
        if antwort is not None:
            antwort.close()


def mjpeg_suchen(ip: str, benutzer: str = "", passwort: str = "",
                 timeout: float = 6.0) -> dict | None:
    """Sucht einen MJPEG-Strom über HTTP.

    Gedacht für Kameras, die kein RTSP anbieten. Zurück kommt die vollständige
    Adresse samt Zugangsdaten - so, wie der Streaming-Dienst sie braucht -
    oder None.
    """
    from urllib.parse import quote

    for adresse in STROM_ADRESSEN:
        for schema in ("http", "https"):
            voll = f"{schema}://{ip}{adresse}"
            kontext = ssl._create_unverified_context() if schema == "https" else None
            antwort = _kopf_holen(voll, timeout, kontext)
            if antwort is None:
                continue
            status, kopf = antwort
            if status == 401 and benutzer:
                kopfzeile = _anmeldung_bauen(kopf.get("www-authenticate", ""), voll,
                                             benutzer, passwort)
                if not kopfzeile:
                    continue
                antwort = _kopf_holen(voll, timeout, kontext, kopfzeile)
                if antwort is None:
                    continue
                status, kopf = antwort
            typ = (kopf.get("content-type") or "").lower()
            if status != 200 or "multipart" not in typ:
                continue

            # Zugangsdaten gehören in die Adresse, damit go2rtc sie mitschickt.
            zugang = ""
            if benutzer:
                zugang = quote(benutzer, safe="")
                if passwort:
                    zugang += ":" + quote(passwort, safe="")
                zugang += "@"
            return {"quelle": f"{schema}://{zugang}{ip}{adresse}", "art": "mjpeg",
                    "pfad": adresse}
    return None


if __name__ == "__main__":
    import sys

    ip = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.2"
    benutzer = sys.argv[2] if len(sys.argv) > 2 else ""
    passwort = sys.argv[3] if len(sys.argv) > 3 else ""
    daten, quelle = bild_holen(ip, benutzer, passwort, "stream2")
    if daten:
        print(f"{ip}: {len(daten)} Bytes über {quelle}")
    else:
        print(f"{ip}: kein Bild ({quelle})")
