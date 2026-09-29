"""RTSP-Prüfung in reinem Python - ohne ffmpeg und ohne ffprobe.

Unter Windows ist ffmpeg meist nicht vorhanden, auf dem Raspberry Pi schon.
Damit eine Kamera trotzdem überall geprüft werden kann, spricht dieses Modul
das RTSP-Protokoll selbst: OPTIONS und DESCRIBE über eine einfache
TCP-Verbindung, Anmeldung per Basic oder Digest (RFC 2617), und die
Auflösung wird aus dem SDP gelesen.

Der aufwendigste Teil ist die Auflösung: im SDP steht bei H.264 kein
"width=...". Dort liegt nur der Parametersatz der Kamera
(`sprop-parameter-sets`, Base64). Darin steckt die SPS (Sequence Parameter
Set), und erst deren Bitfelder verraten die Bildgröße. Diese SPS wird hier
vollständig dekodiert (siehe `_sps_h264_lesen`).

Alle Funktionen arbeiten ohne gemeinsamen Zustand, jeder Socket bekommt eine
Zeitgrenze und wird in einem `finally` geschlossen. Das Modul darf daher aus
mehreren Threads eines HTTP-Servers gleichzeitig benutzt werden.
"""

from __future__ import annotations

import base64
import hashlib
import os
import re
import socket
import sys
import time
from concurrent.futures import ThreadPoolExecutor

# --------------------------------------------------------------------------
# Konstanten (außer diesen hält das Modul keinen Zustand)
# --------------------------------------------------------------------------

RTSP_PORT = 554

# Name, mit dem sich das Modul bei der Kamera meldet.
KENNUNG = "CamGrid/1.0"

# Höchstmenge an Bytes, die Kopf und Körper einer Antwort haben dürfen.
# Verhindert, dass ein Gerät, das kein RTSP spricht, den Speicher füllt.
MAX_KOPF = 65536
MAX_KOERPER = 262144

# H.264-Profile, bei denen die SPS zusätzlich chroma_format_idc und die
# Skalierungsmatrizen enthält (High-Profile-Familie, Anhang A von H.264).
H264_HOHE_PROFILE = frozenset(
    (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)
)

# Gleichzeitige Verbindungen in pfade_testen(). Kameras mögen keine
# unbegrenzte Zahl paralleler RTSP-Sitzungen.
MAX_THREADS = 8


def verfuegbar() -> bool:
    """Immer True - dieses Modul braucht kein externes Programm.

    Existiert nur, damit Aufrufer einheitlich `modul.verfuegbar()` prüfen
    können, egal ob sie mit diesem Modul oder mit einem ffmpeg-Weg arbeiten.
    """
    return True


def leeres_ergebnis() -> dict:
    """Das Rückgabegerüst von beschreiben() - immer dieselben Felder."""
    return {
        "erfolg": False,
        "status": 0,
        "codec": None,
        "breite": None,
        "hoehe": None,
        "fps": None,
        "spuren": [],
        "sdp": None,
        "fehler": None,
        "auth": "keine",
    }


# --------------------------------------------------------------------------
# 1) Bitweises Lesen (Grundlage der SPS-Dekodierung)
# --------------------------------------------------------------------------

class _BitFehler(ValueError):
    """Die Bitfolge ist zu kurz oder unsinnig - die SPS ist unbrauchbar."""


class _BitLeser:
    """Liest eine Bytefolge bitweise, wie H.264/H.265 es verlangen.

    H.264 legt seine Felder nicht auf Bytegrenzen, sondern packt sie dicht
    hintereinander. Zusätzlich werden viele Zahlen als "Exp-Golomb" kodiert:
    erst n Nullbits, dann eine Eins, dann n weitere Bits. Damit lassen sich
    kleine Zahlen sehr kurz und große Zahlen überhaupt darstellen.
    """

    __slots__ = ("_daten", "_pos")

    def __init__(self, daten: bytes) -> None:
        self._daten = daten
        self._pos = 0                       # Leseposition in Bits

    def rest(self) -> int:
        """Anzahl noch lesbarer Bits."""
        return len(self._daten) * 8 - self._pos

    def u(self, anzahl: int) -> int:
        """Liest `anzahl` Bits als vorzeichenlose Zahl (u(n) in der Norm)."""
        if anzahl < 0 or anzahl > self.rest():
            raise _BitFehler("Bitfolge zu kurz")
        wert = 0
        for _ in range(anzahl):
            byte = self._daten[self._pos >> 3]
            bit = (byte >> (7 - (self._pos & 7))) & 1
            wert = (wert << 1) | bit
            self._pos += 1
        return wert

    def flag(self) -> int:
        """Liest ein einzelnes Bit (u(1) in der Norm)."""
        return self.u(1)

    def ue(self) -> int:
        """Liest eine vorzeichenlose Exp-Golomb-Zahl (ue(v) in der Norm).

        Aufbau: k Nullbits, dann eine Eins, dann k Nutzbits. Der Wert ist
        2^k - 1 + Nutzbits. Aus "1" wird 0, aus "010" wird 1, aus "011"
        wird 2, aus "00100" wird 3 - und so weiter.
        """
        nullen = 0
        while True:
            if self.rest() <= 0:
                raise _BitFehler("Exp-Golomb läuft über das Ende hinaus")
            if self.u(1) == 1:
                break
            nullen += 1
            if nullen > 32:
                # Mehr als 32 führende Nullen kommt in echten Strömen nicht
                # vor; dann liest man in Wahrheit Müll.
                raise _BitFehler("Exp-Golomb unplausibel lang")
        if nullen == 0:
            return 0
        return (1 << nullen) - 1 + self.u(nullen)

    def se(self) -> int:
        """Liest eine vorzeichenbehaftete Exp-Golomb-Zahl (se(v)).

        Die Norm bildet 0, 1, -1, 2, -2, ... auf 0, 1, 2, 3, 4, ... ab:
        ungerade Werte sind positiv, gerade negativ.
        """
        wert = self.ue()
        if wert == 0:
            return 0
        betrag = (wert + 1) // 2
        return betrag if wert % 2 == 1 else -betrag


