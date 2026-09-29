@echo off
REM Startet CamGrid zum Testen direkt aus diesem Ordner - ohne Installation.
setlocal
cd /d "%~dp0"

set "PYTHON="
for %%P in (python.exe) do if not defined PYTHON if exist "%%~$PATH:P" set "PYTHON=%%~$PATH:P"
if not defined PYTHON (
    py -3 --version >nul 2>&1
    if not errorlevel 1 set "PYTHON=py -3"
)
if not defined PYTHON (
    echo Python 3 wird benoetigt und wurde nicht gefunden.
    echo Installation zum Beispiel so: winget install Python.Python.3.12
    exit /b 1
)

if not exist "test\lokal" mkdir "test\lokal"
set "CAMGRID_CONFIG=%CD%\test\lokal\config.json"
set "CAMGRID_GO2RTC_YAML=%CD%\test\lokal\go2rtc.yaml"
set "CAMGRID_WEB=%CD%\web\public"
set "PYTHONIOENCODING=utf-8"

echo CamGrid startet lokal ...
echo   Verwaltung : http://127.0.0.1:8080
echo   Anzeige    : http://127.0.0.1:1984/?monitor=1
echo   Anmeldung  : admin / camgrid  (bitte bald aendern)
echo   Daten      : %CD%\test\lokal
echo   Beenden mit Strg+C
echo.

%PYTHON% -m app.dienst --mit-server --config "%CAMGRID_CONFIG%" --port 8080
endlocal
