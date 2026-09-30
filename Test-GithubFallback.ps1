$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Launcher.Services.psm1') -Force
Add-Type -AssemblyName System.Net.Http
# Initialize the production asynchronous helper without making a network request.
$dummy=[Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
[void](ConvertTo-LauncherHttpFailure $dummy)
$dummy.Dispose()
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class GithubFixture : HttpMessageHandler {
    public int ApiCalls, PageCalls;
    public string Mode = "limited";
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage q, CancellationToken t) {
        HttpResponseMessage r;
        if(q.RequestUri.Host == "api.github.com") {
            ApiCalls++;
            r = new HttpResponseMessage(Mode == "normal" ? HttpStatusCode.OK : HttpStatusCode.Forbidden);
            r.RequestMessage=q;
            if(Mode == "limited") {
                r.Headers.Add("X-RateLimit-Remaining","0");
                r.Headers.Add("X-RateLimit-Reset", DateTimeOffset.UtcNow.AddMinutes(3).ToUnixTimeSeconds().ToString());
            }
            if(Mode == "secondary") r.Headers.Add("Retry-After","120");
            r.Content=new StringContent("{\"tag_name\":\"v0.35.0\",\"html_url\":\"https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.35.0\",\"published_at\":null,\"body\":\"test\"}");
        } else {
            PageCalls++;
            r=new HttpResponseMessage(Mode == "both-fail" ? HttpStatusCode.Forbidden : HttpStatusCode.OK);
            string url=Mode == "bad-redirect" ? "https://example.com/Comfy-Org/ComfyUI/releases/tag/v0.35.0" : "https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.35.0";
            r.RequestMessage=new HttpRequestMessage(HttpMethod.Get,url);
        }
        return Task.FromResult(r);
    }
}
'@
function Reset-FixtureState {
    $flags=[Reflection.BindingFlags]'NonPublic,Static'
    [LauncherReleaseTransport].GetField('apiResume',$flags).SetValue($null,[DateTimeOffset]::MinValue)
    [LauncherReleaseTransport].GetField('cachedStable',$flags).SetValue($null,$null)
}
$uri='https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest'
foreach($mode in @('normal','limited','secondary','unknown','both-fail','bad-redirect')) {
    Reset-FixtureState
    $handler=[GithubFixture]::new();$handler.Mode=$mode
    $client=[Net.Http.HttpClient]::new($handler)
    try {
        $errorText=''
        try {$json=[LauncherReleaseTransport]::Fetch($client,$uri).GetAwaiter().GetResult()} catch {$errorText=ConvertTo-LauncherNetworkError $_}
        if($mode -in @('both-fail','bad-redirect')) {
            if(-not $errorText -or $errorText -eq '当前网络无法访问') {throw "Failure not preserved: $mode"}
        } else {
            if($errorText) {throw $errorText}
            $release=$json | ConvertFrom-Json
            if($release.tag_name -ne 'v0.35.0') {throw 'Bad version'}
            if($mode -ne 'normal') {
                if($release.launcher_source -ne 'official-release-page') {throw 'Fallback not identified'}
                [void][LauncherReleaseTransport]::Fetch($client,$uri).GetAwaiter().GetResult()
                if($handler.ApiCalls -ne 1 -or $handler.PageCalls -ne 1) {throw 'Fallback cache did not avoid repeat requests'}
                $previewFailed=$false
                try {[void][LauncherReleaseTransport]::Fetch($client,'https://api.github.com/repos/Comfy-Org/ComfyUI/releases?per_page=10').GetAwaiter().GetResult()} catch {$previewFailed=$true}
                if(-not $previewFailed -or $handler.ApiCalls -ne 1) {throw 'Preview cooldown not enforced'}
            }
        }
        "PASS: $mode"
    } finally {$client.Dispose()}
}
Reset-FixtureState
$r=[Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
$r.RequestMessage=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$uri)
if((ConvertTo-LauncherHttpFailure $r) -notmatch '尚不能判定为限流') {throw 'Unknown 403 mislabeled'}
$r.Headers.Add('Retry-After','120')
if((ConvertTo-LauncherHttpFailure $r) -notmatch '限流') {throw 'Secondary limit missed'}
$r.Dispose()
'PASS: 403 discrimination and retry-after classification'

# Exercise the production WPF completion handler with fallback JSON and failure.
Add-Type -AssemblyName PresentationFramework
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Launcher.ps1'),[ref]$t,[ref]$e)
$fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Complete-CoreUpdateCheck'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
function Get-Brush($color) { return [Windows.Media.BrushConverter]::new().ConvertFromString($color) }
function Save-LauncherSettingsIfAllowed($Path,$Settings) {}
function Update-CoreUpdateAvailability {}
function Update-HomeNotice {}
function Append-Console($Text) {}
foreach($name in @('CoreUpdateStatusText','UpdateTestStatusText','CoreLatestVersionText','CorePublishedText','CoreReleaseNotesText','LastUpdateCheckText')) {Set-Variable -Scope Script -Name $name -Value ([Windows.Controls.TextBlock]::new())}
$script:BtnOpenCoreRelease=[Windows.Controls.Button]::new()
$script:BtnCheckCoreUpdate=[Windows.Controls.Button]::new()
$script:UpdateCheckProgress=[Windows.Controls.ProgressBar]::new()
$script:isClosing=$false;$script:settingsGeneration=1;$script:networkResults=@{}
$script:launcherSettings=New-LauncherSettings
$script:settingsPath='fixture';$script:coreVersion='0.33.1'
foreach($fail in @($false,$true)) {
    $task=[Threading.Tasks.TaskCompletionSource[string]]::new()
    if($fail) {$task.SetException([LauncherHttpFailure]::new('访问被拒绝（HTTP 403），官方发布页也不可用。'))}
    else {$task.SetResult('{"tag_name":"v0.35.0","html_url":"https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.35.0","published_at":null,"body":"官方发布页备用查询","launcher_source":"official-release-page"}')}
    $script:currentUpdateOpId=[guid]::NewGuid().ToString()
    $script:updateRequest=[pscustomobject]@{Task=$task.Task;CompletionClaimed=$false;OpId=$script:currentUpdateOpId;SettingsGeneration=1;Uri=$uri;Client=[Net.Http.HttpClient]::new();Stopwatch=[Diagnostics.Stopwatch]::StartNew()}
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{Complete-CoreUpdateCheck})
    if($null -ne $script:updateRequest -or -not $script:BtnCheckCoreUpdate.IsEnabled) {throw 'UI cleanup failed'}
    if($fail -eq $script:networkResults.update.Success) {throw 'UI result incorrect'}
    if(-not $fail -and ($script:UpdateTestStatusText.Text -notmatch '官方发布页查询成功' -or $script:CorePublishedText.Text -ne '—')) {throw 'Fallback UI inaccurate'}
    if($fail -and $script:UpdateTestStatusText.Text -notmatch '403') {throw '403 details lost'}
}
'PASS: production WPF fallback success and all-routes-failed callbacks'
