# CamGrid - Installation unter Windows
#
# Richtet die Konfiguration und den Autostart ein. Es werden keine
# Adminrechte benoetigt: ohne Adminrechte liegt die Konfiguration unter
# %LOCALAPPDATA%\CamGrid, mit Adminrechten unter %ProgramData%\CamGrid.
#
# Aufruf (PowerShell 5.1 oder neuer):
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Port 8090
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# Alle Meldungen sind auf Deutsch, die Datei selbst bewusst ohne Umlaute,
# damit sie unabhaengig von der Zeichensatzeinstellung lesbar bleibt.

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$NoAutostart,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Feste Startzugangsdaten - muessen nach dem ersten Anmelden geaendert werden.
$StandardBenutzer = 'admin'
$StandardPasswort = 'camgrid'
$AnzeigePort      = 1984
$Aufgabenname     = 'CamGrid'
$Projekt          = $PSScriptRoot
if (-not $Projekt) { $Projekt = (Get-Location).Path }

# ------------------------------------------------------------------ Ausgaben -

function Meldung($text)  { Write-Host "[camgrid] $text" }
function Warnung($text)  { Write-Host "[camgrid] Warnung: $text" -ForegroundColor Yellow }
function Fehler($text) {
    Write-Host "[camgrid] Fehler: $text" -ForegroundColor Red
    exit 1
}

function Projektversion {
    $datei = Join-Path $Projekt 'VERSION'
    if (Test-Path $datei) {
        $wert = (Get-Content $datei -TotalCount 1).Trim()
        if ($wert) { return $wert }
    }
    return 'unbekannt'
}

function Hilfe {
    $v = Projektversion
    Write-Host @"
CamGrid - Installation unter Windows (Version $v)

Aufruf:
  powershell -ExecutionPolicy Bypass -File install.ps1 [Optionen]

Optionen:
  -Port N        Port der Verwaltung (Standard: 8080)
  -NoAutostart   Keine geplante Aufgabe fuer den Autostart anlegen
  -DryRun        Nur anzeigen, was getan wuerde - aendert nichts
  -Uninstall     Autostart entfernen und nach der Konfiguration fragen
  -Help          Diese Hilfe anzeigen

Was das Skript tut:
  1. Python 3 pruefen (Hinweis auf 'winget install Python.Python.3.12', falls es fehlt)
  2. Konfiguration anlegen, falls noch keine vorhanden ist (wird nie ueberschrieben)
  3. Autostart als geplante Aufgabe 'CamGrid' bei der Anmeldung einrichten
  4. Adressen und Zugangsdaten ausgeben

Adminrechte sind nicht notwendig. Ohne Adminrechte liegen Konfiguration und
Protokolle unter %LOCALAPPDATA%\CamGrid, mit Adminrechten unter
%ProgramData%\CamGrid.

Zum Ausprobieren ohne Installation: start-lokal.cmd
"@
}

if ($Help) { Hilfe; exit 0 }

# --------------------------------------------------------------- Umgebung ----

