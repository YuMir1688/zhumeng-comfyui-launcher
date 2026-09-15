param([string]$SourceRoot = (Join-Path $PSScriptRoot 'launcher'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Import-Module (Join-Path $SourceRoot 'tools/ComfyUI-Launcher.Services.psm1') -Force -DisableNameChecking
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Net.Http
$cases = @(
    @{ Error=[TimeoutException]::new('request timeout'); Expected='请求超时' },
    @{ Error=[Threading.Tasks.TaskCanceledException]::new('canceled'); Expected='请求超时' },
    @{ Error=[Exception]::new('DNS name resolution failed'); Expected='域名无法解析' },
    @{ Error=[Exception]::new('proxy connection failed'); Expected='代理连接失败' },
    @{ Error=[Exception]::new('TLS certificate error'); Expected='TLS 证书错误' },
    @{ Error=[Exception]::new('connection refused'); Expected='服务器拒绝连接' },
    @{ Error=[AggregateException]::new([TimeoutException]::new('timeout')); Expected='请求超时' },
    @{ Error=[Management.Automation.MethodInvocationException]::new('wrapper',[TimeoutException]::new('timeout')); Expected='请求超时' },
    @{ Error=[pscustomobject]@{Exception=[pscustomobject]@{Message='DNS failure'}}; Expected='域名无法解析' },
    @{ Error='unrecognized error'; Expected='当前网络无法访问' },
    @{ Error=[pscustomobject]@{}; Expected='当前网络无法访问' },
    @{ Error=$null; Expected='当前网络无法访问' }
)
foreach ($case in $cases) {
    $actual = ConvertTo-LauncherNetworkError $case.Error
    if ($actual -ne $case.Expected) { throw "Network error mismatch: $actual" }
}
try { throw [TimeoutException]::new('timeout') }
catch { if ((ConvertTo-LauncherNetworkError $_) -ne '请求超时') { throw 'ErrorRecord failed' } }

# Execute the production completion handler in a real WPF dispatcher. Only
# controls and the HTTP task are fixtures; no copied implementation or network.
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tools/ComfyUI-Launcher.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'Launcher parse failure' }
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Complete-CoreUpdateCheck'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
function Get-Brush($color) { return [Windows.Media.BrushConverter]::new().ConvertFromString($color) }
function Update-HomeNotice {}
$script:CoreUpdateStatusText=[Windows.Controls.TextBlock]::new()
$script:UpdateTestStatusText=[Windows.Controls.TextBlock]::new()
$script:UpdateCheckProgress=[Windows.Controls.ProgressBar]::new()
$script:BtnCheckCoreUpdate=[Windows.Controls.Button]::new()
$script:networkResults=@{}
$script:isClosing=$false
$script:settingsGeneration=1
$script:completed=0
$script:failure=$null
$script:window=[Windows.Window]::new()
$script:window.Title='Launcher network failure regression'
$script:window.Width=450; $script:window.Height=120
$script:window.Content=$script:CoreUpdateStatusText
$script:timer=[Windows.Threading.DispatcherTimer]::new()
$script:timer.Interval=[TimeSpan]::FromMilliseconds(50)
$script:timer.Add_Tick({
    try {
        if ($script:completed -eq 6) { $script:timer.Stop(); $script:window.Close(); return }
        $case=$cases[$script:completed]
        $tcs=[Threading.Tasks.TaskCompletionSource[string]]::new()
        $tcs.SetException([Exception]$case.Error)
        $script:currentUpdateOpId=[guid]::NewGuid().ToString()
        $script:BtnCheckCoreUpdate.IsEnabled=$false
        $script:updateRequest=[pscustomobject]@{
            Task=$tcs.Task; CompletionClaimed=$false; OpId=$script:currentUpdateOpId
            SettingsGeneration=1; Uri='https://example.invalid/fixture'
            Client=[Net.Http.HttpClient]::new(); Stopwatch=[Diagnostics.Stopwatch]::StartNew()
        }
        Complete-CoreUpdateCheck
        if ($null -ne $script:updateRequest -or -not $script:BtnCheckCoreUpdate.IsEnabled) { throw 'Request cleanup or retry button failed' }
        if ($script:networkResults.update.Success) { throw 'Failure incorrectly marked successful' }
        if ($script:UpdateTestStatusText.Text -ne $case.Expected) { throw "UI error text mismatch: $($script:UpdateTestStatusText.Text)" }
        $script:completed++
    } catch {
        $script:failure=$_
        $script:timer.Stop(); $script:window.Close()
    }
})
$script:timer.Start()
try { [void]$script:window.ShowDialog() } finally { $script:timer.Stop() }
if ($null -ne $script:failure) { throw $script:failure }
if ($script:completed -ne 6) { throw 'WPF completion tests incomplete' }
Write-Output 'Network failure tests OK: 13 input cases; 6 production WPF completion callbacks; retry controls restored.'
