Option Explicit

Dim files, shell, scriptPath, powershell, quote
Set files = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
scriptPath = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "Launch-Receiver.ps1")
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
quote = Chr(34)
shell.Run quote & powershell & quote & " -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File " & quote & scriptPath & quote & " -StartMinimized", 0, False