def _rbsp_entpacken(daten: bytes) -> bytes:
    """Entfernt die "Emulation Prevention Bytes" aus einer NAL-Einheit.

    In einem Videostrom markiert die Folge 00 00 01 den Anfang einer neuen
    NAL-Einheit. Damit Nutzdaten diese Folge nie versehentlich erzeugen,
    schiebt der Kodierer nach zwei Nullbytes ein 0x03 ein (00 00 03 xx).
    Vor dem Bitlesen muss dieses 0x03 wieder heraus, sonst verrutschen alle
    folgenden Felder.
    """
    ergebnis = bytearray()
    nullen = 0
    for byte in daten:
        if nullen >= 2 and byte == 0x03:
            nullen = 0
            continue                        # eingeschobenes Byte verwerfen
        ergebnis.append(byte)
        nullen = nullen + 1 if byte == 0x00 else 0
    return bytes(ergebnis)


def _startcode_abschneiden(daten: bytes) -> bytes:
    """Entfernt einen vorangestellten Startcode (00 00 01 / 00 00 00 01).

    Manche Kameras schreiben den Parametersatz mit Startcode ins SDP,
    andere ohne. Beides muss hier funktionieren.
    """
    if daten[:4] == b"\x00\x00\x00\x01":
        return daten[4:]
    if daten[:3] == b"\x00\x00\x01":
        return daten[3:]
    return daten


# --------------------------------------------------------------------------
# 2) H.264: SPS dekodieren
# --------------------------------------------------------------------------

def _skalierungsliste_ueberspringen(leser: _BitLeser, groesse: int) -> None:
    """Überliest eine Quantisierungs-Skalierungsliste (scaling_list()).

    Ihr Inhalt interessiert hier nicht, aber ihre Länge ist variabel: sobald
    ein Delta den laufenden Wert auf 0 bringt, werden keine weiteren Deltas
    mehr kodiert. Ohne diese Schleife wäre die Leseposition bei
    High-Profile-Strömen falsch.
    """
    letzter = 8
    naechster = 8
    for _ in range(groesse):
        if naechster != 0:
            delta = leser.se()
            naechster = (letzter + delta + 256) % 256
        letzter = naechster if naechster != 0 else letzter


def _vui_fps_lesen(leser: _BitLeser) -> float | None:
    """Liest aus den VUI-Parametern die Bildrate, wenn sie dort steht.

    Die VUI (Video Usability Information) steht am Ende der SPS. Uns
    interessiert nur `timing_info`: dort stehen num_units_in_tick und
    time_scale. Die Bildrate ist time_scale / (2 * num_units_in_tick) - der
    Faktor 2 stammt daraus, dass die Norm in Halbbildern ("Feldern")
    rechnet. Alle Felder davor müssen der Reihe nach übersprungen werden,
    sonst liest man an der falschen Stelle.
    """
    if leser.flag():                        # aspect_ratio_info_present_flag
        aspect_ratio_idc = leser.u(8)
        if aspect_ratio_idc == 255:         # Extended_SAR: Werte folgen direkt
            leser.u(16)                     # sar_width
            leser.u(16)                     # sar_height
    if leser.flag():                        # overscan_info_present_flag
        leser.flag()                        # overscan_appropriate_flag
    if leser.flag():                        # video_signal_type_present_flag
        leser.u(3)                          # video_format
        leser.flag()                        # video_full_range_flag
        if leser.flag():                    # colour_description_present_flag
            leser.u(8)                      # colour_primaries
            leser.u(8)                      # transfer_characteristics
            leser.u(8)                      # matrix_coefficients
    if leser.flag():                        # chroma_loc_info_present_flag
        leser.ue()                          # chroma_sample_loc_type_top_field
        leser.ue()                          # chroma_sample_loc_type_bottom_field
    if not leser.flag():                    # timing_info_present_flag
        return None
    num_units_in_tick = leser.u(32)
    time_scale = leser.u(32)
    leser.flag()                            # fixed_frame_rate_flag
    if num_units_in_tick <= 0 or time_scale <= 0:
        return None
    fps = time_scale / (2.0 * num_units_in_tick)
    if not 0.1 <= fps <= 1000.0:
        return None                         # unplausibel -> lieber nichts melden
    return round(fps, 2)


