@echo off
REM Starts CamGrid for testing straight from this folder - without installing.
setlocal
cd /d "%~dp0"

set "PYTHON="
for %%P in (python.exe) do if not defined PYTHON if exist "%%~$PATH:P" set "PYTHON=%%~$PATH:P"
if not defined PYTHON (
    py -3 --version >nul 2>&1
    if not errorlevel 1 set "PYTHON=py -3"
)
if not defined PYTHON (
    echo Python 3 is required and was not found.
    echo Install it for example with: winget install Python.Python.3.12
    exit /b 1
)

if not exist "test\lokal" mkdir "test\lokal"
set "CAMGRID_CONFIG=%CD%\test\lokal\config.json"
set "CAMGRID_GO2RTC_YAML=%CD%\test\lokal\go2rtc.yaml"
set "CAMGRID_WEB=%CD%\web\public"
set "PYTHONIOENCODING=utf-8"

echo CamGrid is starting locally ...
echo   Admin   : http://127.0.0.1:8080
echo   Display : http://127.0.0.1:1984/?monitor=1
echo   Login   : admin / camgrid  (please change it soon)
echo   Data    : %CD%\test\lokal
echo   Stop with Ctrl+C
echo.

%PYTHON% -m app.dienst --mit-server --config "%CAMGRID_CONFIG%" --port 8080
endlocal
