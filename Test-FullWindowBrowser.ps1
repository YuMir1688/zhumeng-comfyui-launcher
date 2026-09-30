$ErrorActionPreference='Stop'
$fixture=Join-Path $PSScriptRoot ('test-artifacts/browser-window-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'launcher/tools') -Destination $fixture -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'launcher/assets') -Destination $fixture -Recurse
[void][IO.Directory]::CreateDirectory((Join-Path $fixture '.ext'))
[IO.File]::WriteAllText((Join-Path $fixture '.ext/python.exe'),'fixture only - never executed')
[IO.File]::WriteAllText((Join-Path $fixture 'main.py'),'# fixture only')
[IO.File]::WriteAllText((Join-Path $fixture 'comfyui_version.py'),'__version__ = "0.35.0"')
$exe=Join-Path $fixture 'browser probe.exe'
Add-Type -TypeDefinition 'using System; using System.IO; public class WindowBrowserProbe { public static void Main(string[] a) { File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"url.txt"), string.Join("\n",a)); } }' -OutputAssembly $exe -OutputType ConsoleApplication
$source=Join-Path $fixture 'tools/ComfyUI-Launcher.ps1'
$content=[IO.File]::ReadAllText($source)
$injection=@'
function Test-ShouldAutoCheckUpdates { return $false }
$script:fixtureFailure=$null
$script:fixtureTicks=0
$script:fixtureTimer=[Windows.Threading.DispatcherTimer]::new()
$script:fixtureTimer.Interval=[TimeSpan]::FromSeconds(1)
$script:fixtureTimer.Add_Tick({
    $script:fixtureTicks++
    try {
        if ($script:fixtureTicks -eq 1) {
            Show-LauncherPage $script:PageAdvanced $script:NavAdvanced
            $exe=Join-Path $script:root 'browser probe.exe'
            Set-PreferredBrowser $exe
            if ((Read-LauncherSettings $script:settingsPath).browser.executable -ne $exe) { throw 'UI preference was not saved' }
            if ($script:BrowserPathText.Text -ne $exe) { throw 'UI preference label incorrect' }
            $script:activePort=1087
            Open-ComfyUIWeb
            return
        }
        if ([IO.File]::ReadAllText((Join-Path $script:root 'url.txt')) -ne 'http://127.0.0.1:1087') { throw 'Full UI URL dispatch failed' }
        $script:BtnDefaultBrowser.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        if ((Read-LauncherSettings $script:settingsPath).browser.executable -ne '') { throw 'Reset button failed' }
    } catch { $script:fixtureFailure=$_ }
    $script:fixtureTimer.Stop()
    $script:window.Close()
})
$script:fixtureTimer.Start()
'@
$anchor='$pollTimer = New-Object System.Windows.Threading.DispatcherTimer'
if (-not $content.Contains($anchor)) { throw 'Missing fixture anchor' }
$content=$content.Replace($anchor,($injection + "`r`n" + $anchor))
$content += "`r`nif (`$script:fixtureFailure) { throw `$script:fixtureFailure }; if (`$script:fixtureTicks -lt 2) { throw 'Early UI exit' }; 'PASS: full window selection/save/open/reset callbacks'"
[IO.File]::WriteAllText($source,$content,[Text.UTF8Encoding]::new($true))
& powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $source
if ($LASTEXITCODE -ne 0) { throw 'Full browser window test failed' }
