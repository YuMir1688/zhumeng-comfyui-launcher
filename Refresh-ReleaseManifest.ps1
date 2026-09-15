param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
if(-not (Test-Path -LiteralPath (Join-Path $Root '.ext/python.exe'))){throw 'Not a package root'}
if(Test-Path -LiteralPath (Join-Path $Root '.cache')){throw 'Use only on a clean release, not a running package'}
$utf8=New-Object Text.UTF8Encoding($false)
$infoPath=Join-Path $Root 'release-info.json'
$checksumPath=Join-Path $Root 'release-checksums.sha256'
$info=[IO.File]::ReadAllText($infoPath)|ConvertFrom-Json
$info.launcherVersion=([IO.File]::ReadAllText((Join-Path $Root 'tools/launcher-version.json'))|ConvertFrom-Json).version
$files=@(Get-ChildItem -LiteralPath $Root -Force -File -Recurse)
$info.fileCount=$files.Count
$info.bytes=[long](($files|Where-Object {$_.Name -notin 'release-info.json','release-checksums.sha256'}|Measure-Object Length -Sum).Sum)
$info.createdAtUtc=[DateTimeOffset]::UtcNow.ToString('o')
function Write-Manifest([string]$Path,[string]$Text) {
    $attributes=[IO.File]::GetAttributes($Path)
    try {
        [IO.File]::SetAttributes($Path,[IO.FileAttributes]::Normal)
        [IO.File]::WriteAllText($Path,$Text,$utf8)
    } finally { [IO.File]::SetAttributes($Path,$attributes) }
}
Write-Manifest $infoPath ($info|ConvertTo-Json -Depth 6)
$lines=foreach($line in [IO.File]::ReadAllLines($checksumPath)){
    if($line -notmatch '^[a-fA-F0-9]{64} \*(.+)$'){throw 'Invalid existing checksum line'}
    $relative=$Matches[1]
    $full=[IO.Path]::GetFullPath((Join-Path $Root $relative))
    if(-not $full.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Checksum path outside root'}
    (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()+' *'+$relative
}
Write-Manifest $checksumPath (($lines -join [Environment]::NewLine)+[Environment]::NewLine)
Write-Output ('Manifest refreshed: '+$info.launcherVersion)