function IstAdmin {
    $kennung = [Security.Principal.WindowsIdentity]::GetCurrent()
    $rolle = New-Object Security.Principal.WindowsPrincipal($kennung)
    return $rolle.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Datenverzeichnis {
    if (IstAdmin) {
        return (Join-Path $env:ProgramData 'CamGrid')
    }
    return (Join-Path $env:LOCALAPPDATA 'CamGrid')
}

# Sucht Python 3. Rueckgabe: Objekt mit Python (python.exe) und Pythonw.
function FindePython {
    $kandidaten = @()
    foreach ($name in 'py','python','python3') {
        $befehl = Get-Command $name -ErrorAction SilentlyContinue
        if ($befehl) { $kandidaten += $befehl.Source }
    }
    foreach ($pfad in $kandidaten) {
        $ausgabe = $null
        try {
            if ([IO.Path]::GetFileNameWithoutExtension($pfad) -eq 'py') {
                $ausgabe = & $pfad -3 -c "import sys; print(sys.executable); print(sys.version_info[0])"
            } else {
                $ausgabe = & $pfad -c "import sys; print(sys.executable); print(sys.version_info[0])"
            }
        } catch {
            $ausgabe = $null
        }
        if ($LASTEXITCODE -ne 0) { $ausgabe = $null }
        if ($ausgabe -and $ausgabe.Count -ge 2 -and $ausgabe[1].Trim() -eq '3') {
            $exe = $ausgabe[0].Trim()
            if (Test-Path $exe) {
                $ordner = Split-Path $exe -Parent
                $fensterlos = Join-Path $ordner 'pythonw.exe'
                if (-not (Test-Path $fensterlos)) { $fensterlos = $exe }
                return [pscustomobject]@{ Python = $exe; Pythonw = $fensterlos }
            }
        }
    }
    return $null
}

function PythonHinweis {
    Warnung 'Python 3 wurde nicht gefunden.'
    Meldung 'Installation zum Beispiel so:'
    Meldung '  winget install Python.Python.3.12'
    Meldung 'Alternativ von https://www.python.org/downloads/windows/ laden und'
    Meldung 'dabei "Add python.exe to PATH" ankreuzen. Danach install.ps1 erneut starten.'
}

function EigeneIpAdresse {
    try {
        $adressen = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName())
        foreach ($a in $adressen) {
            if ($a.AddressFamily -eq 'InterNetwork' -and -not $a.ToString().StartsWith('127.')) {
                return $a.ToString()
            }
        }
    } catch {
        # Ohne Netzwerk bleibt es beim Platzhalter.
    }
    return '<ip-adresse>'
}

# ----------------------------------------------------------- Konfiguration ---

# Erzeugt die Startkonfiguration mit app/config.py. Eine vorhandene Datei
# wird niemals angefasst.
function ErzeugeKonfiguration($python, $ziel, $port) {
    $skript = Join-Path $env:TEMP 'camgrid-konfig.py'
    $inhalt = @'
import json, os, sys

projekt, ziel, adminport, anzeigeport, benutzer, passwort = sys.argv[1:7]
adminport, anzeigeport = int(adminport), int(anzeigeport)
sys.path.insert(0, projekt)

try:
    from app import config as konfig
    daten = konfig.standard_konfiguration()
except Exception as fehler:                      # Notfall: Minimalfassung
    print("Hinweis: app/config.py nicht nutzbar (%s) - Minimalfassung." % fehler)
    daten = {
        "version": 1,
        "anlage": {"name": "CamGrid"},
        "anzeige": {"aufloesung": "1920x1080", "bildrate": 60, "rand": True,
                    "beschriftung": True, "abstand": 14, "hintergrund": "#0e1116"},
        "monitore": [{"id": 1, "name": "Monitor 1", "ausgang": "",
                      "spalten": 2, "zeilen": 2, "kacheln": []}],
        "kameras": [],
        "zugang": {"admin_benutzer": benutzer, "admin_passwort": passwort,
                   "anzeige_benutzer": "anzeige", "anzeige_passwort": ""},
        "scan": {"netz": "", "zugangsdaten": [{"benutzer": "admin", "passwort": ""}]},
        "dienste": {"go2rtc_port": anzeigeport, "admin_port": adminport},
    }

daten["dienste"]["admin_port"] = adminport
daten["dienste"]["go2rtc_port"] = anzeigeport
daten["kameras"] = []
daten.setdefault("zugang", {})
daten["zugang"]["admin_benutzer"] = benutzer
daten["zugang"]["admin_passwort"] = passwort

os.makedirs(os.path.dirname(ziel), exist_ok=True)
with open(ziel, "w", encoding="utf-8") as datei:
    json.dump(daten, datei, indent=2, ensure_ascii=False)
    datei.write("\n")
print("Konfiguration geschrieben: %s" % ziel)
'@
    Set-Content -Path $skript -Value $inhalt -Encoding UTF8
    try {
        $ausgabe = & $python $skript $Projekt $ziel $port $AnzeigePort $StandardBenutzer $StandardPasswort
        if ($LASTEXITCODE -ne 0) {
            Warnung 'Die Konfiguration konnte nicht erzeugt werden.'
            foreach ($zeile in $ausgabe) { Warnung $zeile }
            return $false
        }
        foreach ($zeile in $ausgabe) { Meldung $zeile }
        return $true
    } finally {
        Remove-Item $skript -Force -ErrorAction SilentlyContinue
    }
}