def _sps_h264_lesen(sps: bytes) -> dict | None:
    """Dekodiert eine H.264-SPS und liefert Breite, Höhe, Profil, Bildrate.

    `sps` ist die rohe NAL-Einheit einschließlich Kopfbyte. Rückgabe ist
    None, wenn die Daten keine brauchbare SPS sind.

    Die Reihenfolge der Felder folgt H.264, Abschnitt 7.3.2.1.1. Sie muss
    genau eingehalten werden: ab dem ersten übersehenen Feld ist alles
    Folgende Zufall, weil die Felder keine Bytegrenzen kennen.
    """
    if len(sps) < 4:
        return None

    # --- Kopfbyte der NAL-Einheit ---------------------------------------
    # Bit 0 ist verboten (muss 0 sein), Bit 1-2 die Wichtigkeit, Bit 3-7 der
    # Typ. Typ 7 ist die SPS.
    rohdaten = _startcode_abschneiden(sps)
    if not rohdaten:
        return None
    if rohdaten[0] & 0x80:
        return None                         # verbotenes Bit gesetzt -> kein NAL
    if (rohdaten[0] & 0x1F) != 7:
        return None                         # keine SPS (meist die PPS)

    leser = _BitLeser(_rbsp_entpacken(rohdaten[1:]))
    try:
        profile_idc = leser.u(8)
        # Ein Byte mit sechs constraint_setX_flags und zwei reservierten
        # Bits. Inhalt egal, gelesen werden muss es trotzdem.
        constraint_flags = leser.u(8)
        level_idc = leser.u(8)
        leser.ue()                          # seq_parameter_set_id

        chroma_format_idc = 1               # Vorgabe 4:2:0, wenn nicht kodiert
        separate_colour_plane_flag = 0
        if profile_idc in H264_HOHE_PROFILE:
            # Nur die High-Profile-Familie kodiert das Farbformat explizit.
            chroma_format_idc = leser.ue()
            if chroma_format_idc == 3:      # 4:4:4 kann die Ebenen trennen
                separate_colour_plane_flag = leser.flag()
            leser.ue()                      # bit_depth_luma_minus8
            leser.ue()                      # bit_depth_chroma_minus8
            leser.flag()                    # qpprime_y_zero_transform_bypass_flag
            if leser.flag():                # seq_scaling_matrix_present_flag
                anzahl = 8 if chroma_format_idc != 3 else 12
                for nummer in range(anzahl):
                    if leser.flag():        # seq_scaling_list_present_flag[i]
                        # Die ersten sechs Listen sind 4x4, die übrigen 8x8.
                        _skalierungsliste_ueberspringen(
                            leser, 16 if nummer < 6 else 64
                        )

        leser.ue()                          # log2_max_frame_num_minus4
        pic_order_cnt_type = leser.ue()
        if pic_order_cnt_type == 0:
            leser.ue()                      # log2_max_pic_order_cnt_lsb_minus4
        elif pic_order_cnt_type == 1:
            leser.flag()                    # delta_pic_order_always_zero_flag
            leser.se()                      # offset_for_non_ref_pic
            leser.se()                      # offset_for_top_to_bottom_field
            anzahl = leser.ue()             # num_ref_frames_in_pic_order_cnt_cycle
            if anzahl > 255:
                raise _BitFehler("num_ref_frames_in_pic_order_cnt_cycle zu groß")
            for _ in range(anzahl):
                leser.se()                  # offset_for_ref_frame[i]
        leser.ue()                          # max_num_ref_frames
        leser.flag()                        # gaps_in_frame_num_value_allowed_flag

        # --- Die Bildgröße, gemessen in Makroblöcken (je 16x16 Pixel) ----
        pic_width_in_mbs_minus1 = leser.ue()
        pic_height_in_map_units_minus1 = leser.ue()
        frame_mbs_only_flag = leser.flag()
        if not frame_mbs_only_flag:
            leser.flag()                    # mb_adaptive_frame_field_flag
        leser.flag()                        # direct_8x8_inference_flag

        # --- Beschnitt (frame_cropping) -----------------------------------
        # Die kodierte Fläche ist immer ein Vielfaches von 16 Pixeln. Eine
        # Auflösung wie 1920x1080 passt nicht (1080 / 16 = 67,5), deshalb
        # kodiert die Kamera 1920x1088 und schneidet unten 8 Zeilen weg.
        crop_links = crop_rechts = crop_oben = crop_unten = 0
        if leser.flag():                    # frame_cropping_flag
            crop_links = leser.ue()
            crop_rechts = leser.ue()
            crop_oben = leser.ue()
            crop_unten = leser.ue()

        fps = None
        if leser.flag():                    # vui_parameters_present_flag
            try:
                fps = _vui_fps_lesen(leser)
            except _BitFehler:
                fps = None                  # VUI unbrauchbar, Größe bleibt gültig
    except _BitFehler:
        return None

    # --- Aus Makroblöcken Pixel machen ----------------------------------
    breite = (pic_width_in_mbs_minus1 + 1) * 16
    # Bei Halbbild-Kodierung (frame_mbs_only_flag == 0) beschreibt eine
    # "map unit" nur ein halbes Bild, die Höhe verdoppelt sich also.
    hoehe = (2 - frame_mbs_only_flag) * (pic_height_in_map_units_minus1 + 1) * 16

    # Der Beschnitt wird nicht in Pixeln, sondern in Chroma-Einheiten
    # angegeben. Bei 4:2:0 ist eine Einheit 2 Pixel breit und 2 hoch.
    chroma_array_type = 0 if separate_colour_plane_flag else chroma_format_idc
    if chroma_array_type == 0:              # monochrom oder getrennte Ebenen
        einheit_x = 1
        einheit_y = 2 - frame_mbs_only_flag
    else:
        sub_breite = 2 if chroma_array_type in (1, 2) else 1   # 4:2:0 / 4:2:2
        sub_hoehe = 2 if chroma_array_type == 1 else 1         # nur 4:2:0
        einheit_x = sub_breite
        einheit_y = sub_hoehe * (2 - frame_mbs_only_flag)

    breite -= einheit_x * (crop_links + crop_rechts)
    hoehe -= einheit_y * (crop_oben + crop_unten)
    if breite <= 0 or hoehe <= 0 or breite > 16384 or hoehe > 16384:
        return None                         # Ergebnis unplausibel

    return {
        "breite": int(breite),
        "hoehe": int(hoehe),
        "fps": fps,
        "profil": int(profile_idc),
        "level": round(level_idc / 10.0, 1),
        "constraint": int(constraint_flags),
    }


# --------------------------------------------------------------------------
# 3) H.265/HEVC: SPS dekodieren (soweit ohne großen Aufwand möglich)
# --------------------------------------------------------------------------

def _hevc_profile_tier_level_ueberspringen(
    leser: _BitLeser, max_sub_layers_minus1: int
) -> None:
    """Überliest profile_tier_level() einer HEVC-SPS (H.265, 7.3.3).

    Der Block hat eine feste Länge von 12 Bytes für die Hauptschicht, danach
    folgen optionale Blöcke je Unterschicht. Für die Bildgröße ist nichts
    davon nötig, aber die Länge muss exakt stimmen.
    """
    leser.u(2)                              # general_profile_space
    leser.flag()                            # general_tier_flag
    leser.u(5)                              # general_profile_idc
    leser.u(32)                             # general_profile_compatibility_flag[32]
    # 48 Bit Randbedingungen (progressive/interlaced/... plus Reserve),
    # in zwei Schritten gelesen, weil u() hier bewusst klein bleibt.
    leser.u(24)
    leser.u(24)
    leser.u(8)                              # general_level_idc

    profil_da: list[int] = []
    level_da: list[int] = []
    for _ in range(max_sub_layers_minus1):
        profil_da.append(leser.flag())      # sub_layer_profile_present_flag[i]
        level_da.append(leser.flag())       # sub_layer_level_present_flag[i]
    if max_sub_layers_minus1 > 0:
        for _ in range(max_sub_layers_minus1, 8):
            leser.u(2)                      # reserved_zero_2bits
    for nummer in range(max_sub_layers_minus1):
        if profil_da[nummer]:
            leser.u(32)
            leser.u(32)
            leser.u(24)                     # zusammen 88 Bit wie oben
        if level_da[nummer]:
            leser.u(8)                      # sub_layer_level_idc


