param()
$ErrorActionPreference='Stop'
$base=Join-Path $PSScriptRoot ('test-artifacts/patch-' + [Guid]::NewGuid().ToString('N'))
$utf8=New-Object Text.UTF8Encoding($false)
$archive=Join-Path $PSScriptRoot 'dist/zhumeng-launcher-1.3.1.zip'
$manifest=Join-Path $PSScriptRoot 'dist/launcher-update.json'
$updater=Join-Path $PSScriptRoot 'launcher/tools/Update-Launcher.ps1'
function New-Fixture([string]$Name) {
    $path=Join-Path $base $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $path '.ext'))
    [void][IO.Directory]::CreateDirectory((Join-Path $path 'tools'))
    [IO.File]::WriteAllText((Join-Path $path '.ext/python.exe'),'test placeholder only',$utf8)
    [IO.File]::WriteAllText((Join-Path $path 'tools/launcher-version.json'),'{"version":"1.3.0"}',$utf8)
    [IO.File]::WriteAllText((Join-Path $path 'tools/ComfyUI-Launcher.xaml'),'old fixture',$utf8)
    return $path
}
$normal=New-Fixture '中文 路径成功'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -Root $normal -LocalArchive $archive -LocalManifest $manifest -NonInteractive
if($LASTEXITCODE -ne 0){throw 'Patch installation failed'}
$version=[IO.File]::ReadAllText((Join-Path $normal 'tools/launcher-version.json'))|ConvertFrom-Json
if($version.version -ne '1.3.1'){throw 'Version was not updated'}
$failed=New-Fixture '锁定文件回滚'
$lockedPath=Join-Path $failed 'tools/ComfyUI-Launcher.xaml'
$locked=[IO.File]::Open($lockedPath,'Open','Read','Read')
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -Root $failed -LocalArchive $archive -LocalManifest $manifest -NonInteractive
    if($LASTEXITCODE -eq 0){throw 'Locked file should fail'}
} finally { $locked.Dispose() }
if([IO.File]::ReadAllText($lockedPath) -ne 'old fixture'){throw 'Original file damaged'}
if(Test-Path -LiteralPath (Join-Path $failed '启动_ComfyUI.exe')){throw 'New file was not rolled back'}
$version=[IO.File]::ReadAllText((Join-Path $failed 'tools/launcher-version.json'))|ConvertFrom-Json
if($version.version -ne '1.3.0'){throw 'Failed update advanced version'}
$bad=New-Fixture '哈希错误'
$badManifest=Join-Path $base 'bad-manifest.json'
$data=[IO.File]::ReadAllText($manifest)|ConvertFrom-Json
$data.sha256='0'*64
[IO.File]::WriteAllText($badManifest,($data|ConvertTo-Json),$utf8)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $updater -Root $bad -LocalArchive $archive -LocalManifest $badManifest -NonInteractive
if($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath (Join-Path $bad '启动_ComfyUI.exe'))){throw 'Bad hash was not blocked'}
Write-Output '{"patchInstall":"OK","chineseSpacePath":"OK","lockedFileRollback":"OK","badHashBlocked":"OK"}'
exit 0