# Liest einen Zahlenwert aus der Konfiguration, ohne Python zu starten.
function LiesPort($datei, $schluessel, $ersatz) {
    if (-not (Test-Path $datei)) { return $ersatz }
    try {
        $daten = Get-Content $datei -Raw | ConvertFrom-Json
        $wert = $daten.dienste.$schluessel
        if ($wert) { return [int]$wert }
    } catch {
        Warnung "Konfiguration $datei ist nicht lesbar - es gilt $ersatz."
    }
    return $ersatz
}

# -------------------------------------------------------------- Autostart ----

function StartVerknuepfung {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'CamGrid.lnk')
}

# Reihenfolge: geplante Aufgabe (bevorzugt), dann schtasks, dann als letzter
# Ausweg eine Verknuepfung im Autostart-Ordner. So klappt es auch dort, wo
# geplante Aufgaben gesperrt sind.
function RichteAutostartEin($pythonw, $konfigdatei, $port) {
    $argumente = '"{0}\app\dienst.py" --mit-server --config "{1}" --port {2}' -f $Projekt, $konfigdatei, $port

    try {
        $aktion = New-ScheduledTaskAction -Execute $pythonw -Argument $argumente -WorkingDirectory $Projekt
        $ausloeser = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
        $einstellungen = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $Aufgabenname -Action $aktion -Trigger $ausloeser `
            -Settings $einstellungen -Description 'Startet CamGrid bei der Anmeldung.' `
            -Force -ErrorAction Stop | Out-Null
        Meldung "Autostart eingerichtet: geplante Aufgabe '$Aufgabenname' (bei der Anmeldung)."
        return 'aufgabe'
    } catch {
        Warnung ("Geplante Aufgabe nicht moeglich: " + $_.Exception.Message)
    }

    $befehlszeile = '"{0}" {1}' -f $pythonw, $argumente
    & schtasks /Create /TN $Aufgabenname /TR $befehlszeile /SC ONLOGON /RL LIMITED /F 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Meldung "Autostart eingerichtet: geplante Aufgabe '$Aufgabenname' (ueber schtasks)."
        return 'aufgabe'
    }
    Warnung 'Auch schtasks war nicht erfolgreich - es wird der Autostart-Ordner verwendet.'

    try {
        $verknuepfung = StartVerknuepfung
        $schale = New-Object -ComObject WScript.Shell
        $ziel = $schale.CreateShortcut($verknuepfung)
        $ziel.TargetPath = $pythonw
        $ziel.Arguments = $argumente
        $ziel.WorkingDirectory = $Projekt
        $ziel.Description = 'Startet CamGrid bei der Anmeldung.'
        $ziel.Save()
        Meldung "Autostart eingerichtet: $verknuepfung"
        return 'verknuepfung'
    } catch {
        Warnung ("Autostart konnte nicht eingerichtet werden: " + $_.Exception.Message)
        return 'keiner'
    }
}

