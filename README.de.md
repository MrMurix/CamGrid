# CamGrid

**Viele Kameras, mehrere Monitore, eine Weboberfläche.** CamGrid macht aus
einem Raspberry Pi (oder jedem anderen Rechner) eine Video-Wand: Kameras im Netz
suchen, per Ziehen auf Monitore und Raster verteilen, fertig. Kein Abo, keine
Cloud, kein Konto — alles läuft im eigenen Netz.

![Das Raster im Dashboard](docs/bilder/raster-dunkel.png)

*English documentation: [README.md](README.md)*

---

## Was es kann

- **Kameras finden** — Netzbereich eingeben, der Rest geht von selbst: ONVIF-Suche,
  Portprüfung, die üblichen RTSP-Pfade werden durchprobiert. Auflösung, Codec und
  Stream-Pfad stehen danach fest. Oder von Hand: IP eintragen, CamGrid prüft den
  Rest selbst.
- **Auch Kameras ohne RTSP** — ältere Modelle (etwa klassische Mobotix) liefern
  MJPEG über HTTP. Das erkennt die Suche und spielt es ab.
- **Raster frei bauen** — beliebig viele Monitore, Raster von 1×1 bis 6×6,
  Kacheln über mehrere Felder ziehen. Die Vorschau zeigt vorab, wie es auf dem
  Bildschirm aussieht.
- **Bedienen ohne Handbuch** — Ziehen oder Antippen, Vorschaubilder überall,
  Rückgängig, gespeichert wird erst auf Knopfdruck.
- **Läuft von allein** — Dienste starten mit dem System, eine Überwachung startet
  leere oder abgestürzte Anzeigefenster automatisch neu.
- **Ohne Fremdsoftware** — kein Docker, keine Datenbank, keine Python-Pakete.
  go2rtc liegt fertig im Projekt.

| Kameras verwalten | Kamerasuche |
|---|---|
| ![Kameras](docs/bilder/kameras-dunkel.png) | ![Suche](docs/bilder/suche-dunkel.png) |

## Installation

### Raspberry Pi und andere Linux-Rechner

```sh
git clone https://github.com/MrMurix/CamGrid.git
cd camgrid && sudo ./install.sh
```

Oder alles in einem Befehl:

```sh
curl -fsSL https://raw.githubusercontent.com/MrMurix/CamGrid/main/netz-installation.sh | sudo sh
```

Das Skript installiert fehlende Pakete (apt, dnf und pacman macht es selbst),
richtet die Dienste ein und öffnet die Anzeige nach dem nächsten Login von
selbst. go2rtc liegt im Projekt — es wird nichts nachgeladen.

Nützliche Schalter: `--user NAME` (Benutzer der grafischen Sitzung),
`--no-kiosk` (nur Server, keine Anzeige), `--port N` (Port des Dashboards),
`--dry-run` (zeigt nur, was passieren würde), `--version`.
Entfernen: `sudo ./uninstall.sh`.

### Windows

```powershell
git clone https://github.com/MrMurix/CamGrid.git
cd camgrid
powershell -ExecutionPolicy Bypass -File install.ps1
```

Braucht keine Administratorrechte. Entfernen: `-Uninstall`.

### macOS

```sh
git clone https://github.com/MrMurix/CamGrid.git
cd camgrid && sudo ./install.sh
```

Die Dienste laufen über launchd. Eine Kiosk-Anzeige richtet das Skript hier
nicht ein — die Anzeigeseite lässt sich im Browser im Vollbild öffnen.

### Nur ausprobieren, nichts installieren

```sh
./start-lokal.sh      # Linux und macOS
start-lokal.cmd       # Windows
```

Danach: **http://127.0.0.1:8080**. Wer nur die Oberfläche anschauen will, startet
`python3 demo.py` — das legt eine Beispielanlage mit erfundenen Kameras an
(eigene Ports, stört eine laufende Installation nicht).

## Erste Schritte

1. Dashboard öffnen: `http://<adresse-des-geräts>:8080`
   Anmeldung: **admin / camgrid** — bitte sofort unter *Einstellungen → Zugang*
   ändern. Das Dashboard weist darauf hin, bis es geändert ist.
2. **Kamerasuche**: Netzbereich (z. B. `192.168.1.0/24`) und Kamerapasswort
   eintragen, suchen, gefundene Kameras übernehmen.
