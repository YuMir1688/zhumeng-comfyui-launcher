param([Parameter(Mandatory=$true)][string]$Python)
$ErrorActionPreference='Stop'
if($Python -notlike '*1.3.6_20260930*'){throw 'Isolated test Python required'}
$code=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Core-Updater.ps1'))
. ([scriptblock]::Create($code.Substring($code.IndexOf('$ErrorActionPreference'),$code.IndexOf('if ($SelfTest)')-$code.IndexOf('$ErrorActionPreference'))))
$baseline=Get-InstalledPythonPackageMap $Python
if($baseline.ContainsKey('codex-launcher-rollback-probe')){throw 'Probe already present'}
$stage=Join-Path $env:TEMP ('added-dependency-'+[guid]::NewGuid().ToString('N'))
$wheels=Join-Path $stage 'target'; $oldWheels=Join-Path $stage 'rollback'
[void][IO.Directory]::CreateDirectory($wheels); [void][IO.Directory]::CreateDirectory($oldWheels)
$wheel=Join-Path $wheels 'codex_launcher_rollback_probe-1.0.0-py3-none-any.whl'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::Open($wheel,'Create')
try{
 $entries=@{
 'codex_launcher_rollback_probe.py'="VALUE = 1`n"
 'codex_launcher_rollback_probe-1.0.0.dist-info/METADATA'="Metadata-Version: 2.1`nName: codex-launcher-rollback-probe`nVersion: 1.0.0`n"
 'codex_launcher_rollback_probe-1.0.0.dist-info/WHEEL'="Wheel-Version: 1.0`nGenerator: local-test`nRoot-Is-Purelib: true`nTag: py3-none-any`n"
 }
 $entries['codex_launcher_rollback_probe-1.0.0.dist-info/RECORD']=((@($entries.Keys | ForEach-Object { $_+',,' })+@('codex_launcher_rollback_probe-1.0.0.dist-info/RECORD,,')) -join "`n")+"`n"
 foreach($key in $entries.Keys){$writer=[IO.StreamWriter]::new($zip.CreateEntry($key).Open(),$script:utf8); try{$writer.Write($entries[$key])}finally{$writer.Dispose()}}
}finally{$zip.Dispose()}
$targetPins=Join-Path $stage 'target.txt'; $oldPins=Join-Path $stage 'old.txt'; $manifest=Join-Path $stage 'manifest.json'
[IO.File]::WriteAllText($targetPins,'codex-launcher-rollback-probe==1.0.0',$script:utf8)
[IO.File]::WriteAllText($oldPins,'',$script:utf8)
Write-Utf8Atomic $manifest (@([ordered]@{set='target';file=[IO.Path]::GetFileName($wheel);sha256=(Get-FileHash $wheel).Hash})|ConvertTo-Json)
$tx=[pscustomobject]@{AddedPackageNames=@('codex-launcher-rollback-probe');RollbackRequirementsPath=$oldPins;RollbackWheelDirectory=$oldWheels;WheelManifestPath=$manifest}
try{
 Invoke-PreparedDependencySet $Python $targetPins $wheels 'Test new dependency'
 if(-not (Get-InstalledPythonPackageMap $Python).ContainsKey('codex-launcher-rollback-probe')){throw 'Install not exercised'}
}finally{Invoke-DependencyRepairRollback $Python $tx}
$after=Get-InstalledPythonPackageMap $Python
if($after.Count -ne $baseline.Count){throw 'Inventory count mismatch'}
foreach($key in $baseline.Keys){if(-not $after.ContainsKey($key) -or $after[$key].Version -cne $baseline[$key].Version){throw "Inventory mismatch: $key"}}
Remove-TreeWithoutFollowingReparse $stage ([IO.Path]::GetTempPath())
'PASS: actual new wheel installed, rolled back without old wheels, all distribution versions unchanged'
