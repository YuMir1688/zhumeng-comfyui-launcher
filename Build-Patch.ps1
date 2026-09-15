param([string]$Version = '1.3.2')
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$source = Join-Path $repo 'launcher'
if (([IO.File]::ReadAllText((Join-Path $source 'tools/launcher-version.json')) | ConvertFrom-Json).version -ne $Version) { throw 'Source version does not match requested patch version' }
$dist = Join-Path $repo 'dist'
[void][IO.Directory]::CreateDirectory($dist)
$stage = Join-Path $dist ('stage-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stage)
& (Join-Path $source 'tools/Build-PortableLauncher.ps1') -Root $source
if ([Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $source '启动_ComfyUI.exe')).FileVersion -ne ($Version + '.0')) { throw 'Executable version does not match launcher-version.json' }
$paths = @(
    '启动_ComfyUI.exe', 'tools/ComfyUI-Launcher.ps1', 'tools/ComfyUI-Launcher.xaml',
    'tools/ComfyUI-Launcher.Services.psm1', 'tools/ComfyUI-Core-Updater.ps1',
    'tools/ComfyUI-Extension-Worker.ps1', 'tools/Update-Launcher.ps1',
    'tools/launcher-version.json'
    'tools/PortableLauncher.cs'
)
$files = foreach ($relative in $paths) {
    $path = Join-Path $source $relative
    $target = Join-Path $stage $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Copy($path, $target)
    [ordered]@{path=$relative; sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $stage 'patch.json'), ([ordered]@{version=$Version; files=@($files)} | ConvertTo-Json -Depth 5), $utf8)
$archive = Join-Path $dist "zhumeng-launcher-$Version.zip"
if (Test-Path -LiteralPath $archive) { throw "Output already exists: $archive" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::Open($archive, 'Create')
try {
    foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
        $relative = $file.FullName.Substring($stage.Length + 1).Replace('\','/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$file.FullName,$relative)
    }
} finally { $zip.Dispose() }
$manifest = [ordered]@{
    schemaVersion=1; version=$Version; minimumVersion='1.3.0'
    url="https://github.com/YuMir1688/zhumeng-comfyui-launcher/releases/download/v$Version/zhumeng-launcher-$Version.zip"
    sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
}
[IO.File]::WriteAllText((Join-Path $dist 'launcher-update.json'), ($manifest | ConvertTo-Json), $utf8)
# First-time installer loads this script fully before patching the tools folder.
[IO.File]::Copy((Join-Path $source 'tools/Update-Launcher.ps1'), (Join-Path $dist 'Update-Launcher.ps1'), $true)
Write-Output $archive
$bootstrap = Join-Path $dist ('bootstrap-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($bootstrap)
foreach ($name in @("zhumeng-launcher-$Version.zip", 'launcher-update.json', 'Update-Launcher.ps1')) {
    [IO.File]::Copy((Join-Path $dist $name),(Join-Path $bootstrap $name))
}
[IO.File]::WriteAllText((Join-Path $bootstrap 'Install-Launcher-Update.cmd'), ([IO.File]::ReadAllText((Join-Path $repo 'Install-Launcher-Update.cmd')) -replace 'zhumeng-launcher-\d+\.\d+\.\d+\.zip',"zhumeng-launcher-$Version.zip"), [Text.Encoding]::ASCII)
$bootstrapZip = Join-Path $dist "zhumeng-first-update-$Version.zip"
if (Test-Path -LiteralPath $bootstrapZip) { throw "Output already exists: $bootstrapZip" }
[IO.Compression.ZipFile]::CreateFromDirectory($bootstrap,$bootstrapZip)
Write-Output $bootstrapZip