def _sps_h265_lesen(sps: bytes) -> dict | None:
    """Dekodiert Breite und Höhe aus einer HEVC-SPS.

    HEVC hat es leichter als H.264: die Größe steht direkt in Pixeln
    (`pic_width_in_luma_samples`), nur ein optionales "conformance window"
    schneidet noch Ränder weg. Davor liegt aber profile_tier_level(), das
    übersprungen werden muss. Klappt das nicht, ist die Rückgabe None -
    das ist kein Fehler, dann wird eben nur der Codec gemeldet.
    """
    rohdaten = _startcode_abschneiden(sps)
    if len(rohdaten) < 12:
        return None
    # HEVC hat ein zwei Byte langes NAL-Kopffeld; der Typ steht in den
    # Bits 1-6 des ersten Bytes. Typ 33 ist die SPS.
    if ((rohdaten[0] >> 1) & 0x3F) != 33:
        return None

    leser = _BitLeser(_rbsp_entpacken(rohdaten[2:]))
    try:
        leser.u(4)                          # sps_video_parameter_set_id
        max_sub_layers_minus1 = leser.u(3)
        leser.flag()                        # sps_temporal_id_nesting_flag
        _hevc_profile_tier_level_ueberspringen(leser, max_sub_layers_minus1)
        leser.ue()                          # sps_seq_parameter_set_id
        chroma_format_idc = leser.ue()
        if chroma_format_idc == 3:
            leser.flag()                    # separate_colour_plane_flag
        breite = leser.ue()                 # pic_width_in_luma_samples
        hoehe = leser.ue()                  # pic_height_in_luma_samples
        if leser.flag():                    # conformance_window_flag
            links = leser.ue()
            rechts = leser.ue()
            oben = leser.ue()
            unten = leser.ue()
            sub_breite = 2 if chroma_format_idc in (1, 2) else 1
            sub_hoehe = 2 if chroma_format_idc == 1 else 1
            breite -= sub_breite * (links + rechts)
            hoehe -= sub_hoehe * (oben + unten)
    except _BitFehler:
        return None
    if breite <= 0 or hoehe <= 0 or breite > 16384 or hoehe > 16384:
        return None
    return {"breite": int(breite), "hoehe": int(hoehe), "fps": None}


# --------------------------------------------------------------------------
# 4) SDP auswerten
# --------------------------------------------------------------------------

def _base64_entpacken(text: str) -> bytes | None:
    """Dekodiert einen Base64-Schnipsel aus dem SDP, notfalls mit Auffüllen.

    Kameras lassen die "="-Auffüllzeichen gern weg, manche benutzen auch das
    URL-Alphabet. Beides wird hier abgefangen.
    """
    text = (text or "").strip().replace("-", "+").replace("_", "/")
    if not text:
        return None
    fehlt = (-len(text)) % 4
    try:
        return base64.b64decode(text + "=" * fehlt, validate=False)
    except (ValueError, TypeError):
        return None


def _fmtp_werte(zeile: str) -> dict:
    """Zerlegt eine `a=fmtp:`-Zeile in ihre Schlüssel-Wert-Paare.

    Beispiel: "a=fmtp:96 packetization-mode=1;sprop-parameter-sets=Z0I...,aM4..."
    """
    werte: dict[str, str] = {}
    _, _, rest = zeile.partition(":")
    _, _, parameter = rest.strip().partition(" ")
    for teil in parameter.split(";"):
        name, trenner, wert = teil.strip().partition("=")
        if trenner:
            werte[name.strip().lower()] = wert.strip()
    return werte


def _codec_name(rtpmap: str | None) -> str:
    """Bringt den Codecnamen aus `a=rtpmap:` auf eine einheitliche Form.

    Aus "a=rtpmap:96 H264/90000" wird "h264", aus "H265" wird "hevc"
    (wie ffprobe es nennt, damit beide Wege dieselben Namen liefern).
    """
    if rtpmap:
        _, _, rest = rtpmap.partition(":")
        _, _, beschreibung = rest.strip().partition(" ")
        name = beschreibung.split("/")[0].strip().lower()
        if name:
            return {"h265": "hevc", "mpeg4-generic": "aac"}.get(name, name)
    return "unbekannt"


def _framerate_aus_sdp(zeilen: list[str]) -> float | None:
    """Liest `a=framerate:25` oder `a=x-framerate: 25` aus dem SDP."""
    for zeile in zeilen:
        treffer = re.match(r"a=(?:x-)?framerate:\s*([0-9]+(?:\.[0-9]+)?)", zeile, re.I)
        if not treffer:
            continue
        try:
            wert = float(treffer.group(1))
        except ValueError:
            continue
        if 0.1 <= wert <= 1000.0:
            return round(wert, 2)
    return None


