# CamGrid - installation on Windows
#
# Sets up the configuration and the autostart entry. Admin rights are not
# needed: without admin rights the configuration lives in
# %LOCALAPPDATA%\CamGrid, with admin rights in %ProgramData%\CamGrid.
#
# Usage (PowerShell 5.1 or newer):
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Port 8090
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# All messages are in English and the file deliberately uses plain ASCII, so
# that it stays readable no matter which code page is active.

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [switch]$NoAutostart,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Fixed initial credentials - must be changed after the first login.
$StandardBenutzer = 'admin'
$StandardPasswort = 'camgrid'
$AnzeigePort      = 1984
$Aufgabenname     = 'CamGrid'
$Projekt          = $PSScriptRoot
if (-not $Projekt) { $Projekt = (Get-Location).Path }

# ------------------------------------------------------------------- output --

function Meldung($text)  { Write-Host "[camgrid] $text" }
function Warnung($text)  { Write-Host "[camgrid] Warning: $text" -ForegroundColor Yellow }
function Fehler($text) {
    Write-Host "[camgrid] Error: $text" -ForegroundColor Red
    exit 1
}

function Projektversion {
    $datei = Join-Path $Projekt 'VERSION'
    if (Test-Path $datei) {
        $wert = (Get-Content $datei -TotalCount 1).Trim()
        if ($wert) { return $wert }
    }
    return 'unknown'
}

function Hilfe {
    $v = Projektversion
    Write-Host @"
CamGrid - installation on Windows (version $v)

Usage:
  powershell -ExecutionPolicy Bypass -File install.ps1 [options]

Options:
  -Port N        Port of the admin interface (default: 8080)
  -NoAutostart   Do not create a scheduled task for the autostart
  -DryRun        Only show what would be done - changes nothing
  -Uninstall     Remove the autostart and ask about the configuration
  -Help          Show this help

What the script does:
  1. Check for Python 3 (points to 'winget install Python.Python.3.12' if missing)
  2. Create the configuration if there is none yet (it is never overwritten)
  3. Set up the autostart as the scheduled task 'CamGrid' at logon
  4. Print the addresses and credentials

Admin rights are not required. Without them the configuration and the logs
live under %LOCALAPPDATA%\CamGrid, with admin rights under
%ProgramData%\CamGrid.

To try it out without installing: start-lokal.cmd
"@
}

if ($Help) { Hilfe; exit 0 }

# -------------------------------------------------------------- environment --

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

# Looks for Python 3. Returns an object with Python (python.exe) and Pythonw.
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
    Warnung 'Python 3 was not found.'
    Meldung 'Install it for example with:'
    Meldung '  winget install Python.Python.3.12'
    Meldung 'Or download it from https://www.python.org/downloads/windows/ and tick'
    Meldung '"Add python.exe to PATH". Then run install.ps1 again.'
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
        # Without a network the placeholder stays.
    }
    return '<ip-address>'
}

# ----------------------------------------------------------- configuration ---

# Creates the initial configuration with app/config.py. An existing file is
# never touched.
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
except Exception as fehler:                      # fallback: minimal version
    print("Note: app/config.py is not usable (%s) - minimal version." % fehler)
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
print("Configuration written: %s" % ziel)
'@
    Set-Content -Path $skript -Value $inhalt -Encoding UTF8
    try {
        $ausgabe = & $python $skript $Projekt $ziel $port $AnzeigePort $StandardBenutzer $StandardPasswort
        if ($LASTEXITCODE -ne 0) {
            Warnung 'The configuration could not be created.'
            foreach ($zeile in $ausgabe) { Warnung $zeile }
            return $false
        }
        foreach ($zeile in $ausgabe) { Meldung $zeile }
        return $true
    } finally {
        Remove-Item $skript -Force -ErrorAction SilentlyContinue
    }
}

# Reads a numeric value from the configuration without starting Python.
function LiesPort($datei, $schluessel, $ersatz) {
    if (-not (Test-Path $datei)) { return $ersatz }
    try {
        $daten = Get-Content $datei -Raw | ConvertFrom-Json
        $wert = $daten.dienste.$schluessel
        if ($wert) { return [int]$wert }
    } catch {
        Warnung "Configuration $datei is not readable - $ersatz is used."
    }
    return $ersatz
}

