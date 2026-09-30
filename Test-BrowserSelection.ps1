$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Launcher.Services.psm1') -Force
$fixture = Join-Path $PSScriptRoot ('test-artifacts/browser-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$exe = Join-Path $fixture '测试 浏览器.exe'
# A real executable records the received URL; no actual browser/user profile is touched.
Add-Type -TypeDefinition 'using System; using System.IO; public class BrowserProbe { public static void Main(string[] a) { File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"url.txt"), string.Join("\n",a)); } }' -OutputAssembly $exe -OutputType ConsoleApplication
$settings = Merge-LauncherSettings ([pscustomobject]@{schemaVersion=1})
if ($settings.browser.executable -ne '') { throw 'Old settings migration failed' }
$settings.browser.executable = $exe
$settingsPath = Join-Path $fixture 'settings.json'
Save-LauncherSettings $settingsPath $settings
$restored = Read-LauncherSettings $settingsPath
if ($restored.browser.executable -ne $exe) { throw 'Browser persistence failed' }
$info = New-LauncherBrowserStartInfo $restored.browser.executable 1087
$proc = [Diagnostics.Process]::Start($info)
if (-not $proc.WaitForExit(10000)) { $proc.Kill(); throw 'Browser probe timed out' }
if ([IO.File]::ReadAllText((Join-Path $fixture 'url.txt')) -ne 'http://127.0.0.1:1087') { throw 'URL dispatch failed' }
$proc.Dispose()
$default = New-LauncherBrowserStartInfo '' 1080
if (-not $default.UseShellExecute -or $default.FileName -ne 'http://127.0.0.1:1080') { throw 'System default broken' }
foreach ($invalid in @('relative.exe', (Join-Path $fixture 'missing.exe'), $settingsPath)) {
    $rejected = $false
    try { [void](New-LauncherBrowserStartInfo $invalid 1080) } catch { $rejected = $true }
    if (-not $rejected) { throw "Invalid browser accepted: $invalid" }
}
$settings.browser.executable = ''
Save-LauncherSettings $settingsPath $settings
if ((Read-LauncherSettings $settingsPath).browser.executable -ne '') { throw 'Reset failed' }
'PASS: old settings, persistence, real EXE dispatch with Chinese/spaces, default, reset, missing/non-EXE rejection'