def sdp_auswerten(sdp: str) -> dict:
    """Zerlegt ein SDP-Dokument in Spuren mit Codec und Auflösung.

    Rückgabe: {"spuren": [...], "codec", "breite", "hoehe", "fps"}, wobei
    die vier Einzelwerte von der ersten Videospur stammen.
    """
    ergebnis: dict = {
        "spuren": [],
        "codec": None,
        "breite": None,
        "hoehe": None,
        "fps": None,
    }
    if not sdp:
        return ergebnis

    zeilen = [z.strip() for z in sdp.replace("\r\n", "\n").split("\n") if z.strip()]

    # Das SDP ist in Abschnitte geteilt: alles vor dem ersten "m=" gilt für
    # die ganze Sitzung, danach beginnt je "m=" eine Medienspur.
    abschnitte: list[list[str]] = []
    aktuell: list[str] | None = None
    for zeile in zeilen:
        if zeile.startswith("m="):
            aktuell = [zeile]
            abschnitte.append(aktuell)
        elif aktuell is not None:
            aktuell.append(zeile)

    # Eine Bildrate im Sitzungsteil gilt für alle Spuren.
    sitzungs_zeilen = zeilen[: len(zeilen) - sum(len(a) for a in abschnitte)]
    sitzungs_fps = _framerate_aus_sdp(sitzungs_zeilen)

    for abschnitt in abschnitte:
        felder = abschnitt[0][2:].split()   # "m=video 0 RTP/AVP 96"
        medienart = (felder[0] if felder else "").lower()
        rtpmap = next((z for z in abschnitt if z.lower().startswith("a=rtpmap:")), None)
        fmtp = next((z for z in abschnitt if z.lower().startswith("a=fmtp:")), None)
        steuerung = next((z for z in abschnitt if z.lower().startswith("a=control:")), None)

        codec = _codec_name(rtpmap)
        spur: dict = {
            "art": medienart if medienart in ("video", "audio") else (medienart or "unbekannt"),
            "codec": codec,
            "breite": None,
            "hoehe": None,
            "fps": None,
            "steuerung": steuerung.partition(":")[2].strip() if steuerung else None,
        }

        if medienart == "video":
            werte = _fmtp_werte(fmtp) if fmtp else {}
            groesse = None
            if codec == "h264":
                # Der Parametersatz enthält kommagetrennt SPS und PPS. Uns
                # interessiert nur die SPS; welcher Teil das ist, sagt das
                # NAL-Kopfbyte - deshalb alle Teile durchprobieren.
                for teil in (werte.get("sprop-parameter-sets") or "").split(","):
                    rohdaten = _base64_entpacken(teil)
                    if rohdaten:
                        groesse = _sps_h264_lesen(rohdaten)
                        if groesse:
                            break
            elif codec in ("hevc", "h265"):
                # Bei HEVC liegen VPS, SPS und PPS in getrennten Feldern.
                for feld in ("sprop-sps", "sprop-vps", "sprop-pps"):
                    for teil in (werte.get(feld) or "").split(","):
                        rohdaten = _base64_entpacken(teil)
                        if rohdaten:
                            groesse = _sps_h265_lesen(rohdaten)
                            if groesse:
                                break
                    if groesse:
                        break

            if groesse:
                spur["breite"] = groesse["breite"]
                spur["hoehe"] = groesse["hoehe"]
                spur["fps"] = groesse.get("fps")
            # Ein `a=framerate` im Abschnitt hat Vorrang vor der
            # VUI-Schätzung: dort meldet die Kamera ihre echte Einstellung.
            aus_sdp = _framerate_aus_sdp(abschnitt) or sitzungs_fps
            if aus_sdp:
                spur["fps"] = aus_sdp

            if ergebnis["codec"] is None:
                ergebnis["codec"] = codec
                ergebnis["breite"] = spur["breite"]
                ergebnis["hoehe"] = spur["hoehe"]
                ergebnis["fps"] = spur["fps"]

        ergebnis["spuren"].append(spur)

    if ergebnis["codec"] is None and ergebnis["spuren"]:
        ergebnis["codec"] = ergebnis["spuren"][0]["codec"]
    return ergebnis


# --------------------------------------------------------------------------
# 5) Anmeldung: Basic und Digest
# --------------------------------------------------------------------------

def _auth_kopf_zerlegen(kopfzeile: str) -> dict:
    """Zerlegt einen `WWW-Authenticate:`-Wert in seine Parameter.

    Aus `Digest realm="AXIS", nonce="abc", qop="auth"` wird
    {"realm": "AXIS", "nonce": "abc", "qop": "auth"}. Werte dürfen in
    Anführungszeichen stehen (dann auch mit Komma darin) oder ohne.
    """
    werte: dict[str, str] = {}
    for name, in_zitat, ohne_zitat in re.findall(
        r'([A-Za-z0-9_-]+)\s*=\s*(?:"([^"]*)"|([^,\s]+))', kopfzeile
    ):
        werte[name.lower()] = in_zitat if in_zitat else ohne_zitat
    return werte


def _basic_kopf_bauen(benutzer: str, passwort: str) -> str:
    """Baut den `Authorization: Basic ...`-Wert (RFC 7617)."""
    return "Basic " + base64.b64encode(
        f"{benutzer}:{passwort}".encode("utf-8")
    ).decode("ascii")


def _digest_kopf_bauen(
    benutzer: str,
    passwort: str,
    methode: str,
    uri: str,
    parameter: dict,
) -> str:
    """Baut den `Authorization: Digest ...`-Wert nach RFC 2617.

    Unterstützt wird MD5 und MD5-sess, mit und ohne qop=auth - mehr
    verlangen Netzwerkkameras in der Praxis nicht. Das Passwort geht
    unverändert in den Hash ein, es darf also beliebige Sonderzeichen
    enthalten (kein Prozent-Kodieren, das würde den Hash verfälschen).
    """
    realm = parameter.get("realm", "")
    nonce = parameter.get("nonce", "")
    opaque = parameter.get("opaque")
    algorithmus = (parameter.get("algorithm") or "MD5").upper()

    def md5(text: str) -> str:
        return hashlib.md5(text.encode("utf-8")).hexdigest()

    # HA1 ist der "Passwortabdruck", HA2 der Abdruck der Anfrage.
    ha1 = md5(f"{benutzer}:{realm}:{passwort}")
    ha2 = md5(f"{methode}:{uri}")

    # qop kann mehrere Werte anbieten ("auth,auth-int"); bedient wird nur
    # "auth", weil "auth-int" den Nachrichtenkörper einbezieht - den hat
    # eine DESCRIBE-Anfrage nicht.
    angebote = [teil.strip().lower() for teil in (parameter.get("qop") or "").split(",")]
    teile = [
        f'username="{benutzer}"',
        f'realm="{realm}"',
        f'nonce="{nonce}"',
        f'uri="{uri}"',
    ]
    if "auth" in angebote:
        cnonce = os.urandom(8).hex()        # eigener Zufall, gegen Wiederholung
        nc = "00000001"                     # je Nonce hochzählen; hier eine Anfrage
        if algorithmus == "MD5-SESS":
            ha1 = md5(f"{ha1}:{nonce}:{cnonce}")
        antwort = md5(f"{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}")
        teile += [f'response="{antwort}"', "qop=auth", f"nc={nc}", f'cnonce="{cnonce}"']
    else:
        antwort = md5(f"{ha1}:{nonce}:{ha2}")
        teile.append(f'response="{antwort}"')
    if parameter.get("algorithm"):
        teile.append(f"algorithm={parameter['algorithm']}")
    if opaque:
        teile.append(f'opaque="{opaque}"')
    return "Digest " + ", ".join(teile)