function EntferneAutostart {
    $entfernt = $false
    try {
        $vorhanden = Get-ScheduledTask -TaskName $Aufgabenname -ErrorAction SilentlyContinue
        if ($vorhanden) {
            Unregister-ScheduledTask -TaskName $Aufgabenname -Confirm:$false -ErrorAction Stop
            Meldung "Geplante Aufgabe '$Aufgabenname' entfernt."
            $entfernt = $true
        }
    } catch {
        Warnung ("Geplante Aufgabe liess sich nicht entfernen: " + $_.Exception.Message)
    }
    # Nur wenn es das Cmdlet nicht gibt, ueber schtasks nachsehen - sonst
    # meldet schtasks bei jedem Lauf ohne Aufgabe eine Fehlerzeile.
    if (-not $entfernt -and -not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        & cmd /c "schtasks /Query /TN ""$Aufgabenname"" >nul 2>&1"
        if ($LASTEXITCODE -eq 0) {
            & cmd /c "schtasks /Delete /TN ""$Aufgabenname"" /F >nul 2>&1"
            if ($LASTEXITCODE -eq 0) {
                Meldung "Geplante Aufgabe '$Aufgabenname' entfernt (ueber schtasks)."
                $entfernt = $true
            }
        }
    }
    $verknuepfung = StartVerknuepfung
    if (Test-Path $verknuepfung) {
        Remove-Item $verknuepfung -Force
        Meldung "Entfernt: $verknuepfung"
        $entfernt = $true
    }
    if (-not $entfernt) {
        Meldung 'Es war kein Autostart eingerichtet.'
    }
}

# ----------------------------------------------------- Umgebungsvariablen ----

# app/streams.py legt go2rtc.yaml sonst unter C:\var\lib ab - deshalb werden
# die Pfade als Benutzer-Umgebungsvariablen hinterlegt. Das geht ohne
# Adminrechte und gilt auch fuer die geplante Aufgabe.
function SetzeUmgebung($konfigdatei, $datenverz) {
    $werte = [ordered]@{
        'CAMGRID_CONFIG'      = $konfigdatei
        'CAMGRID_GO2RTC_YAML' = (Join-Path $datenverz 'go2rtc.yaml')
        'CAMGRID_WEB'         = (Join-Path $Projekt 'web\public')
    }
    foreach ($schluessel in $werte.Keys) {
        [Environment]::SetEnvironmentVariable($schluessel, $werte[$schluessel], 'User')
        Set-Item -Path ("env:" + $schluessel) -Value $werte[$schluessel]
    }
    Meldung 'Umgebungsvariablen gesetzt: CAMGRID_CONFIG, CAMGRID_GO2RTC_YAML, CAMGRID_WEB'
}

function EntferneUmgebung {
    foreach ($schluessel in 'CAMGRID_CONFIG','CAMGRID_GO2RTC_YAML','CAMGRID_WEB') {
        [Environment]::SetEnvironmentVariable($schluessel, $null, 'User')
    }
    Meldung 'Umgebungsvariablen entfernt.'
}

# ------------------------------------------------------------ Deinstallation -

function Deinstallieren {
    $datenverz = Datenverzeichnis
    $konfigdatei = Join-Path $datenverz 'config.json'
    Meldung 'CamGrid wird von diesem Rechner entfernt.'

    if ($DryRun) {
        Meldung "[Probelauf] Autostart '$Aufgabenname' wuerde entfernt."
        Meldung "[Probelauf] Nach $konfigdatei wuerde gefragt."
        return
    }

    EntferneAutostart
    EntferneUmgebung

    if (Test-Path $konfigdatei) {
        $antwort = ''
        try {
            $antwort = Read-Host "Konfiguration $konfigdatei behalten? [J/n]"
        } catch {
            $antwort = 'j'
        }
        if ($antwort -match '^(n|nein)$') {
            Remove-Item $datenverz -Recurse -Force
            Meldung "Entfernt: $datenverz"
        } else {
            Meldung "Konfiguration bleibt erhalten: $konfigdatei"
        }
    } else {
        Meldung 'Es war keine Konfiguration vorhanden.'
    }

    Write-Host ''
    Meldung 'Fertig. Die Projektdateien selbst wurden nicht angetastet.'
    Meldung "Sie liegen weiterhin in $Projekt und koennen von Hand geloescht werden."
}

# ----------------------------------------------------------------- Ablauf -----

$version = Projektversion
Write-Host ''
Meldung "CamGrid $version - Windows"

