param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Launcher.ps1'
$content=[IO.File]::ReadAllText($source)
$injection=@'
# Test-only injection: fail the automatic HTTP task, leave all real WPF
# controls, timers, completion handlers and cleanup running unchanged.
$script:suppressSettingsPersistence=$true
Add-Type -AssemblyName System.Net.Http
$script:launcherSettings.updates.autoCheck=$false
function Test-ShouldAutoCheckUpdates { return $true }
function Start-LauncherJsonRequest {
    param($Uri,$Settings,$TimeoutSeconds)
    $tcs=[Threading.Tasks.TaskCompletionSource[string]]::new()
    $tcs.SetException([TimeoutException]::new('injected request timeout'))
    return [pscustomobject]@{
        Task=$tcs.Task; Uri=$Uri; Client=[Net.Http.HttpClient]::new()
        Stopwatch=[Diagnostics.Stopwatch]::StartNew()
    }
}
$script:fixtureFailure=$null
$script:fixtureTicks=0
$script:fixtureTimer=[Windows.Threading.DispatcherTimer]::new()
$script:fixtureTimer.Interval=[TimeSpan]::FromSeconds(1)
$script:fixtureTimer.Add_Tick({
    $script:fixtureTicks++
    if ($script:fixtureTicks -lt 20) { return }
    try {
        if ($script:CoreUpdateStatusText.Text -notlike '*请求超时*') { throw ('Timeout not shown in full UI: ' + $script:CoreUpdateStatusText.Text) }
        if (-not $script:BtnCheckCoreUpdate.IsEnabled) { throw 'Retry not enabled' }
        if ($null -ne $script:updateRequest) { throw 'Request not cleaned up' }
        Show-LauncherPage $script:PageNetwork $script:NavNetwork
        Show-NetworkSection 'update'
        $script:window.UpdateLayout()
    } catch { $script:fixtureFailure=$_ }
    $script:fixtureTimer.Stop()
    $script:window.Close()
})
$script:fixtureTimer.Start()
'@
$anchor='$pollTimer = New-Object System.Windows.Threading.DispatcherTimer'
if (-not $content.Contains($anchor)) { throw 'Test injection anchor missing' }
$content=$content.Replace($anchor,($injection + "`r`n" + $anchor))
$content += @'

if ($null -ne $script:fixtureFailure) { throw $script:fixtureFailure }
if ($script:fixtureTicks -lt 20) { throw 'Window exited early' }
Write-Output 'Full launcher window survived automatic request timeout for 20 seconds; navigation and retry restored.'
'@
$fixture=Join-Path $Root ('tools/network-window-fixture-' + [guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($fixture,$content,[Text.UTF8Encoding]::new($true))
try {
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Full window failure regression failed' }
} finally { Remove-Item -LiteralPath $fixture }