def _auth_verfahren_waehlen(kopfzeilen: list[str]) -> tuple[str, dict]:
    """Wählt aus den angebotenen Verfahren das stärkste aus.

    Kameras schicken bei 401 oft zwei `WWW-Authenticate`-Zeilen. Digest ist
    Basic immer vorzuziehen, weil das Passwort dabei nicht im Klartext über
    die Leitung geht.
    """
    basic: dict | None = None
    for zeile in kopfzeilen:
        text = zeile.strip()
        if text[:6].lower() == "digest":
            return "digest", _auth_kopf_zerlegen(text[6:])
        if text[:5].lower() == "basic" and basic is None:
            basic = _auth_kopf_zerlegen(text[5:])
    if basic is not None:
        return "basic", basic
    return "keine", {}


# --------------------------------------------------------------------------
# 6) RTSP über TCP sprechen
# --------------------------------------------------------------------------

def rtsp_url(ip: str, pfad: str, port: int = RTSP_PORT) -> str:
    """Baut die RTSP-Adresse ohne Zugangsdaten.

    Zugangsdaten gehören hier absichtlich nicht in die Adresse: sie werden
    als `Authorization`-Kopfzeile geschickt, und genau diese Adresse muss
    auch im Digest-Hash stehen.
    """
    return f"rtsp://{ip}:{int(port)}/{(pfad or '').lstrip('/')}"


class _Antwort:
    """Eine RTSP-Antwort: Statuszahl, Meldung, Kopfzeilen, Körper."""

    __slots__ = ("status", "meldung", "kopf", "koerper")

    def __init__(self, status: int, meldung: str, kopf: dict, koerper: str) -> None:
        self.status = status
        self.meldung = meldung
        self.kopf = kopf                    # Name klein -> Liste der Werte
        self.koerper = koerper


def _kopf_lesen(verbindung: socket.socket, ende: float) -> tuple[bytes, bytes]:
    """Liest bis zur Leerzeile und gibt (Kopfteil, schon gelesener Rest).

    RTSP trennt Kopf und Körper wie HTTP durch eine Leerzeile. Weil TCP
    keine Nachrichtengrenzen kennt, kommt dabei oft schon ein Stück des
    Körpers mit; das wird als zweiter Wert zurückgegeben.
    """
    puffer = b""
    while b"\r\n\r\n" not in puffer and b"\n\n" not in puffer:
        rest = ende - time.monotonic()
        if rest <= 0:
            raise TimeoutError("Zeitgrenze beim Lesen der RTSP-Antwort")
        if len(puffer) > MAX_KOPF:
            raise ValueError("Die Antwort hat einen unplausibel langen Kopf.")
        verbindung.settimeout(rest)
        stueck = verbindung.recv(4096)
        if not stueck:
            if not puffer:
                raise ConnectionError("Die Gegenstelle hat nichts gesendet")
            break
        puffer += stueck
    trenner = b"\r\n\r\n" if b"\r\n\r\n" in puffer else b"\n\n"
    kopf, _, rest_bytes = puffer.partition(trenner)
    return kopf, rest_bytes


def _antwort_lesen(verbindung: socket.socket, ende: float) -> _Antwort:
    """Liest eine vollständige RTSP-Antwort von der Verbindung."""
    kopf_bytes, koerper_bytes = _kopf_lesen(verbindung, ende)
    zeilen = kopf_bytes.decode("utf-8", "replace").replace("\r\n", "\n").split("\n")

    # Erste Zeile: "RTSP/1.0 200 OK"
    treffer = re.match(r"RTSP/\d\.\d\s+(\d{3})\s*(.*)", zeilen[0].strip())
    if not treffer:
        raise ValueError(
            f"Das Gerät antwortet nicht mit RTSP: {zeilen[0][:60]!r}"
        )
    status = int(treffer.group(1))
    meldung = treffer.group(2).strip()

    kopf: dict[str, list[str]] = {}
    for zeile in zeilen[1:]:
        name, trenner, wert = zeile.partition(":")
        if trenner:
            kopf.setdefault(name.strip().lower(), []).append(wert.strip())

    # Körper nachlesen, soweit Content-Length ihn ankündigt.
    laenge = 0
    if kopf.get("content-length"):
        try:
            laenge = max(0, min(MAX_KOERPER, int(kopf["content-length"][0])))
        except ValueError:
            laenge = 0
    while len(koerper_bytes) < laenge:
        rest = ende - time.monotonic()
        if rest <= 0:
            break                           # Zeit um: nehmen, was da ist
        verbindung.settimeout(rest)
        try:
            stueck = verbindung.recv(min(8192, laenge - len(koerper_bytes)))
        except (socket.timeout, TimeoutError):
            break
        if not stueck:
            break
        koerper_bytes += stueck
    return _Antwort(status, meldung, kopf, koerper_bytes.decode("utf-8", "replace"))


def _anfrage_senden(
    verbindung: socket.socket,
    methode: str,
    uri: str,
    cseq: int,
    ende: float,
    zusatz: dict | None = None,
) -> None:
    """Schickt eine RTSP-Anfrage. Der Zeilenabschluss ist immer CRLF."""
    kopf = {"CSeq": str(cseq), "User-Agent": KENNUNG}
    kopf.update(zusatz or {})
    text = f"{methode} {uri} RTSP/1.0\r\n"
    text += "".join(f"{name}: {wert}\r\n" for name, wert in kopf.items())
    text += "\r\n"
    rest = ende - time.monotonic()
    if rest <= 0:
        raise TimeoutError("Zeitgrenze vor dem Senden erreicht")
    verbindung.settimeout(rest)
    verbindung.sendall(text.encode("utf-8"))