if ($Port -lt 1 -or $Port -gt 65535) { Fehler "Ungueltiger Port: $Port" }
if ($Port -eq $AnzeigePort) { Fehler "Port $AnzeigePort ist fuer die Anzeige belegt - bitte einen anderen waehlen." }

if ($Uninstall) { Deinstallieren; exit 0 }

$adminrechte = IstAdmin
$datenverz = Datenverzeichnis
$konfigdatei = Join-Path $datenverz 'config.json'

if ($adminrechte) {
    Meldung "Adminrechte vorhanden - Konfiguration unter $datenverz"
} else {
    Meldung "Ohne Adminrechte (das genuegt) - Konfiguration unter $datenverz"
}
if ($DryRun) { Meldung '[Probelauf] Es wird nichts geaendert.' }

# 1. Projektdateien pruefen
foreach ($pflicht in 'app\dienst.py', 'app\server.py', 'web\public') {
    if (-not (Test-Path (Join-Path $Projekt $pflicht))) {
        Fehler "$pflicht fehlt in $Projekt - bitte das Skript im Projektordner starten."
    }
}

# 2. Python pruefen
$py = FindePython
if (-not $py) {
    PythonHinweis
    if (-not $DryRun) { Fehler 'Ohne Python 3 geht es nicht weiter.' }
    $py = [pscustomobject]@{ Python = 'python.exe'; Pythonw = 'pythonw.exe' }
} else {
    Meldung ("Python 3: " + $py.Python)
    if ($py.Pythonw -ne $py.Python) {
        Meldung ("Ohne Fenster: " + $py.Pythonw)
    } else {
        Warnung 'pythonw.exe nicht gefunden - der Autostart oeffnet ein Konsolenfenster.'
    }
}

# 3. go2rtc pruefen
$go2rtc = Join-Path $Projekt 'vendor\go2rtc\go2rtc.exe'
if (Test-Path $go2rtc) {
    Meldung "Streaming-Dienst: $go2rtc"
} else {
    Warnung "go2rtc fehlt: $go2rtc"
    Warnung 'Ohne go2rtc gibt es keine Videobilder. Datei go2rtc_win64.zip von'
    Warnung 'https://github.com/AlexxIT/go2rtc/releases holen, go2rtc.exe nach'
    Warnung 'vendor\go2rtc\ entpacken und install.ps1 erneut starten.'
}

# 4. Verzeichnis und Konfiguration
if ($DryRun) {
    Meldung "[Probelauf] Verzeichnis wuerde angelegt: $datenverz"
    if (Test-Path $konfigdatei) {
        Meldung "[Probelauf] Vorhandene Konfiguration bleibt unveraendert: $konfigdatei"
    } else {
        Meldung "[Probelauf] Konfiguration wuerde angelegt: $konfigdatei"
        Meldung "[Probelauf] Startzugang waere: $StandardBenutzer / $StandardPasswort"
    }
} else {
    if (-not (Test-Path $datenverz)) {
        New-Item -ItemType Directory -Path $datenverz -Force | Out-Null
        Meldung "Verzeichnis angelegt: $datenverz"
    }
}

$neueKonfiguration = $false
if (-not $DryRun) {
    if (Test-Path $konfigdatei) {
        Meldung "Konfiguration ist vorhanden und bleibt unveraendert: $konfigdatei"
        if ($Port -ne 8080) {
            Warnung "-Port $Port wird nicht uebernommen: der Port steht in der vorhandenen Konfiguration."
        }
    } else {
        if (ErzeugeKonfiguration $py.Python $konfigdatei $Port) {
            $neueKonfiguration = $true
        } else {
            Fehler "Konfiguration $konfigdatei konnte nicht angelegt werden."
        }
    }
    SetzeUmgebung $konfigdatei $datenverz
}

