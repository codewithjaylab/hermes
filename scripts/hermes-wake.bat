@echo off
rem ============================================================
rem  hermes-wake.bat — levanta el gateway de Hermes si esta caido
rem
rem  Uso:
rem    hermes-wake.bat                 un chequeo y, si hace falta, levanta
rem    hermes-wake.bat --dry-run       solo dice que haria
rem    hermes-wake.bat --watch         vigilante residente (Ctrl+C para salir)
rem    hermes-wake.bat --install-task  lo registra cada 3 min, sin ventana (Programador)
rem    hermes-wake.bat --uninstall-task
rem    hermes-wake.bat --message       ademas intenta despertar leyendo WhatsApp
rem  Agregar  pause  como ultimo argumento para que espere tecla (doble clic).
rem ============================================================
setlocal

set "HERMES_HOME=%LOCALAPPDATA%\hermes"
set "PY=%HERMES_HOME%\hermes-agent\venv\Scripts\python.exe"
if not exist "%PY%" set "PY=python"

rem pythonw evita la ventana de consola cuando lo lanza el Programador de tareas
if defined HERMES_WAKE_WINDOWLESS (
    if exist "%HERMES_HOME%\hermes-agent\venv\Scripts\pythonw.exe" (
        set "PY=%HERMES_HOME%\hermes-agent\venv\Scripts\pythonw.exe"
    )
)

"%PY%" "%~dp0hermes-wake.py" %*
set "RC=%ERRORLEVEL%"

echo %* | findstr /i /c:"pause" >nul && pause
exit /b %RC%
