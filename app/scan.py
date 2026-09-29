"""Kamerasuche im Netz: ONVIF-Discovery, Portscan, RTSP-Prüfung.

Zwei Wege führen zu einer Kamera:

* ONVIF-WS-Discovery per UDP-Multicast - schnell, findet aber nur Geräte,
  die auch antworten wollen.
* Gezieltes Abklopfen eines IP-Bereichs - langsamer, findet auch stille
  Kameras und liefert gleich die passenden RTSP-Pfade mit.

Es wird ausschließlich die Standardbibliothek benutzt. Die externen
Programme `ffprobe` und `ffmpeg` werden verwendet, wenn sie im PATH liegen,
sind aber optional: fehlen sie, liefern die Funktionen weiterhin ein
brauchbares Ergebnis (Feld "stream" ist dann None) und werfen keine
Ausnahme.

Alle Funktionen arbeiten ohne gemeinsamen Zustand und dürfen aus mehreren
Threads gleichzeitig aufgerufen werden - etwa aus einem Arbeits-Thread des
Admin-Webservers.
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# --------------------------------------------------------------------------
# Konstanten (außer diesen hält das Modul keinen Zustand)
# --------------------------------------------------------------------------

# Ziel der WS-Discovery-Anfrage (festgelegt in der ONVIF-Spezifikation).
ONVIF_ADRESSE = "239.255.255.250"
ONVIF_PORT = 3702

# Diese Ports werden je Host geprüft, in dieser Reihenfolge.
PRUEF_PORTS = (554, 80, 443)
RTSP_PORT = 554

# Sicherheitsbremse: größere Bereiche lehnt netz_hosts() ab, damit ein
# Tippfehler wie "10.0.0.0/8" nicht den ganzen Pi blockiert.
MAX_HOSTS = 65536

# RTSP-Pfade in der Reihenfolge, in der sie durchprobiert werden. Vorn
# stehen die Pfade der Kameras, für die dieses Projekt zuerst gebaut wurde
# (Mobotix: stream1/stream2).
STANDARD_PFADE = (
    "stream1",
    "stream2",
    "live.sdp",
    "live2.sdp",
    "h264",
    "video1",
    "profile1/media.smp",
    "cam/realmonitor?channel=1&subtype=0",
    "cam/realmonitor?channel=1&subtype=1",
    "Streaming/Channels/101",
    "Streaming/Channels/102",
    "11",
    "12",
    "axis-media/media.amp",
    "onvif1",
    "MediaInput/h264",
    "live/ch0",
    "videoMain",
    "media/video1",
    "",                       # leerer Pfad: manche Kameras liefern so
)

# Zusammengehörende Haupt-/Nebenstrom-Paare. Ist ein Pfad gefunden, werden
# seine Partner ebenfalls geprüft, damit beide Auflösungen bekannt sind und
# der Nutzer später zwischen groß und klein wählen kann.
NEBENSTROM_PAARE = {
    "stream1": ("stream2",),
    "stream2": ("stream1",),
    "live.sdp": ("live2.sdp",),
    "live2.sdp": ("live.sdp",),
    "h264": ("h264_2",),
    "video1": ("video2",),
    "videoMain": ("videoSub",),
    "media/video1": ("media/video2",),
    "live/ch0": ("live/ch1",),
    "profile1/media.smp": ("profile2/media.smp",),
    "cam/realmonitor?channel=1&subtype=0": ("cam/realmonitor?channel=1&subtype=1",),
    "cam/realmonitor?channel=1&subtype=1": ("cam/realmonitor?channel=1&subtype=0",),
    "Streaming/Channels/101": ("Streaming/Channels/102",),
    "Streaming/Channels/102": ("Streaming/Channels/101",),
    "11": ("12",),
    "12": ("11",),
}

# Kleine eingebaute OUI-Tabelle: MAC-Präfix -> Hersteller. Bewusst knapp
# gehalten, es geht nur um einen Hinweis für den Nutzer.
OUI_HERSTELLER = {
    "00:03:c5": "Mobotix",
    "00:40:8c": "Axis",
    "ac:cc:8e": "Axis",
    "b8:a4:4f": "Axis",
    "00:0f:7c": "Axis",
    "44:19:b6": "Hikvision",
    "4c:bd:8f": "Hikvision",
    "c0:56:e3": "Hikvision",
    "bc:ad:28": "Hikvision",
    "28:57:be": "Hikvision",
    "3c:ef:8c": "Dahua",
    "90:02:a9": "Dahua",
    "4c:11:bf": "Dahua",
    "08:ed:ed": "Dahua",
    "e0:50:8b": "Dahua",
    "00:07:5f": "Bosch",
    "00:1b:86": "Bosch",
    "00:04:63": "Bosch",
    "00:02:d1": "Vivotek",
    "00:16:6c": "Hanwha/Samsung",
    "00:09:18": "Hanwha/Samsung",
    "00:80:45": "Panasonic",
    "08:00:23": "Panasonic",
    "00:12:fb": "Sony",
}

# Textschnipsel aus HTTP-Header oder Seitentitel -> Hersteller. Zweite
# Chance, wenn die MAC-Adresse nicht in der ARP-Tabelle steht (anderes
# Subnetz) oder das OUI unbekannt ist.
HTTP_HERSTELLER_MUSTER = (
    ("mobotix", "Mobotix"),
    ("axis", "Axis"),
    ("hikvision", "Hikvision"),
    ("dvrdvs", "Hikvision"),
    ("dahua", "Dahua"),
    ("bosch", "Bosch"),
    ("vivotek", "Vivotek"),
    ("hanwha", "Hanwha/Samsung"),
    ("wisenet", "Hanwha/Samsung"),
    ("samsung", "Hanwha/Samsung"),
    ("panasonic", "Panasonic"),
    ("i-pro", "Panasonic"),
    ("reolink", "Reolink"),
    ("foscam", "Foscam"),
    ("amcrest", "Amcrest"),
    ("uniview", "Uniview"),
    ("avigilon", "Avigilon"),
    ("geovision", "GeoVision"),
)


def leeres_ergebnis(ip: str = "") -> dict:
    """Das Rückgabegerüst von kamera_pruefen() - immer dieselben Felder."""
    return {
        "ip": str(ip),
        "erreichbar": False,
        "ports": [],
        "onvif": False,
        "benutzer": None,
        "passwort": None,
        "stream": None,
        "quelle": "",
        "art": "rtsp",
        "weitere_streams": [],
        "hersteller": None,
        "fehler": None,
    }


# --------------------------------------------------------------------------
# 1) ONVIF-Suche
# --------------------------------------------------------------------------

def _probe_nachricht() -> bytes:
    """Baut eine WS-Discovery-Probe nach NetworkVideoTransmitter."""
    kennung = f"urn:uuid:{os.urandom(16).hex()}"
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"'
        ' xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"'
        ' xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"'
        ' xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
        "<e:Header>"
        f"<w:MessageID>{kennung}</w:MessageID>"
        '<w:To e:mustUnderstand="true">'
        "urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"
        '<w:Action e:mustUnderstand="true">'
        "http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>"
        "</e:Header>"
        "<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types>"
        "</d:Probe></e:Body>"
        "</e:Envelope>"
    )
    return xml.encode("utf-8")


def _ist_kamera_antwort(text: str) -> bool:
    """Prüft, ob eine Antwort wirklich von einer Kamera kommt.

    Auf 239.255.255.250:3702 horcht nicht nur ONVIF: Windows-Rechner und
    Netzwerkdrucker antworten dort ebenfalls (WSD). Nur Antworten, die sich
    als ONVIF ausweisen, werden übernommen.
    """
    klein = text.lower()
    if "probematch" not in klein:
        return False
    return "networkvideotransmitter" in klein or "onvif" in klein


def _ips_aus_antwort(text: str) -> list[str]:
    """Zieht die brauchbaren IPv4-Adressen aus den XAddrs einer Antwort.

    Kameras führen dort gern mehrere Adressen auf, unter anderem eine
    Selbstvergebene (169.254.x.x). Die wird übergangen, sonst erscheint
    dieselbe Kamera zweimal in der Trefferliste.
    """
    gefunden = []
    for treffer in re.findall(r"https?://([0-9A-Za-z_.\-]+)", text):
        wirt = treffer.split(":")[0]
        try:
            adresse = ipaddress.IPv4Address(wirt)
        except ValueError:
            continue                      # Hostname oder IPv6 - überspringen
        if adresse.is_link_local or adresse.is_loopback or adresse.is_unspecified:
            continue
        gefunden.append(wirt)
    return gefunden


def onvif_suche(timeout: float = 3.0) -> list[str]:
    """Sucht ONVIF-Kameras per WS-Discovery, liefert deren IP-Adressen.

    Gebunden wird an 0.0.0.0, damit die Anfrage bei mehreren Netzwerkkarten
    über die Standardroute hinausgeht. Fehler (kein Netz, Multicast
    gesperrt) ergeben eine leere Liste, nie eine Ausnahme.
    """
    gefunden: list[str] = []
    bekannt: set[str] = set()
    ende = time.monotonic() + max(0.2, timeout)
    steckdose = None
    try:
        steckdose = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        steckdose.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        steckdose.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 4)
        steckdose.bind(("0.0.0.0", 0))

        # Zweimal fragen: UDP-Multicast geht gern einmal verloren.
        for _ in range(2):
            try:
                steckdose.sendto(_probe_nachricht(), (ONVIF_ADRESSE, ONVIF_PORT))
            except OSError:
                pass

        while True:
            rest = ende - time.monotonic()
            if rest <= 0:
                break
            steckdose.settimeout(min(rest, 0.5))
            try:
                rohdaten, absender = steckdose.recvfrom(65535)
            except (socket.timeout, TimeoutError):
                continue
            except OSError:
                break
            text = rohdaten.decode("utf-8", "ignore")
            if not _ist_kamera_antwort(text):
                continue                  # Drucker, PC oder eigenes Echo
            # Absenderadresse ist die zuverlässigste Quelle, XAddrs ergänzt.
            for ip in [absender[0]] + _ips_aus_antwort(text):
                if ip not in bekannt:
                    bekannt.add(ip)
                    gefunden.append(ip)
    except OSError:
        return gefunden
    finally:
        if steckdose is not None:
            try:
                steckdose.close()
            except OSError:
                pass
    return gefunden


# --------------------------------------------------------------------------
# 2) Hostliste aus einer Netzangabe
# --------------------------------------------------------------------------

def _bereich_hosts(text: str) -> list[str]:
    """Löst "192.168.1.1-192.168.1.50" oder kurz "192.168.1.1-50" auf."""
    links, rechts = (teil.strip() for teil in text.split("-", 1))
    try:
        start = ipaddress.IPv4Address(links)
    except ValueError as fehler:
        raise ValueError(
            f"Ungültige Startadresse im Bereich: {links!r}"
        ) from fehler

    if "." in rechts:
        try:
            ende = ipaddress.IPv4Address(rechts)
        except ValueError as fehler:
            raise ValueError(
                f"Ungültige Endadresse im Bereich: {rechts!r}"
            ) from fehler
    else:
        # Kurzform: nur das letzte Oktett wurde angegeben.
        if not rechts.isdigit() or int(rechts) > 255:
            raise ValueError(
                f"Ungültiges letztes Oktett im Bereich: {rechts!r}"
            )
        ende = ipaddress.IPv4Address(".".join(links.split(".")[:3] + [rechts]))

    if int(ende) < int(start):
        raise ValueError("Das Bereichsende liegt vor dem Bereichsanfang.")
    anzahl = int(ende) - int(start) + 1
    if anzahl > MAX_HOSTS:
        raise ValueError(
            f"Der Bereich ist zu groß ({anzahl} Adressen). "
            f"Erlaubt sind höchstens {MAX_HOSTS}."
        )
    return [str(ipaddress.IPv4Address(wert)) for wert in range(int(start), int(ende) + 1)]


def netz_hosts(netz: str) -> list[str]:
    """Liefert die zu prüfenden Host-Adressen einer Netzangabe.

    Erlaubt sind CIDR-Netze ("192.168.1.0/24"), Bereiche
    ("192.168.1.1-192.168.1.50" oder kurz "192.168.1.1-50") und einzelne
    Adressen ("192.168.1.5"). Netz- und Broadcastadresse fallen weg. Bei
    unbrauchbaren Eingaben kommt ein ValueError mit deutscher Meldung.
    """
    if not isinstance(netz, str) or not netz.strip():
        raise ValueError("Es wurde keine Netzangabe übergeben.")
    text = netz.strip()

    if "-" in text:
        return _bereich_hosts(text)

    if "/" in text:
        try:
            netzwerk = ipaddress.ip_network(text, strict=False)
        except ValueError as fehler:
            raise ValueError(f"Ungültige Netzangabe: {text!r}") from fehler
        if netzwerk.version != 4:
            raise ValueError("Es werden nur IPv4-Netze unterstützt.")
        if netzwerk.num_addresses > MAX_HOSTS:
            raise ValueError(
                f"Das Netz ist zu groß ({netzwerk.num_addresses} Adressen). "
                f"Erlaubt sind höchstens {MAX_HOSTS}."
            )
        # hosts() lässt Netz- und Broadcastadresse selbst weg.
        return [str(adresse) for adresse in netzwerk.hosts()]

    try:
        adresse = ipaddress.ip_address(text)
    except ValueError as fehler:
        raise ValueError(
            f"Ungültige Netzangabe: {text!r}. Erwartet wird zum Beispiel "
            '"192.168.1.0/24", "192.168.1.1-192.168.1.50" oder "192.168.1.7".'
        ) from fehler
    if adresse.version != 4:
        raise ValueError("Es werden nur IPv4-Adressen unterstützt.")
    return [str(adresse)]


# --------------------------------------------------------------------------
# 3) Portprüfung
# --------------------------------------------------------------------------

def port_offen(ip: str, port: int, timeout: float = 1.0) -> bool:
    """Prüft, ob ein TCP-Port erreichbar ist. Immer mit Zeitgrenze."""
    try:
        with socket.create_connection((ip, int(port)), timeout=max(0.05, timeout)):
            return True
    except (OSError, ValueError, OverflowError):
        return False


# --------------------------------------------------------------------------
# RTSP-Prüfung mit ffprobe
# --------------------------------------------------------------------------

def _werkzeug(name: str) -> str | None:
    """Sucht ein externes Programm im PATH. None heißt: nicht vorhanden."""
    return shutil.which(name)


def rtsp_adresse_bauen(
    ip: str, benutzer: str | None, passwort: str | None, pfad: str
) -> str:
    """Baut eine RTSP-Adresse und kodiert Sonderzeichen der Zugangsdaten.

    Wichtig, weil Passwörter wie "GeheimesPasswort!23" die Adresse sonst
    zerlegen würden - daraus wird "GeheimesPasswort%2123".
    """
    zugang = ""
    if benutzer:
        zugang = urllib.parse.quote(str(benutzer), safe="")
        if passwort:
            zugang += ":" + urllib.parse.quote(str(passwort), safe="")
        zugang += "@"
    return f"rtsp://{zugang}{ip}:{RTSP_PORT}/{(pfad or '').lstrip('/')}"


def _bildrate(bruch: str | None) -> float | None:
    """Rechnet ffprobe-Brüche wie "25/1" in eine Zahl um."""
    if not bruch or "/" not in str(bruch):
        return None
    zaehler, _, nenner = str(bruch).partition("/")
    try:
        oben, unten = float(zaehler), float(nenner)
    except ValueError:
        return None
    if oben <= 0 or unten <= 0:
        return None                       # "0/0" heißt: unbekannt
    return round(oben / unten, 2)


def _stream_pruefen(adresse: str, pfad: str, timeout: float) -> dict | None:
    """Fragt einen RTSP-Stream mit ffprobe ab.

    Rückgabe ist ein Streameintrag oder None - letzteres auch dann, wenn
    ffprobe fehlt, die Zeit abgelaufen ist oder kein Videobild kommt. Die
    Zeitgrenze des Unterprozesses ist die harte Grenze: hängen bleiben kann
    der Aufruf damit nicht.
    """
    ffprobe = _werkzeug("ffprobe")
    if not ffprobe or timeout <= 0:
        return None
    befehl = [
        ffprobe,
        "-v", "error",
        "-rtsp_transport", "tcp",         # UDP fällt in fremden Netzen oft aus
        "-analyzeduration", "2000000",
        "-probesize", "1000000",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,codec_name,avg_frame_rate",
        "-print_format", "json",
        "-i", adresse,
    ]
    try:
        lauf = subprocess.run(
            befehl,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            timeout=max(1.0, timeout),
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    if lauf.returncode != 0 or not lauf.stdout:
        return None
    try:
        daten = json.loads(lauf.stdout.decode("utf-8", "ignore"))
    except ValueError:
        return None
    streams = daten.get("streams") or []
    if not streams:
        return None
    erster = streams[0]
    try:
        breite = int(erster.get("width") or 0)
        hoehe = int(erster.get("height") or 0)
    except (TypeError, ValueError):
        return None
    if breite <= 0 or hoehe <= 0:
        return None                       # Tonspur oder leere Antwort
    return {
        "pfad": pfad,
        "breite": breite,
        "hoehe": hoehe,
        "codec": str(erster.get("codec_name") or "unbekannt"),
        "fps": _bildrate(erster.get("avg_frame_rate")),
    }


# --------------------------------------------------------------------------
# Herstellererkennung
# --------------------------------------------------------------------------

def _mac_normieren(rohwert: str) -> str | None:
    """Bringt eine MAC-Adresse auf die Form "00:03:c5:11:22:33"."""
    zeichen = re.sub(r"[^0-9a-fA-F]", "", rohwert or "").lower()
    if len(zeichen) != 12 or zeichen in ("0" * 12, "f" * 12):
        return None
    return ":".join(zeichen[i:i + 2] for i in range(0, 12, 2))


def _mac_aus_arp(ip: str, timeout: float = 2.0) -> str | None:
    """Liest die MAC-Adresse einer IP aus der ARP-Tabelle des Systems."""
    # Linux (Raspberry Pi OS): /proc/net/arp ist schnell und braucht kein
    # Unterprogramm. Der vorangegangene Portscan hat den Eintrag erzeugt.
    try:
        with open("/proc/net/arp", "r", encoding="ascii", errors="ignore") as datei:
            for zeile in datei:
                felder = zeile.split()
                if len(felder) >= 4 and felder[0] == ip:
                    return _mac_normieren(felder[3])
    except OSError:
        pass                              # kein Linux oder kein /proc

    befehl = ["arp", "-a", ip] if os.name == "nt" else ["arp", "-n", ip]
    try:
        lauf = subprocess.run(
            befehl,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            timeout=max(0.5, timeout),
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    for zeile in (lauf.stdout or b"").decode("utf-8", "ignore").splitlines():
        if ip not in zeile:
            continue
        treffer = re.search(r"([0-9a-fA-F]{2}(?:[:-][0-9a-fA-F]{2}){5})", zeile)
        if treffer:
            return _mac_normieren(treffer.group(1))
    return None


def _hersteller_aus_mac(mac: str | None) -> str | None:
    """Ordnet eine MAC-Adresse über das OUI-Präfix einem Hersteller zu."""
    if not mac:
        return None
    return OUI_HERSTELLER.get(mac[:8])


def _hersteller_aus_text(text: str) -> str | None:
    """Sucht bekannte Herstellernamen in einem Textschnipsel."""
    klein = (text or "").lower()
    for schnipsel, hersteller in HTTP_HERSTELLER_MUSTER:
        if schnipsel in klein:
            return hersteller
    return None


def _hersteller_aus_http(ip: str, ports: list[int], timeout: float = 2.0) -> str | None:
    """Liest Server-Header, Anmelde-Realm und Seitentitel der Weboberfläche."""
    ende = time.monotonic() + max(0.5, timeout)
    for port in (80, 443):
        if port not in ports or time.monotonic() >= ende:
            continue
        adresse = f"{'https' if port == 443 else 'http'}://{ip}:{port}/"
        # Kameras haben fast immer ein selbst ausgestelltes Zertifikat.
        kontext = ssl._create_unverified_context() if port == 443 else None
        anfrage = urllib.request.Request(adresse, headers={"User-Agent": "CamGrid"})
        text = ""
        try:
            with urllib.request.urlopen(
                anfrage, timeout=max(0.5, ende - time.monotonic()), context=kontext
            ) as antwort:
                text = " ".join(f"{name}: {wert}" for name, wert in antwort.headers.items())
                text += " " + antwort.read(8192).decode("utf-8", "ignore")
        except urllib.error.HTTPError as fehler:
            # Auch 401 ist aufschlussreich: im Realm steht oft der Hersteller.
            try:
                text = " ".join(f"{name}: {wert}" for name, wert in fehler.headers.items())
            except (AttributeError, ValueError):
                text = ""
        except (urllib.error.URLError, OSError, ValueError):
            continue
        titel = re.search(r"<title[^>]*>(.{0,200}?)</title>", text, re.I | re.S)
        if titel:
            text += " " + titel.group(1)
        hersteller = _hersteller_aus_text(text)
        if hersteller:
            return hersteller
    return None


def _hersteller_bestimmen(ip: str, ports: list[int], budget: float = 4.0) -> str | None:
    """Erst die MAC-Adresse versuchen, dann die Weboberfläche.

    `budget` ist die noch verbleibende Zeit in Sekunden; beide Schritte
    halten sich daran, damit kamera_pruefen() seine Zeitgrenze einhält.
    """
    ende = time.monotonic() + max(0.5, budget)
    hersteller = _hersteller_aus_mac(_mac_aus_arp(ip, timeout=min(2.0, budget)))
    if hersteller:
        return hersteller
    rest = ende - time.monotonic()
    if rest < 0.5:
        return None
    return _hersteller_aus_http(ip, ports, timeout=min(2.0, rest))


# --------------------------------------------------------------------------
# 4) Eine Kamera prüfen
# --------------------------------------------------------------------------

def _zugangsliste(zugangsdaten: list[dict] | None) -> list[tuple[str | None, str | None]]:
    """Normiert die Zugangsdaten. Leere Liste heißt: ohne Login probieren."""
    liste: list[tuple[str | None, str | None]] = []
    for satz in zugangsdaten or []:
        if not isinstance(satz, dict):
            continue
        liste.append((satz.get("benutzer") or None, satz.get("passwort") or None))
    if not liste:
        liste.append((None, None))
    return liste


def _nebenstroeme_pruefen(
    ip: str,
    benutzer: str | None,
    passwort: str | None,
    treffer_pfad: str,
    ende: float,
    einzel_timeout: float,
) -> list[dict]:
    """Prüft die typischen Partnerpfade des gefundenen Streams."""
    weitere: list[dict] = []
    for partner in NEBENSTROM_PAARE.get(treffer_pfad, ()):
        rest = ende - time.monotonic()
        if rest <= 1.0:
            break                         # Zeit ist um, Hauptstrom genügt
        eintrag = _stream_pruefen(
            rtsp_adresse_bauen(ip, benutzer, passwort, partner),
            partner,
            min(einzel_timeout, rest),
        )
        if eintrag:
            weitere.append(eintrag)
    return weitere


def _stream_suchen(
    ip: str,
    zugangsdaten: list[dict],
    pfade: list[str],
    ende: float,
) -> tuple[str | None, str | None, dict | None]:
    """Probiert Pfade und Zugangsdaten durch, bis ein Stream Bild liefert."""
    einzel_timeout = max(1.5, min(3.0, (ende - time.monotonic()) / 3.0))
    for benutzer, passwort in _zugangsliste(zugangsdaten):
        for pfad in pfade:
            rest = ende - time.monotonic()
            if rest <= 1.0:
                return None, None, None   # Zeitbudget für diese IP verbraucht
            gefunden = _stream_pruefen(
                rtsp_adresse_bauen(ip, benutzer, passwort, pfad),
                pfad,
                min(einzel_timeout, rest),
            )
            if gefunden:
                return benutzer, passwort, gefunden
    return None, None, None


def _eigener_rtsp_test(ip: str, zugangsdaten: list[dict], pfade, ergebnis: dict,
                       ende: float) -> bool:
    """Sucht den Stream mit app/rtsp.py (ohne ffprobe).

    Trägt Treffer direkt in `ergebnis` ein und meldet, ob etwas gefunden wurde.
    Schlägt das fehl, geht der Aufrufer den alten Weg über ffprobe.
    """
    rest = ende - time.monotonic()
    if rest < 1.0:
        return False
    try:
        from app import rtsp
    except ImportError:
        return False

    liste = list(pfade) if pfade else list(STANDARD_PFADE)
    versuche = zugangsdaten or [{"benutzer": "", "passwort": ""}]
    treffer = rtsp.pfade_testen(ip, liste[:14], versuche, timeout=min(4.0, rest))
    if not treffer:
        return False

    # Kleinster Strom zuerst anbieten: der belastet die Anzeige am wenigsten.
    bester = treffer[-1]
    ergebnis["benutzer"] = bester["benutzer"]
    ergebnis["passwort"] = bester["passwort"]
    ergebnis["stream"] = {
        "pfad": bester["pfad"], "breite": bester["breite"], "hoehe": bester["hoehe"],
        "codec": bester["codec"], "fps": bester["fps"],
    }
    ergebnis["weitere_streams"] = [
        {"pfad": t["pfad"], "breite": t["breite"], "hoehe": t["hoehe"],
         "codec": t["codec"], "fps": t["fps"]} for t in treffer
    ]
    return True


def _mjpeg_versuchen(ip: str, zugangsdaten: list[dict], timeout: float) -> dict:
    """Sucht einen MJPEG-Strom über HTTP und baut daraus einen Treffer.

    Auflösung lässt sich so nicht sicher bestimmen; dafür steht die Kamera
    wenigstens mit Bild in der Liste statt als "kein Video".
    """
    try:
        from app import kamerabild
    except ImportError:
        return {}

    for zugang in (zugangsdaten or [{"benutzer": "", "passwort": ""}]):
        fund = kamerabild.mjpeg_suchen(ip, zugang.get("benutzer", ""),
                                       zugang.get("passwort", ""), timeout=timeout)
        if fund:
            return {
                "benutzer": zugang.get("benutzer") or None,
                "passwort": zugang.get("passwort") or None,
                "quelle": fund["quelle"],
                "art": "mjpeg",
                "stream": {"pfad": fund["pfad"], "breite": 0, "hoehe": 0,
                           "codec": "mjpeg", "fps": None},
                "fehler": None,
            }
    return {}


def kamera_pruefen(
    ip: str,
    zugangsdaten: list[dict],
    pfade: list[str] | None = None,
    timeout: float = 6.0,
) -> dict:
    """Prüft eine einzelne IP-Adresse auf eine Netzwerkkamera.

    Erst werden die Ports 554/80/443 abgeklopft. Ist 554 offen, werden die
    RTSP-Pfade mit jedem Zugangsdatensatz durchprobiert, bis einer ein Bild
    liefert; danach noch der zugehörige Nebenstrom. Die Gesamtlaufzeit hält
    sich an `timeout`, und das Rückgabeformat ist immer dasselbe - auch
    wenn nichts gefunden wurde.
    """
    ergebnis = leeres_ergebnis(ip)
    ende = time.monotonic() + max(1.0, timeout)
    # Kurz halten: bei toten Adressen laufen alle drei Ports in die
    # Zeitgrenze, und davon gibt es in einem /24 die meisten.
    port_timeout = min(1.0, max(0.3, timeout / 6.0))

    # Schritt 1: Ports abklopfen.
    for port in PRUEF_PORTS:
        if time.monotonic() >= ende:
            break
        if port_offen(ip, port, timeout=port_timeout):
            ergebnis["ports"].append(port)
    ergebnis["erreichbar"] = bool(ergebnis["ports"])
    if not ergebnis["erreichbar"]:
        ergebnis["fehler"] = "Kein offener Port (554/80/443) gefunden."
        return ergebnis

    # Schritt 2: RTSP-Pfade durchprobieren.
    # Zuerst der eigene RTSP-Test (app/rtsp.py): der braucht kein ffprobe,
    # ist deutlich schneller und liest die Auflösung direkt aus dem Stream.
    if RTSP_PORT not in ergebnis["ports"]:
        ergebnis["fehler"] = "Port 554 (RTSP) ist geschlossen."
    elif _eigener_rtsp_test(ip, zugangsdaten, pfade, ergebnis, ende):
        pass
    elif not _werkzeug("ffprobe"):
        ergebnis["fehler"] = "Kein Stream gefunden (Zugangsdaten oder Pfad prüfen)."
    else:
        liste = list(pfade) if pfade is not None else list(STANDARD_PFADE)
        benutzer, passwort, stream = _stream_suchen(ip, zugangsdaten, liste, ende)
        if stream:
            ergebnis["benutzer"] = benutzer
            ergebnis["passwort"] = passwort
            ergebnis["stream"] = stream
            einzel_timeout = max(1.5, min(3.0, (ende - time.monotonic()) / 2.0))
            ergebnis["weitere_streams"] = [stream] + _nebenstroeme_pruefen(
                ip, benutzer, passwort, stream["pfad"], ende, einzel_timeout
            )
        else:
            ergebnis["fehler"] = "Port 554 offen, aber kein Stream abspielbar."

    # Schritt 2b: Kameras ohne RTSP (z. B. klassische Mobotix) liefern MJPEG
    # über HTTP. Das ist hier die zweite Chance, bevor aufgegeben wird.
    if not ergebnis["stream"] and (80 in ergebnis["ports"] or 443 in ergebnis["ports"]):
        rest = ende - time.monotonic()
        if rest > 1.0:
            ergebnis.update(_mjpeg_versuchen(ip, zugangsdaten, min(6.0, rest)))

    # Schritt 3: Hersteller bestimmen, solange noch Zeit übrig ist.
    rest = ende - time.monotonic()
    if rest > 0.5:
        ergebnis["hersteller"] = _hersteller_bestimmen(ip, ergebnis["ports"], rest)
    return ergebnis


# --------------------------------------------------------------------------
# 5) Kompletter Netzscan
# --------------------------------------------------------------------------

def _ip_schluessel(eintrag: dict) -> int:
    """Sortierschlüssel: Zahlenwert der IP, damit .10 hinter .9 kommt."""
    try:
        return int(ipaddress.IPv4Address(eintrag.get("ip", "0.0.0.0")))
    except ValueError:
        return 0


def netz_scannen(
    netz: str,
    zugangsdaten: list[dict],
    fortschritt=None,
    max_threads: int = 64,
) -> list[dict]:
    """Scannt ein Netz vollständig und liefert nur die Treffer.

    Zuerst läuft die ONVIF-Suche; die dabei gefundenen Adressen werden im
    Ergebnis mit "onvif": True markiert und mitgeprüft, auch wenn sie
    außerhalb der Netzangabe liegen. Danach werden alle Hosts parallel
    geprüft. `fortschritt` wird nach jedem Host als
    fortschritt(fertig, gesamt, aktuelle_ip) aufgerufen; Fehler daraus
    werden verschluckt, damit ein kaputter Rückruf den Scan nicht stoppt.
    Sortiert wird numerisch nach IP.
    """
    onvif_ips = set(onvif_suche())
    hosts = netz_hosts(netz)
    bekannt = set(hosts)
    hosts += [ip for ip in sorted(onvif_ips, key=ipaddress.IPv4Address) if ip not in bekannt]

    gesamt = len(hosts)
    treffer: list[dict] = []
    sperre = threading.Lock()
    zaehler = {"fertig": 0}

    def melden(ip: str) -> None:
        """Ruft den Fortschritts-Rückruf abgesichert auf."""
        with sperre:
            zaehler["fertig"] += 1
            fertig = zaehler["fertig"]
        if fortschritt is None:
            return
        try:
            fortschritt(fertig, gesamt, ip)
        except Exception:
            pass

    arbeiter = max(1, min(int(max_threads or 1), gesamt or 1))
    with ThreadPoolExecutor(max_workers=arbeiter) as pool:
        auftraege = {pool.submit(kamera_pruefen, ip, zugangsdaten): ip for ip in hosts}
        for auftrag in as_completed(auftraege):
            ip = auftraege[auftrag]
            try:
                ergebnis = auftrag.result()
            except Exception as fehler:   # ein Host darf den Scan nie abbrechen
                ergebnis = leeres_ergebnis(ip)
                ergebnis["fehler"] = f"Prüfung fehlgeschlagen: {fehler}"
            if ip in onvif_ips:
                ergebnis["onvif"] = True
            if ergebnis["erreichbar"] or ergebnis["stream"]:
                treffer.append(ergebnis)
            melden(ip)

    treffer.sort(key=_ip_schluessel)
    return treffer


# --------------------------------------------------------------------------
# 6) Schnappschuss
# --------------------------------------------------------------------------

def schnappschuss(
    ip: str,
    benutzer: str | None,
    passwort: str | None,
    pfad: str,
    timeout: float = 8.0,
) -> bytes | None:
    """Holt ein einzelnes JPEG-Bild aus einem RTSP-Stream.

    Braucht `ffmpeg`. Geschrieben wird nur in ein temporäres Verzeichnis,
    zurück kommen die Bilddaten. Bei jedem Problem - kein ffmpeg, kein
    Bild, Zeit abgelaufen - ist die Rückgabe None.
    """
    ffmpeg = _werkzeug("ffmpeg")
    if not ffmpeg:
        return None
    adresse = rtsp_adresse_bauen(ip, benutzer, passwort, pfad)
    try:
        with tempfile.TemporaryDirectory(prefix="camgrid-") as ordner:
            ziel = os.path.join(ordner, "bild.jpg")
            befehl = [
                ffmpeg,
                "-nostdin", "-loglevel", "error", "-y",
                "-rtsp_transport", "tcp",
                "-i", adresse,
                "-frames:v", "1",
                "-q:v", "3",
                "-f", "image2",
                ziel,
            ]
            try:
                subprocess.run(
                    befehl,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    stdin=subprocess.DEVNULL,
                    timeout=max(2.0, timeout),
                    check=False,
                )
            except (subprocess.TimeoutExpired, OSError):
                return None
            if not os.path.isfile(ziel) or os.path.getsize(ziel) == 0:
                return None
            with open(ziel, "rb") as datei:
                daten = datei.read()
    except OSError:
        return None
    return daten or None


# --------------------------------------------------------------------------
# Selbsttest von der Kommandozeile
# --------------------------------------------------------------------------

def _tabelle_ausgeben(treffer: list[dict]) -> None:
    """Gibt die Treffer als einfache Tabelle aus (nur für den Selbsttest)."""
    kopf = (
        f"{'IP':<16}{'Ports':<14}{'ONVIF':<7}{'Hersteller':<16}"
        f"{'Auflösung':<12}{'Pfad / Hinweis'}"
    )
    print(kopf)
    print("-" * 95)
    for eintrag in treffer:
        ports = ",".join(str(port) for port in eintrag["ports"]) or "-"
        stream = eintrag["stream"]
        aufloesung = f"{stream['breite']}x{stream['hoehe']}" if stream else "-"
        hinweis = stream["pfad"] if stream else (eintrag["fehler"] or "-")
        print(
            f"{eintrag['ip']:<16}{ports:<14}"
            f"{('ja' if eintrag['onvif'] else 'nein'):<7}"
            f"{(eintrag['hersteller'] or '-'):<16}{aufloesung:<12}{hinweis}"
        )
    print(f"\n{len(treffer)} Treffer.")


def _hauptprogramm(argumente: list[str]) -> int:
    """Startet einen Scan von der Kommandozeile."""
    if not argumente:
        print("Aufruf: python -m app.scan <Netz> [benutzer:passwort ...]")
        print('Beispiel: python -m app.scan 192.168.1.0/24 "admin:GeheimesPasswort!23"')
        return 2

    zugangsdaten = []
    for angabe in argumente[1:]:
        benutzer, _, passwort = angabe.partition(":")
        zugangsdaten.append({"benutzer": benutzer, "passwort": passwort})

    # Die Windows-Konsole kann nicht immer Umlaute; lieber ersetzen als
    # den Selbsttest daran scheitern lassen.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError, ValueError):
        pass

    if not _werkzeug("ffprobe"):
        print("Hinweis: ffprobe fehlt - Ports werden geprüft, Streams nicht.")

    def zeigen(fertig: int, gesamt: int, ip: str) -> None:
        stand = f"{fertig}/{gesamt} geprüft ({ip})"
        print("\r" + stand.ljust(52), end="", flush=True)

    beginn = time.monotonic()
    try:
        treffer = netz_scannen(argumente[0], zugangsdaten, fortschritt=zeigen)
    except ValueError as fehler:
        print(f"Fehler: {fehler}")
        return 2
    print("\r" + " " * 52 + "\r", end="")
    _tabelle_ausgeben(treffer)
    print(f"Dauer: {time.monotonic() - beginn:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(_hauptprogramm(sys.argv[1:]))