# --------------------------------------------------------------- autostart ---

function StartVerknuepfung {
    return (Join-Path ([Environment]::GetFolderPath('Startup')) 'CamGrid.lnk')
}

# Order: scheduled task (preferred), then schtasks, and as a last resort a
# shortcut in the startup folder. That way it also works where scheduled
# tasks are blocked.
function RichteAutostartEin($pythonw, $konfigdatei, $port) {
    $argumente = '"{0}\app\dienst.py" --mit-server --config "{1}" --port {2}' -f $Projekt, $konfigdatei, $port

    try {
        $aktion = New-ScheduledTaskAction -Execute $pythonw -Argument $argumente -WorkingDirectory $Projekt
        $ausloeser = New-ScheduledTaskTrigger -AtLogOn -User ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
        $einstellungen = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $Aufgabenname -Action $aktion -Trigger $ausloeser `
            -Settings $einstellungen -Description 'Starts CamGrid at logon.' `
            -Force -ErrorAction Stop | Out-Null
        Meldung "Autostart set up: scheduled task '$Aufgabenname' (at logon)."
        return 'aufgabe'
    } catch {
        Warnung ("Scheduled task not possible: " + $_.Exception.Message)
    }

    $befehlszeile = '"{0}" {1}' -f $pythonw, $argumente
    & schtasks /Create /TN $Aufgabenname /TR $befehlszeile /SC ONLOGON /RL LIMITED /F 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Meldung "Autostart set up: scheduled task '$Aufgabenname' (via schtasks)."
        return 'aufgabe'
    }
    Warnung 'schtasks was not successful either - the startup folder is used instead.'

    try {
        $verknuepfung = StartVerknuepfung
        $schale = New-Object -ComObject WScript.Shell
        $ziel = $schale.CreateShortcut($verknuepfung)
        $ziel.TargetPath = $pythonw
        $ziel.Arguments = $argumente
        $ziel.WorkingDirectory = $Projekt
        $ziel.Description = 'Starts CamGrid at logon.'
        $ziel.Save()
        Meldung "Autostart set up: $verknuepfung"
        return 'verknuepfung'
    } catch {
        Warnung ("Autostart could not be set up: " + $_.Exception.Message)
        return 'keiner'
    }
}

function EntferneAutostart {
    $entfernt = $false
    try {
        $vorhanden = Get-ScheduledTask -TaskName $Aufgabenname -ErrorAction SilentlyContinue
        if ($vorhanden) {
            Unregister-ScheduledTask -TaskName $Aufgabenname -Confirm:$false -ErrorAction Stop
            Meldung "Scheduled task '$Aufgabenname' removed."
            $entfernt = $true
        }
    } catch {
        Warnung ("The scheduled task could not be removed: " + $_.Exception.Message)
    }
    # Only look via schtasks when the cmdlet is missing - otherwise schtasks
    # prints an error line on every run without a task.
    if (-not $entfernt -and -not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        & cmd /c "schtasks /Query /TN ""$Aufgabenname"" >nul 2>&1"
        if ($LASTEXITCODE -eq 0) {
            & cmd /c "schtasks /Delete /TN ""$Aufgabenname"" /F >nul 2>&1"
            if ($LASTEXITCODE -eq 0) {
                Meldung "Scheduled task '$Aufgabenname' removed (via schtasks)."
                $entfernt = $true
            }
        }
    }
    $verknuepfung = StartVerknuepfung
    if (Test-Path $verknuepfung) {
        Remove-Item $verknuepfung -Force
        Meldung "Removed: $verknuepfung"
        $entfernt = $true
    }
    if (-not $entfernt) {
        Meldung 'There was no autostart set up.'
    }
}

# ------------------------------------------------- environment variables -----

# Otherwise app/streams.py would put go2rtc.yaml under C:\var\lib - so the
# paths are stored as user environment variables. That works without admin
# rights and also applies to the scheduled task.
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
    Meldung 'Environment variables set: CAMGRID_CONFIG, CAMGRID_GO2RTC_YAML, CAMGRID_WEB'
}