# 5. Autostart
$autostartart = 'keiner'
if ($NoAutostart) {
    Meldung 'Kein Autostart (-NoAutostart).'
    if (-not $DryRun) { EntferneAutostart }
} elseif ($DryRun) {
    Meldung "[Probelauf] Geplante Aufgabe '$Aufgabenname' wuerde bei der Anmeldung starten:"
    Meldung ("[Probelauf]   {0} `"{1}\app\dienst.py`" --mit-server --config `"{2}`" --port {3}" -f $py.Pythonw, $Projekt, $konfigdatei, $Port)
} else {
    $autostartart = RichteAutostartEin $py.Pythonw $konfigdatei $Port
}

# ----------------------------------------------------------- Zusammenfassung --

$ip = EigeneIpAdresse
$adminport = $Port
$anzeige = $AnzeigePort
if (-not $DryRun) {
    $adminport = LiesPort $konfigdatei 'admin_port' $Port
    $anzeige = LiesPort $konfigdatei 'go2rtc_port' $AnzeigePort
}

Write-Host ''
Write-Host '========================================================'
if ($DryRun) {
    Write-Host " CamGrid $version - Probelauf beendet (nichts geaendert)"
} else {
    Write-Host " CamGrid $version - Installation abgeschlossen"
}
Write-Host '========================================================'
Write-Host ''
Write-Host ' Adressen'
Write-Host "   Verwaltung : http://$ip`:$adminport"
Write-Host "   Anzeige    : http://$ip`:$anzeige/?monitor=1"
Write-Host "   Am Geraet  : http://127.0.0.1:$adminport"
Write-Host ''
Write-Host ' Zugangsdaten'
if ($neueKonfiguration -or $DryRun) {
    Write-Host "   Benutzer   : $StandardBenutzer"
    Write-Host "   Passwort   : $StandardPasswort"
    Write-Host '   >>> Das ist die bekannte Vorgabe. Bitte SOFORT nach dem ersten'
    Write-Host '   >>> Anmelden in der Verwaltung ein eigenes Passwort setzen.'
} else {
    Write-Host '   Unveraendert (vorhandene Konfiguration wurde beibehalten).'
    Write-Host "   Vorgabe bei einer frischen Installation: $StandardBenutzer / $StandardPasswort"
}
Write-Host ''
Write-Host ' Pfade'
Write-Host "   Projekt        : $Projekt"
Write-Host "   Konfiguration  : $konfigdatei"
Write-Host "   go2rtc.yaml    : $(Join-Path $datenverz 'go2rtc.yaml')"
Write-Host "   Protokoll      : $(Join-Path $datenverz 'go2rtc.log')"
Write-Host ''
Write-Host ' Naechste Schritte'
Write-Host '   1. Jetzt starten, ohne neu anzumelden:'
Write-Host ("      `"{0}`" `"{1}\app\dienst.py`" --mit-server --config `"{2}`" --port {3}" -f $py.Pythonw, $Projekt, $konfigdatei, $adminport)
if ($autostartart -eq 'aufgabe') {
    Write-Host "      oder: Start-ScheduledTask -TaskName $Aufgabenname"
}
Write-Host '   2. Verwaltung im Browser oeffnen, Passwort aendern, Kameras eintragen.'
Write-Host '   3. Anzeige im Vollbild oeffnen (F11 im Browser):'
Write-Host "      http://127.0.0.1:$anzeige/?monitor=1"
Write-Host ''
Write-Host ' Autostart'
switch ($autostartart) {
    'aufgabe'     { Write-Host "   Geplante Aufgabe '$Aufgabenname' - laeuft bei jeder Anmeldung." }
    'verknuepfung' { Write-Host "   Verknuepfung im Autostart-Ordner: $(StartVerknuepfung)" }
    default {
        if ($NoAutostart) {
            Write-Host '   Nicht eingerichtet (-NoAutostart).'
        } elseif ($DryRun) {
            Write-Host '   Im Probelauf nicht eingerichtet.'
        } else {
            Write-Host '   Nicht eingerichtet - bitte von Hand starten (siehe oben).'
        }
    }
}
Write-Host "   Entfernen: powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall"
Write-Host ''
exit 0
