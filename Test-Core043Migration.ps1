param([Parameter(Mandatory=$true)][string]$Root, [switch]$InjectFailure)
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
if([IO.Path]::GetFileName($Root) -notlike '*1.3.6_20260930'){throw 'Use the isolated verification copy only'}
if([IO.File]::ReadAllText((Join-Path $Root 'comfyui_version.py')) -notmatch '0.33.1'){throw 'Baseline must be 0.33.1'}
$python=Join-Path $Root '.ext/python.exe'
$before=& $python -s -m pip list --format=json --disable-pip-version-check
if($LASTEXITCODE){throw 'Baseline inventory failed'}
$updater=Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Core-Updater.ps1'
$temp=Join-Path $env:TEMP ('core043-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8=[Text.UTF8Encoding]::new($false)
if($InjectFailure){
    $code=[IO.File]::ReadAllText($updater)
    # Inject only after the production core-update health check has succeeded.
    $anchor='    Publish-Status `' + "`n" + '        -Stage "complete" `' + "`n" + '        -Message ("ComfyUI'
    $code=$code.Replace("`r`n","`n")
    if(-not $code.Contains($anchor)){throw 'Injection anchor missing'}
    $code=$code.Replace($anchor,('    throw "INJECTED_AFTER_REAL_HEALTH"'+"`n"+$anchor))
    $updater=Join-Path $temp 'fault.ps1'
    # The child process reads this BOM-free fixture explicitly as UTF-8.
    [IO.File]::WriteAllText($updater,$code,$utf8)
}
$id=[guid]::NewGuid().ToString('N')
$request=[ordered]@{
 root=$Root; pythonPath=$python; currentVersion='0.33.1'; targetVersion='0.43.0'
 sourceUrl='https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/v0.43.0.zip'
 sourceUrls=@('https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/v0.43.0.zip')
 pypiIndexUrl='https://pypi.org/simple'; proxyMode='custom'; proxyAddress='http://127.0.0.1'; proxyPort=7898
 statusPath=(Join-Path $Root "user/launcher/state/core043-$id.json")
 logPath=(Join-Path $Root "user/launcher/logs/core043-$id.log")
 workRoot=(Join-Path $Root ".cache/core043-$id")
 backupsRoot=(Join-Path $Root '.cache/core043-backups')
}
$requestPath=Join-Path $temp 'request.json'
[IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 5),$utf8)
$hashBefore=(Get-FileHash -LiteralPath (Join-Path $Root 'main.py')).Hash
$nodesBefore=@(Get-ChildItem -LiteralPath (Join-Path $Root 'custom_nodes') -Force | Select-Object Name,LastWriteTimeUtc)
# Explicit UTF-8 read supports the BOM-free fault fixture on Windows PS 5.1.
$env:CORE043_SCRIPT=$updater; $env:CORE043_REQUEST=$requestPath
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '& ([scriptblock]::Create([IO.File]::ReadAllText($env:CORE043_SCRIPT,[Text.Encoding]::UTF8))) -RequestPath $env:CORE043_REQUEST'
$exit=$LASTEXITCODE
$status=[IO.File]::ReadAllText($request.statusPath)|ConvertFrom-Json
if($InjectFailure){
 if($exit -eq 0 -or $status.error -notmatch 'INJECTED_AFTER_REAL_HEALTH' -or -not $status.rollbackPerformed){throw ('Failure test did not reach rollback: '+$status.error)}
 $after=& $python -s -m pip list --format=json --disable-pip-version-check
 if($LASTEXITCODE -or ($before -join '') -cne ($after -join '')){throw 'Distribution inventory not restored'}
 if((Get-FileHash -LiteralPath (Join-Path $Root 'main.py')).Hash -ne $hashBefore){throw 'Core not restored'}
} else {
 if($exit -ne 0 -or -not $status.success){throw ('Core upgrade failed: '+$status.error)}
 if([IO.File]::ReadAllText((Join-Path $Root 'comfyui_version.py')) -notmatch '0\.43\.0'){throw 'Target core version missing'}
 $after=& $python -s -m pip list --format=json --disable-pip-version-check
 if($LASTEXITCODE){throw 'Final inventory failed'}
 $oldPackages=($before -join '')|ConvertFrom-Json
 $newPackages=($after -join '')|ConvertFrom-Json
 foreach($package in $oldPackages){
  if($package.name -match '^(torch|torchvision|torchaudio|xformers|triton(?:-.*)?|nvidia-.*)$'){
   $found=@($newPackages|Where-Object {$_.name -eq $package.name})
   if($found.Count -ne 1 -or $found[0].version -cne $package.version){throw ('Runtime package changed: '+$package.name)}
  }
 }
}
$nodesAfter=@(Get-ChildItem -LiteralPath (Join-Path $Root 'custom_nodes') -Force | Select-Object Name,LastWriteTimeUtc)
if(Compare-Object $nodesBefore $nodesAfter -Property Name,LastWriteTimeUtc){throw 'Extension directories changed'}
[pscustomobject]@{Result='OK';InjectedFailure=[bool]$InjectFailure;Status=$request.statusPath;Log=$request.logPath;ExtensionsUnchanged=$true;InventoryRestored=([bool]$InjectFailure)}|ConvertTo-Json