function EntferneUmgebung {
    foreach ($schluessel in 'CAMGRID_CONFIG','CAMGRID_GO2RTC_YAML','CAMGRID_WEB') {
        [Environment]::SetEnvironmentVariable($schluessel, $null, 'User')
    }
    Meldung 'Environment variables removed.'
}

# ------------------------------------------------------------------ uninstall -

function Deinstallieren {
    $datenverz = Datenverzeichnis
    $konfigdatei = Join-Path $datenverz 'config.json'
    Meldung 'CamGrid is being removed from this computer.'

    if ($DryRun) {
        Meldung "[Dry run] The autostart '$Aufgabenname' would be removed."
        Meldung "[Dry run] You would be asked about $konfigdatei."
        return
    }

    EntferneAutostart
    EntferneUmgebung

    if (Test-Path $konfigdatei) {
        $antwort = ''
        try {
            $antwort = Read-Host "Keep the configuration $konfigdatei? [Y/n]"
        } catch {
            $antwort = 'y'
        }
        if ($antwort -match '^(n|no)$') {
            Remove-Item $datenverz -Recurse -Force
            Meldung "Removed: $datenverz"
        } else {
            Meldung "The configuration is kept: $konfigdatei"
        }
    } else {
        Meldung 'There was no configuration.'
    }

    Write-Host ''
    Meldung 'Done. The project files themselves were not touched.'
    Meldung "They are still in $Projekt and can be deleted by hand."
}

# --------------------------------------------------------------------- flow ---

$version = Projektversion
Write-Host ''
Meldung "CamGrid $version - Windows"

if ($Port -lt 1 -or $Port -gt 65535) { Fehler "Invalid port: $Port" }
if ($Port -eq $AnzeigePort) { Fehler "Port $AnzeigePort is used by the display - please pick another one." }

if ($Uninstall) { Deinstallieren; exit 0 }

$adminrechte = IstAdmin
$datenverz = Datenverzeichnis
$konfigdatei = Join-Path $datenverz 'config.json'

if ($adminrechte) {
    Meldung "Admin rights present - configuration under $datenverz"
} else {
    Meldung "Without admin rights (that is enough) - configuration under $datenverz"
}
if ($DryRun) { Meldung '[Dry run] Nothing is changed.' }

# 1. Check the project files
foreach ($pflicht in 'app\dienst.py', 'app\server.py', 'web\public') {
    if (-not (Test-Path (Join-Path $Projekt $pflicht))) {
        Fehler "$pflicht is missing in $Projekt - please run the script inside the project folder."
    }
}

# 2. Check Python
$py = FindePython
if (-not $py) {
    PythonHinweis
    if (-not $DryRun) { Fehler 'Without Python 3 this cannot continue.' }
    $py = [pscustomobject]@{ Python = 'python.exe'; Pythonw = 'pythonw.exe' }
} else {
    Meldung ("Python 3: " + $py.Python)
    if ($py.Pythonw -ne $py.Python) {
        Meldung ("Without a window: " + $py.Pythonw)
    } else {
        Warnung 'pythonw.exe not found - the autostart will open a console window.'
    }
}

# 3. Check go2rtc
$go2rtc = Join-Path $Projekt 'vendor\go2rtc\go2rtc.exe'
if (Test-Path $go2rtc) {
    Meldung "Streaming service: $go2rtc"
} else {
    Warnung "go2rtc is missing: $go2rtc"
    Warnung 'Without go2rtc there are no video images. Get go2rtc_win64.zip from'
    Warnung 'https://github.com/AlexxIT/go2rtc/releases, extract go2rtc.exe into'
    Warnung 'vendor\go2rtc\ and run install.ps1 again.'
}

# 4. Directory and configuration
if ($DryRun) {
    Meldung "[Dry run] The directory would be created: $datenverz"
    if (Test-Path $konfigdatei) {
        Meldung "[Dry run] The existing configuration would stay unchanged: $konfigdatei"
    } else {
        Meldung "[Dry run] The configuration would be created: $konfigdatei"
        Meldung "[Dry run] The initial login would be: $StandardBenutzer / $StandardPasswort"
    }
} else {
    if (-not (Test-Path $datenverz)) {
        New-Item -ItemType Directory -Path $datenverz -Force | Out-Null
        Meldung "Directory created: $datenverz"
    }
}

