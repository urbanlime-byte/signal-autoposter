Set sh = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\autoposter.ps1""", 0, False
