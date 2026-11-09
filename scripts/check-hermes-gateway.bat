@echo off
rem ============================================================
rem  check-hermes-gateway.bat
rem  ¿El gateway de Hermes está corriendo, sí o sí?
rem
rem  Uso:
rem    check-hermes-gateway.bat              resumen legible
rem    check-hermes-gateway.bat --json       salida JSON
rem    check-hermes-gateway.bat --quiet      solo UP/DEGRADED/DOWN
rem    check-hermes-gateway.bat pause        igual, y espera tecla al final
rem
rem  Código de salida: 0 = UP, 1 = DOWN, 2 = DEGRADED
rem ============================================================
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT=%~dp0check-hermes-gateway.py"
set "PAUSE_AT_END="
set "ARGS="

:parse
if "%~1"=="" goto run
if /i "%~1"=="pause" (
    set "PAUSE_AT_END=1"
    shift
    goto parse
)
set "ARGS=!ARGS! %1"
shift
goto parse

:run
if not exist "%SCRIPT%" (
    echo [FAIL] no encuentro "%SCRIPT%"
    set "RC=1"
    goto end
)

set "HERMES_HOME=%LOCALAPPDATA%\hermes"
set "PY=%HERMES_HOME%\hermes-agent\venv\Scripts\python.exe"

if exist "%PY%" goto exec
rem Fallback: python del PATH
set "PY="
for %%P in (python.exe) do if not defined PY set "PY=%%~$PATH:P"
if not defined PY (
    echo [FAIL] no encuentro el python del venv de Hermes ni "python" en el PATH
    set "RC=1"
    goto end
)

:exec
"%PY%" "%SCRIPT%"!ARGS!
set "RC=%ERRORLEVEL%"

:end
if defined PAUSE_AT_END pause
exit /b %RC%