$neueKonfiguration = $false
if (-not $DryRun) {
    if (Test-Path $konfigdatei) {
        Meldung "The configuration exists and stays unchanged: $konfigdatei"
        if ($Port -ne 8080) {
            Warnung "-Port $Port is ignored: the port is taken from the existing configuration."
        }
    } else {
        if (ErzeugeKonfiguration $py.Python $konfigdatei $Port) {
            $neueKonfiguration = $true
        } else {
            Fehler "The configuration $konfigdatei could not be created."
        }
    }
    SetzeUmgebung $konfigdatei $datenverz
}

# 5. Autostart
$autostartart = 'keiner'
if ($NoAutostart) {
    Meldung 'No autostart (-NoAutostart).'
    if (-not $DryRun) { EntferneAutostart }
} elseif ($DryRun) {
    Meldung "[Dry run] The scheduled task '$Aufgabenname' would start at logon:"
    Meldung ("[Dry run]   {0} `"{1}\app\dienst.py`" --mit-server --config `"{2}`" --port {3}" -f $py.Pythonw, $Projekt, $konfigdatei, $Port)
} else {
    $autostartart = RichteAutostartEin $py.Pythonw $konfigdatei $Port
}

# ------------------------------------------------------------------- summary --

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
    Write-Host " CamGrid $version - dry run finished (nothing changed)"
} else {
    Write-Host " CamGrid $version - installation finished"
}
Write-Host '========================================================'
Write-Host ''
Write-Host ' Addresses'
Write-Host "   Admin     : http://$ip`:$adminport"
Write-Host "   Display   : http://$ip`:$anzeige/?monitor=1"
Write-Host "   On device : http://127.0.0.1:$adminport"
Write-Host ''
Write-Host ' Credentials'
if ($neueKonfiguration -or $DryRun) {
    Write-Host "   User      : $StandardBenutzer"
    Write-Host "   Password  : $StandardPasswort"
    Write-Host '   >>> This is the well-known default. Please set your own password'
    Write-Host '   >>> in the admin interface IMMEDIATELY after the first login.'
} else {
    Write-Host '   Unchanged (the existing configuration was kept).'
    Write-Host "   Default for a fresh installation: $StandardBenutzer / $StandardPasswort"
}
Write-Host ''
Write-Host ' Paths'
Write-Host "   Project        : $Projekt"
Write-Host "   Configuration  : $konfigdatei"
Write-Host "   go2rtc.yaml    : $(Join-Path $datenverz 'go2rtc.yaml')"
Write-Host "   Log            : $(Join-Path $datenverz 'go2rtc.log')"
Write-Host ''
Write-Host ' Next steps'
Write-Host '   1. Start it now, without logging in again:'
Write-Host ("      `"{0}`" `"{1}\app\dienst.py`" --mit-server --config `"{2}`" --port {3}" -f $py.Pythonw, $Projekt, $konfigdatei, $adminport)
if ($autostartart -eq 'aufgabe') {
    Write-Host "      or: Start-ScheduledTask -TaskName $Aufgabenname"
}
Write-Host '   2. Open the admin interface in a browser, change the password, add cameras.'
Write-Host '   3. Open the display full screen (F11 in the browser):'
Write-Host "      http://127.0.0.1:$anzeige/?monitor=1"
Write-Host ''
Write-Host ' Autostart'
switch ($autostartart) {
    'aufgabe'     { Write-Host "   Scheduled task '$Aufgabenname' - runs at every logon." }
    'verknuepfung' { Write-Host "   Shortcut in the startup folder: $(StartVerknuepfung)" }
    default {
        if ($NoAutostart) {
            Write-Host '   Not set up (-NoAutostart).'
        } elseif ($DryRun) {
            Write-Host '   Not set up during a dry run.'
        } else {
            Write-Host '   Not set up - please start it by hand (see above).'
        }
    }
}
Write-Host "   Remove: powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall"
Write-Host ''
exit 0
