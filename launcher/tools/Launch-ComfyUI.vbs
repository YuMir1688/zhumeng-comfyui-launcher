Option Explicit

Dim fileSystem
Dim shell
Dim toolsDirectory
Dim rootDirectory
Dim launcherPath
Dim command

Set fileSystem = CreateObject("Scripting.FileSystemObject")
toolsDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
rootDirectory = fileSystem.GetParentFolderName(toolsDirectory)
launcherPath = fileSystem.BuildPath(toolsDirectory, "ComfyUI-Launcher.ps1")

If Not fileSystem.FileExists(launcherPath) Then
    MsgBox "Launcher file not found:" & vbCrLf & launcherPath, vbCritical, "ComfyUI Launcher"
    WScript.Quit 1
End If

' Start through cmd.exe so Windows PowerShell inherits a valid console host.
' The cmd window itself remains hidden by WScript.Shell.Run.
command = "%ComSpec% /d /s /c ""powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & launcherPath & """"""

Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = rootDirectory
shell.Run command, 0, False