def beschreiben(
    ip: str,
    pfad: str,
    benutzer: str = "",
    passwort: str = "",
    port: int = RTSP_PORT,
    timeout: float = 6.0,
) -> dict:
    """Fragt eine Kamera per OPTIONS und DESCRIBE ab.

    Rückgabe ist immer ein Wörterbuch mit denselben Feldern (siehe
    `leeres_ergebnis`). Bei Erfolg stehen Codec und - bei H.264 - die
    Auflösung darin, sonst sagt "fehler" auf Deutsch, was schiefging.

    Verlangt die Kamera eine Anmeldung (Status 401), wird ihr Angebot
    ausgewertet und die Anfrage automatisch mit Basic oder Digest
    wiederholt. Das Feld "auth" sagt hinterher, welches Verfahren die
    Kamera verlangt hat - auch dann, wenn die Anmeldung fehlschlug.

    Es wird nie ein Strom geöffnet (kein SETUP, kein PLAY): die Kamera
    behält damit alle Verbindungen für die eigentliche Anzeige frei.
    """
    ergebnis = leeres_ergebnis()
    ende = time.monotonic() + max(0.5, float(timeout))
    uri = rtsp_url(ip, pfad, port)
    verbindung: socket.socket | None = None

    try:
        verbindung = socket.create_connection(
            (str(ip), int(port)), timeout=max(0.5, ende - time.monotonic())
        )
        # Nagle abschalten: unsere Anfragen sind kurz und sollen sofort raus.
        try:
            verbindung.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

        cseq = 1
        auth_parameter: dict = {}
        verfahren = "keine"

        # --- OPTIONS: prüft, ob überhaupt RTSP gesprochen wird, und holt
        #     bei manchen Kameras schon die Anmeldeaufforderung ------------
        _anfrage_senden(verbindung, "OPTIONS", uri, cseq, ende)
        antwort = _antwort_lesen(verbindung, ende)
        ergebnis["status"] = antwort.status
        if antwort.status == 401:
            verfahren, auth_parameter = _auth_verfahren_waehlen(
                antwort.kopf.get("www-authenticate", [])
            )
            ergebnis["auth"] = verfahren
        elif antwort.status >= 500:
            ergebnis["fehler"] = (
                f"OPTIONS scheiterte: {antwort.status} {antwort.meldung}"
            )
            return ergebnis

        # --- DESCRIBE: liefert das SDP mit Codec und Parametersatz -------
        for versuch in range(2):
            cseq += 1
            zusatz = {"Accept": "application/sdp"}
            if benutzer and verfahren == "digest":
                zusatz["Authorization"] = _digest_kopf_bauen(
                    benutzer, passwort, "DESCRIBE", uri, auth_parameter
                )
            elif benutzer and verfahren == "basic":
                zusatz["Authorization"] = _basic_kopf_bauen(benutzer, passwort)

            _anfrage_senden(verbindung, "DESCRIBE", uri, cseq, ende, zusatz)
            antwort = _antwort_lesen(verbindung, ende)
            ergebnis["status"] = antwort.status
            if antwort.status != 401:
                break

            # 401 nach DESCRIBE: entweder verlangte OPTIONS noch nichts,
            # oder die Nonce ist abgelaufen. Einmal neu versuchen.
            neues_verfahren, neue_parameter = _auth_verfahren_waehlen(
                antwort.kopf.get("www-authenticate", [])
            )
            if neues_verfahren != "keine":
                verfahren, auth_parameter = neues_verfahren, neue_parameter
                ergebnis["auth"] = verfahren
            if versuch == 1 or not benutzer:
                break

        if antwort.status == 401:
            ergebnis["fehler"] = (
                "Die Zugangsdaten wurden abgelehnt (401)."
                if benutzer
                else "Die Kamera verlangt Zugangsdaten (401)."
            )
            return ergebnis
        if antwort.status == 404:
            ergebnis["fehler"] = f"Der Pfad {pfad!r} ist unbekannt (404)."
            return ergebnis
        if antwort.status != 200:
            ergebnis["fehler"] = (
                f"DESCRIBE scheiterte: {antwort.status} {antwort.meldung}"
            )
            return ergebnis

        sdp = antwort.koerper or ""
        ergebnis["sdp"] = sdp
        if "m=" not in sdp:
            ergebnis["fehler"] = "Die Antwort enthält kein SDP."
            return ergebnis

        ausgewertet = sdp_auswerten(sdp)
        ergebnis["spuren"] = ausgewertet["spuren"]
        ergebnis["codec"] = ausgewertet["codec"]
        ergebnis["breite"] = ausgewertet["breite"]
        ergebnis["hoehe"] = ausgewertet["hoehe"]
        ergebnis["fps"] = ausgewertet["fps"]
        ergebnis["erfolg"] = any(spur["art"] == "video" for spur in ergebnis["spuren"])
        if not ergebnis["erfolg"]:
            ergebnis["fehler"] = "Das SDP enthält keine Videospur."
        return ergebnis

    except (socket.timeout, TimeoutError):
        ergebnis["fehler"] = f"Zeitgrenze von {float(timeout):.0f} s überschritten."
        return ergebnis
    except (ConnectionError, OSError) as fehler:
        ergebnis["fehler"] = f"Keine Verbindung zu {ip}:{port} ({fehler})."
        return ergebnis
    except ValueError as fehler:
        ergebnis["fehler"] = str(fehler)
        return ergebnis
    finally:
        # Sauber verabschieden, damit die Kamera die Sitzung sofort freigibt.
        if verbindung is not None:
            try:
                verbindung.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                verbindung.close()
            except OSError:
                pass


# --------------------------------------------------------------------------
# 7) Viele Pfade und Zugangsdaten durchprobieren
# --------------------------------------------------------------------------

def _zugangsliste(zugangsdaten: list[dict] | None) -> list[tuple[str, str]]:
    """Normiert die Zugangsdaten. Leere Liste heißt: ohne Anmeldung probieren."""
    liste: list[tuple[str, str]] = []
    for satz in zugangsdaten or []:
        if not isinstance(satz, dict):
            continue
        paar = (str(satz.get("benutzer") or ""), str(satz.get("passwort") or ""))
        if paar not in liste:
            liste.append(paar)
    if not liste:
        liste.append(("", ""))
    return liste


def _flaeche(eintrag: dict) -> int:
    """Bildfläche in Pixeln - Sortierschlüssel für "Hauptstrom zuerst"."""
    return int(eintrag.get("breite") or 0) * int(eintrag.get("hoehe") or 0)


