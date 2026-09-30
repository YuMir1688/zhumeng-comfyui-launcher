$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
public static class StartupMessageCapture {
    public static string Message;
    public static int Show(object owner, string message, string title, object buttons, object icon) {
        Message = message; return 0;
    }
}
'@
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Launcher.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Finalize-ComfyUIProcess'},$true)
. ([scriptblock]::Create($fn.Extent.Text.Replace('[System.Windows.MessageBox]::Show(', '[StartupMessageCapture]::Show(')))
function Read-PendingLogs {}
function Set-LauncherStatus($Text,$Color) {}
function Get-UiText($Key,$Args) {return $Key}
function Save-LastStartupFailureLog($Reason) {return $script:fixtureLog}
function Set-RunningControls($Running) {}
function Show-LauncherPage($Page,$Nav) {}
function Remove-TemporaryLogs {}
$script:fixtureLog=Join-Path $PSScriptRoot ('test-artifacts/null-diagnostic-' + [guid]::NewGuid().ToString('N') + '.log')
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:fixtureLog))
$script:window=$null;$script:PageConsole=$null;$script:NavConsole=$null
$script:BtnConsoleOpenWeb=[pscustomobject]@{IsEnabled=$false}
$script:AutoTempCleanCheck=[pscustomobject]@{IsChecked=$false}
$script:isClosing=$false
foreach($case in @(
    @{Code=73;Log='';Expected='NUL'},
    @{Code=$null;Log='[LAUNCHER:E_NULL_DEVICE] missing';Expected='NUL'},
    @{Code=$null;Log='unrelated failure';Expected='退出代码：-1'}
)) {
    [IO.File]::WriteAllText($script:fixtureLog,$case.Log)
    $script:portReady=$false
    $script:comfyProcess=[pscustomobject]@{HasExited=$true;ExitCode=$case.Code}
    $script:comfyProcess | Add-Member ScriptMethod WaitForExit {param($timeout) return $true}
    $script:comfyProcess | Add-Member ScriptMethod Dispose {}
    Finalize-ComfyUIProcess
    if(-not [StartupMessageCapture]::Message.Contains($case.Expected)){throw 'Incorrect failure dialog'}
    if($null -ne $script:comfyProcess){throw 'Process not finalized'}
}
'PASS: NUL-specific dialog, missing ExitCode fallback, generic exit code not blank'
