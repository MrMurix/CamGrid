"""Erzeugt die go2rtc-Konfiguration aus von CamGrid-Konfiguration.

Läuft vor jedem Start des Streaming-Dienstes (ExecStartPre) und immer dann,
wenn im Admin-Dashboard etwas an den Kameras geändert wurde. Damit gibt es
nur eine Quelle der Wahrheit: config.json.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import config as konfig  # noqa: E402

ZIEL = Path(os.environ.get("CAMGRID_GO2RTC_YAML", "/var/lib/camgrid/go2rtc.yaml"))
WEB = Path(os.environ.get("CAMGRID_WEB", "/opt/camgrid/web/public"))

# Der Admin-Server bedient mehrere Anfragen gleichzeitig. Ohne diese Sperre
# könnten zwei Anfragen go2rtc.yaml und anzeige.json in verschränkter
# Reihenfolge ersetzen - die Dateien wären zwar in sich heil (sie werden
# umbenannt, nicht überschrieben), könnten aber aus verschiedenen Ständen
# der Konfiguration stammen.
_schreib_sperre = threading.Lock()


def yaml_text(daten: dict) -> str:
    """Baut die go2rtc.yaml. Bewusst von Hand erzeugt, damit das Projekt
    ohne PyYAML auskommt - die Struktur ist einfach genug.

    Jeder Wert, der aus der Konfiguration kommt, wird in Anführungszeichen
    gesetzt (`_wert`). Sonst könnte ein Kamerapfad oder ein Passwort mit
    Doppelpunkt, Rautezeichen oder Zeilenumbruch eigene YAML-Zeilen
    erzeugen - und damit zum Beispiel einen zusätzlichen Stream oder einen
    offenen Zugang eintragen.
    """
    dienste = daten.get("dienste") or {}
    zugang = daten.get("zugang") or {}
    zeilen = [
        "# Diese Datei wird automatisch erzeugt - Änderungen hier gehen verloren.",
        "# Gepflegt wird alles in von CamGrid-Konfiguration (config.json).",
        "api:",
        f"  listen: \":{_port(dienste.get('go2rtc_port'), 1984)}\"",
        f"  static_dir: {_wert(WEB.resolve().as_posix())}",
    ]
    # Login nur für Zugriffe von außen; lokal (127.0.0.1) lässt go2rtc jeden durch.
    if zugang.get("anzeige_benutzer") and zugang.get("anzeige_passwort"):
        zeilen += [
            f"  username: {_wert(zugang['anzeige_benutzer'])}",
            f"  password: {_wert(zugang['anzeige_passwort'])}",
        ]
    zeilen += [
        "rtsp:",
        "  listen: \"127.0.0.1:8554\"",
        "webrtc:",
        "  listen: \":8555\"",
        "log:",
        "  level: info",
        "streams:",
    ]

    vergeben: set[str] = set()
    for kamera in daten.get("kameras") or []:
        if not isinstance(kamera, dict):
            continue
        name = konfig.stream_name(kamera)
        adresse = konfig.rtsp_adresse(kamera)
        if not name or name in vergeben:
            continue                      # ohne brauchbaren Namen kein Stream
        if not kamera.get("aktiv", True) or not adresse:
            continue                      # Platzhalter ohne IP übergehen
        vergeben.add(name)
        zeilen.append(f"  {name}: {_wert(adresse)}")

    return "\n".join(zeilen) + "\n"


def _wert(text: str) -> str:
    """YAML-Quoting für Zeichenketten.

    json.dumps erzeugt genau die Form, die YAML als doppelt gequotete
    Zeichenkette liest (Anführungszeichen, Backslash und Steuerzeichen
    werden maskiert).
    """
    return json.dumps(str(text), ensure_ascii=False)


def _port(wert, vorgabe: int) -> int:
    """Portnummer aus der Konfiguration, notfalls die Vorgabe."""
    try:
        zahl = int(wert)
    except (TypeError, ValueError, OverflowError):
        return vorgabe
    return zahl if 1 <= zahl <= 65535 else vorgabe


def anzeige_json(daten: dict, ziel: Path | None = None) -> Path:
    """Schreibt die Angaben, die die Anzeigeseite braucht, neben die Seite.

    Die Anzeigeseite wird von go2rtc ausgeliefert und kann den Admin-Server
    nicht fragen (anderer Port, andere Anmeldung). Deshalb legt der Server die
    nötigen Angaben - ohne Passwörter - als statische Datei daneben.
    """
    ziel = Path(ziel or (WEB / "anzeige.json"))
    inhalt = konfig.ohne_geheimnisse(daten)
    with _schreib_sperre:
        ziel.parent.mkdir(parents=True, exist_ok=True)
        _unteilbar_schreiben(ziel, json.dumps(inhalt, ensure_ascii=False, indent=2) + "\n")
    return ziel


def schreiben(daten: dict | None = None, ziel: Path = ZIEL) -> Path:
    daten = daten if isinstance(daten, dict) else konfig.laden()
    ziel = Path(ziel)
    try:
        anzeige_json(daten)
    except OSError as fehler:
        print(f"Warnung: anzeige.json konnte nicht geschrieben werden: {fehler}", file=sys.stderr)
    text = yaml_text(daten)
    with _schreib_sperre:
        ziel.parent.mkdir(parents=True, exist_ok=True)
        # 0600: die Datei enthält die Kamera-Passwörter.
        _unteilbar_schreiben(ziel, text, rechte=0o600)
    return ziel


def _unteilbar_schreiben(ziel: Path, text: str, rechte: int | None = None) -> None:
    """Schreibt erst in eine Nebendatei und benennt sie dann um.

    Damit sieht ein Leser (go2rtc, die Anzeigeseite) immer eine vollständige
    Datei. Bricht etwas ab, bleibt keine halbe Datei liegen.
    """
    temp = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=ziel.parent, delete=False, suffix=".tmp"
        ) as datei:
            temp = Path(datei.name)
            datei.write(text)
            datei.flush()
            os.fsync(datei.fileno())
        if rechte is not None:
            try:
                temp.chmod(rechte)
            except OSError:
                pass
        temp.replace(ziel)
        temp = None
    finally:
        if temp is not None:
            try:
                temp.unlink()
            except OSError:
                pass


# --------------------------------------------------------------------------
# Änderungen ohne Neustart übernehmen
# --------------------------------------------------------------------------

def uebernehmen(daten: dict, port: int | None = None) -> tuple[bool, str]:
    """Meldet die Streams direkt bei einem laufenden go2rtc an.

    Spart den Neustart des Dienstes: laufende Bilder auf der Wand bleiben
    stehen, nur geänderte Kameras werden neu verbunden. Gelingt das nicht
    (Dienst läuft nicht), meldet die Funktion das zurück - der Aufrufer kann
    dann neu starten.
    """
    schreiben(daten)
    port = _port(port or (daten.get("dienste") or {}).get("go2rtc_port"), 1984)
    basis = f"http://127.0.0.1:{port}/api"

    try:
        vorhanden = set(_json_holen(f"{basis}/streams"))
    except OSError as fehler:
        return False, f"go2rtc nicht erreichbar: {fehler}"
    except ValueError as fehler:
        # Antwort ist kein JSON: dann lieber melden als abstürzen.
        return False, f"go2rtc antwortet unverständlich: {fehler}"

    gewuenscht = {}
    for kamera in daten.get("kameras") or []:
        if not isinstance(kamera, dict):
            continue
        name = konfig.stream_name(kamera)
        adresse = konfig.rtsp_adresse(kamera)
        if name and adresse and kamera.get("aktiv", True):
            gewuenscht[name] = adresse

    fehler_liste = []
    for name, adresse in gewuenscht.items():
        try:
            _anfrage(f"{basis}/streams?name={_kodiert(name)}&src={_kodiert(adresse)}", "PUT")
        except OSError as fehler:
            fehler_liste.append(f"{name}: {fehler}")
    for name in vorhanden - set(gewuenscht):
        try:
            _anfrage(f"{basis}/streams?src={_kodiert(name)}", "DELETE")
        except OSError:
            pass                          # nicht schlimm, beim Neustart weg

    if fehler_liste:
        return False, "; ".join(fehler_liste)
    return True, f"{len(gewuenscht)} Kameras übernommen"


def _kodiert(text: str) -> str:
    from urllib.parse import quote

    return quote(text, safe="")


def _json_holen(adresse: str) -> dict:
    with urllib.request.urlopen(adresse, timeout=5) as antwort:
        daten = json.loads(antwort.read(4_000_000).decode("utf-8", "replace") or "{}")
    if not isinstance(daten, dict):
        raise ValueError("Es wurde ein JSON-Objekt erwartet.")
    return daten


def _anfrage(adresse: str, methode: str) -> None:
    anfrage = urllib.request.Request(adresse, method=methode)
    try:
        with urllib.request.urlopen(anfrage, timeout=5):
            return
    except urllib.error.HTTPError as fehler:
        raise OSError(f"HTTP {fehler.code}") from fehler


if __name__ == "__main__":
    ziel = schreiben()
    print(f"go2rtc-Konfiguration geschrieben: {ziel}")