def pfade_testen(
    ip: str,
    pfade: list[str],
    zugangsdaten: list[dict],
    port: int = RTSP_PORT,
    timeout: float = 5.0,
) -> list[dict]:
    """Probiert Pfade mit Zugangsdaten durch und liefert alle Treffer.

    Die Reihenfolge ist bewusst "erst alle Pfade mit dem ersten
    Zugangsdatensatz": stimmen die ersten Zugangsdaten, sind nach einem
    Durchgang alle Ströme gefunden. Abgebrochen wird nicht beim ersten
    Treffer, weil eine Kamera meist einen großen Haupt- und einen kleinen
    Nebenstrom hat und beide bekannt sein sollen.

    Gearbeitet wird mit höchstens `MAX_THREADS` gleichzeitigen Verbindungen.
    Die Gesamtlaufzeit ist gedeckelt: was bis dahin nicht dran war, fällt
    weg. Sortiert wird nach Bildfläche absteigend, der Hauptstrom steht
    also vorn.
    """
    einzel_timeout = max(1.0, float(timeout))
    # Gesamtdeckel: eine Gruppe (alle Pfade eines Zugangsdatensatzes) läuft
    # parallel, deshalb genügt ein kleines Vielfaches der Einzelzeit.
    gesamt_ende = time.monotonic() + einzel_timeout * 4 + 2.0

    saubere_pfade: list[str] = []
    for pfad in pfade or []:
        text = str(pfad).lstrip("/")
        if text not in saubere_pfade:
            saubere_pfade.append(text)
    if not saubere_pfade:
        return []

    treffer: list[dict] = []
    gesehen: set[str] = set()               # Pfade, die schon einen Treffer haben

    def einen_pruefen(auftrag: tuple[str, str, str]) -> dict | None:
        pfad, benutzer, passwort = auftrag
        rest = gesamt_ende - time.monotonic()
        if rest <= 0.5:
            return None                     # Zeitdeckel erreicht
        try:
            ergebnis = beschreiben(
                ip, pfad, benutzer, passwort, port=port, timeout=min(einzel_timeout, rest)
            )
        except Exception:                   # noqa: BLE001
            # Ein einzelner Pfad darf die ganze Prüfung nicht abbrechen:
            # pool.map würde die Ausnahme sonst an den Aufrufer weiterreichen.
            return None
        if not ergebnis["erfolg"]:
            return None
        return {
            "pfad": pfad,
            "benutzer": benutzer,
            "passwort": passwort,
            "codec": ergebnis["codec"],
            "breite": ergebnis["breite"],
            "hoehe": ergebnis["hoehe"],
            "fps": ergebnis["fps"],
        }

    arbeiter = max(1, min(MAX_THREADS, len(saubere_pfade)))
    with ThreadPoolExecutor(max_workers=arbeiter) as pool:
        for benutzer, passwort in _zugangsliste(zugangsdaten):
            if time.monotonic() >= gesamt_ende - 0.5:
                break
            # Pfade, die mit früheren Zugangsdaten schon liefen, nicht erneut.
            auftraege = [
                (pfad, benutzer, passwort)
                for pfad in saubere_pfade
                if pfad not in gesehen
            ]
            if not auftraege:
                break
            for ergebnis in pool.map(einen_pruefen, auftraege):
                if ergebnis and ergebnis["pfad"] not in gesehen:
                    gesehen.add(ergebnis["pfad"])
                    treffer.append(ergebnis)

    treffer.sort(key=_flaeche, reverse=True)
    return treffer


# --------------------------------------------------------------------------
# Selbsttest von der Kommandozeile
# --------------------------------------------------------------------------

def _hauptprogramm(argumente: list[str]) -> int:
    """Prüft eine Kamera von der Kommandozeile und gibt eine Tabelle aus."""
    if not argumente:
        print("Aufruf: python -m app.rtsp <ip> [benutzer] [passwort] [pfad ...]")
        print('Beispiel: python -m app.rtsp 192.168.1.2 admin "GeheimesPasswort!23"')
        return 2

    # Die Windows-Konsole kann nicht immer Umlaute; lieber ersetzen als den
    # Selbsttest daran scheitern lassen.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError, ValueError):
        pass

    ip = argumente[0]
    benutzer = argumente[1] if len(argumente) > 1 else ""
    passwort = argumente[2] if len(argumente) > 2 else ""
    pfade = argumente[3:] or [
        "stream1", "stream2", "live.sdp", "h264", "Streaming/Channels/101",
    ]

    print(f"Kamera {ip}, Benutzer {benutzer or '(ohne)'}")
    print()
    print(
        f"{'Pfad':<28}{'Status':<8}{'Auth':<9}{'Codec':<8}"
        f"{'Auflösung':<13}{'fps':<7}Hinweis"
    )
    print("-" * 100)
    beginn = time.monotonic()
    for pfad in pfade:
        ergebnis = beschreiben(ip, pfad, benutzer, passwort)
        aufloesung = (
            f"{ergebnis['breite']}x{ergebnis['hoehe']}"
            if ergebnis["breite"] and ergebnis["hoehe"]
            else "-"
        )
        print(
            f"{pfad[:27]:<28}{ergebnis['status']:<8}{ergebnis['auth']:<9}"
            f"{(ergebnis['codec'] or '-'):<8}{aufloesung:<13}"
            f"{(str(ergebnis['fps']) if ergebnis['fps'] else '-'):<7}"
            f"{ergebnis['fehler'] or 'in Ordnung'}"
        )

    print()
    print("pfade_testen() - alle gefundenen Ströme, größter zuerst:")
    funde = pfade_testen(ip, pfade, [{"benutzer": benutzer, "passwort": passwort}])
    if not funde:
        print("  (kein Strom gefunden)")
    for fund in funde:
        print(
            f"  {fund['pfad']:<28}{(fund['codec'] or '-'):<8}"
            f"{fund['breite']}x{fund['hoehe']}  {fund['fps'] or '-'} fps"
        )
    print(f"\nDauer: {time.monotonic() - beginn:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(_hauptprogramm(sys.argv[1:]))