3. **Monitore & Raster**: Raster wählen, Kameras in die Kacheln ziehen, **Speichern**.
4. Die Monitore übernehmen die Änderung innerhalb von 15 Sekunden von selbst.

Die Anzeigeseite eines Monitors liegt unter `http://<adresse>:1984/?monitor=1`
(Monitor 2 entsprechend mit `?monitor=2`).

## Voraussetzungen

- Python 3.11 oder neuer (auf Raspberry Pi OS und den meisten Linux-Systemen dabei)
- Für die Anzeige am Gerät: Chromium und ein laufender Desktop
- Kameras mit RTSP (praktisch jede IP-Kamera); ONVIF hilft beim Finden, ist aber
  nicht nötig
- `ffmpeg` ist **optional** — Auflösung und Vorschaubild gehen auch ohne

## Aufbau

| Teil | Aufgabe |
|---|---|
| `app/server.py` | Dashboard und JSON-Schnittstelle (Port 8080) |
| `app/config.py` | Konfiguration lesen, prüfen, speichern |
| `app/scan.py` | Kamerasuche im Netz (ONVIF, Ports, Hersteller über MAC) |
| `app/rtsp.py` | RTSP-Prüfung in reinem Python: Auflösung und Codec ohne ffmpeg |
| `app/kamerabild.py` | Vorschaubild direkt von der Kamera (HTTP, Digest-Anmeldung) |
| `app/dienst.py` | startet und überwacht go2rtc, wenn keine Dienstverwaltung da ist |
| `app/streams.py` | erzeugt `go2rtc.yaml` und `anzeige.json` aus der Konfiguration |
| `app/kioskinfo.py` | Monitorangaben für das Kiosk-Skript |
| `web/admin/` | das Dashboard |
| `web/public/` | die Anzeigeseite für die Monitore |
| `vendor/go2rtc/` | mitgeliefertes go2rtc für ARM64, ARM, x86-64 und Windows |
| `scripts/kiosk.sh` | öffnet die Fenster und überwacht sie dauerhaft |
| `install.sh`, `install.ps1`, `netz-installation.sh` | Einrichtung je Betriebssystem |
| `test/` | Selbsttests: Schnittstelle, Browser, Anzeigeseite, echte Kameras |

