' hermes-wake-hidden.vbs - generado por hermes-wake.py --install-task
' Lanza hermes-wake.py con pythonw (sin ventana de consola). No editar a mano.
Option Explicit
Dim fso, sh, here, python, script, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = here & "\hermes-wake.py"
python = sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\hermes\hermes-agent\venv\Scripts\pythonw.exe"
If Not fso.FileExists(python) Then python = "pythonw.exe"
cmd = Chr(34) & python & Chr(34) & " " & Chr(34) & script & Chr(34) & " --quiet"
' 0 = ventana oculta, False = no esperar a que termine
sh.Run cmd, 0, False