**Streaming** übernimmt [go2rtc](https://github.com/AlexxIT/go2rtc): Es holt die
RTSP-Ströme und liefert sie als Video an den Browser, dazu die Anzeigeseite auf
Port 1984. Die Kameras werden nie direkt vom Browser angesprochen.

Es gibt **eine Quelle der Wahrheit**: `config.json`. Alles andere
(`go2rtc.yaml`, `anzeige.json`) wird daraus erzeugt — diese Dateien von Hand zu
ändern hat keinen Sinn.

| Pfad (Linux) | Inhalt |
|---|---|
| `/opt/camgrid` | Programmdateien |
| `/etc/camgrid/config.json` | die Konfiguration (Rechte 600, enthält Passwörter) |
| `/var/lib/camgrid/go2rtc.yaml` | erzeugt, nicht bearbeiten |
| `/var/log/camgrid/kiosk.log` | Protokoll der Anzeige |

Unter Windows liegt die Konfiguration in `%LOCALAPPDATA%\CamGrid`.

## Befehle

```sh
systemctl status camgrid-admin camgrid-go2rtc   # laufen die Dienste?
sudo systemctl restart camgrid-go2rtc              # Streams neu starten
/opt/camgrid/scripts/kiosk.sh --neustart           # Anzeigefenster neu öffnen
tail -20 /var/log/camgrid/kiosk.log                # was die Überwachung tat
journalctl -u camgrid-admin -n 50                  # Fehler des Dashboards
python3 -m app.scan 192.168.1.0/24 admin:passwort     # Kamerasuche ohne Dashboard
```

## Selbst prüfen

```sh
python3 test/test_server.py                              # Schnittstelle, ohne Kameras
python3 test/browsertest.py                              # klickt und zieht im Dashboard
python3 test/echttest.py 192.168.1.0/24 admin passwort   # gegen echte Kameras
python3 test/anzeigetest.py                              # Anzeigeseite: läuft Video?
```

Der Browsertest steuert Chrome oder Edge im Hintergrund, erwartet ein laufendes
`start-lokal` und holt sich die Anmeldedaten aus `test/lokal/config.json`.

## Wenn etwas nicht geht

| Problem | Ursache und Abhilfe |
|---|---|
| Kamera gefunden, aber „kein Video" | Benutzer, Passwort oder Stream-Pfad stimmen nicht. In der Kameraliste auf **Prüfen** — dort steht, was gefunden wurde. |
| Kamera antwortet, aber Port 554 ist zu | Dann kann sie kein RTSP. CamGrid sucht in dem Fall einen MJPEG-Strom über HTTP; klappt das nicht, im Seitenfenster unter **Vollständige Adresse** die Stream-Adresse der Kamera eintragen. |
| Bild grün oder lila | Chromium braucht `--use-angle=gl`; `scripts/kiosk.sh` setzt das. Bei eigenem Start ergänzen. |
| Monitore bleiben weiß | `tail /var/log/camgrid/kiosk.log`. Die Überwachung startet leere Fenster nach spätestens einer Minute neu. |
| Anzeige ruckelt | Nebenstrom statt Hauptstrom verwenden (die Suche schlägt ihn vor), Monitore auf 1920×1080 bei 60 Hz stellen. |
| „antwortet nicht" trotz Bild | Der Zustand wird über Port 554 geprüft. Kameras mit RTSP auf einem anderen Port melden sich hier nicht. |
| Dashboard fragt ständig nach dem Passwort | Nach dem Ändern der Zugangsdaten meldet sich der Browser neu an — einmal die Seite neu laden. |

## Erfahrungen, die in diesem Projekt stecken

Diese Punkte haben im Vorgängerprojekt Zeit gekostet und sind hier fest eingebaut:

- **Chromium braucht `--use-angle=gl`.** Mit der Voreinstellung `gles` sind die
  Videobilder grün/lila verfärbt.
- **4K nur mit 30 Hz.** Die Monitore laufen deshalb standardmäßig mit 1920×1080
  bei 60 Hz; das Bild wird dadurch nicht schlechter, weil die Kamerabilder
  kleiner sind, aber der Rechner wird deutlich entlastet.
- **Nach dem Booten 15 Sekunden warten.** Startet Chromium zu früh, hängt es auf
  langsamen SD-Karten in der Warteschlange der Festplatte und zeigt ein leeres
  weißes Fenster.
- **`exit_type` zurücksetzen.** Nach hartem Ausschalten meint Chromium, es sei
  abgestürzt, und startet mit leerem Fenster.
- **Zeitstempel an der Adresse.** Sonst zeigt Chromium nach einer Änderung noch
  die alte Seite aus dem Zwischenspeicher.
- **Nebenstrom statt Hauptstrom.** Acht 5-Megapixel-Ströme überlasten einen Pi 5;
  mit dem kleineren Strom liegt er bei etwa der Hälfte.
- **Überwachung mit echtem Kriterium.** Ein laufender Chromium-Prozess heißt
  nicht, dass ein Bild zu sehen ist. Geprüft wird, ob die Seite wirklich
  Verbindungen zum Streaming-Dienst hält.
- **Schlüsselbund entsperren.** Sonst steht auf einem Gerät ohne Tastatur ein
  Passwortfenster im Weg.
- **Kein ffmpeg nötig.** Auflösung und Codec liest `app/rtsp.py` direkt aus dem
  Stream, das Vorschaubild kommt über die Schnappschuss-Adresse der Kamera.

## Sicherheit

- Voreinstellung ist **admin / camgrid**. Bitte beim ersten Start ändern.
- Kamerapasswörter stehen nur in `config.json` und `go2rtc.yaml` (beide 600).
  Die Anzeigeseite bekommt weder Passwörter noch Kamera-IP-Adressen.
- Alles läuft über HTTP im lokalen Netz. Für einen Zugriff von außen gehört ein
  VPN davor — bitte keine Ports ins Internet freigeben.

## Mitmachen

Fehlerberichte und Verbesserungen sind willkommen. Vor einem Pull Request bitte
`python3 test/test_server.py` und, wenn die Oberfläche betroffen ist,
`python3 test/browsertest.py` laufen lassen.

## Lizenz

MIT — siehe [LICENSE](LICENSE). Enthält [go2rtc](https://github.com/AlexxIT/go2rtc)
(ebenfalls MIT).
