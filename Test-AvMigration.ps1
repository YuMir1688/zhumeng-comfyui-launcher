param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
$code=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Core-Updater.ps1'))
Invoke-Expression $code.Substring($code.IndexOf('$ErrorActionPreference'),$code.IndexOf('if ($SelfTest)')-$code.IndexOf('$ErrorActionPreference'))
$python=Join-Path $Root '.ext/python.exe'
$stage=Join-Path $Root ('.cache/av-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($stage)
$old=Join-Path $stage 'old.txt'; $target=Join-Path $stage 'target.txt'
[IO.File]::WriteAllText($old,'av>=16.0.0',$script:utf8)
[IO.File]::WriteAllText($target,'av==17.0.0',$script:utf8)
$before=& $python -s -c "import importlib.metadata as m; print(m.version('av')); print(m.version('torch'))"
if($LASTEXITCODE){throw 'Version probe failed'}
$plan=Get-SafeRequirementMigrationPlan $old $target
$transaction=Invoke-DependencyMigrationPreflight -PythonPath $python -TargetRequirementsPath $target -BaselineRequirementsPath $old -IndexUrl 'https://pypi.tuna.tsinghua.edu.cn/simple' -Request ([pscustomobject]@{proxyMode='none';proxyAddress='';proxyPort=0}) -StageRoot $stage
if($transaction.Count -ne 1){throw 'Expected av migration'}
try {
    Invoke-PreparedDependencySet -PythonPath $python -RequirementsPath $transaction.TargetRequirementsPath -WheelDirectory $transaction.TargetWheelDirectory -StatusMessage 'Testing av target'
    $actual=& $python -s -c 'import av; print(av.__version__)'
    if($LASTEXITCODE -or $actual -ne '17.0.0'){throw 'av target import failed'}
} finally {
    Invoke-PreparedDependencySet -PythonPath $python -RequirementsPath $transaction.RollbackRequirementsPath -WheelDirectory $transaction.RollbackWheelDirectory -StatusMessage 'Testing av rollback'
}
$after=& $python -s -c "import importlib.metadata as m; print(m.version('av')); print(m.version('torch'))"
if($LASTEXITCODE -or ($before -join '') -cne ($after -join '')){throw 'av/torch restoration failed'}
Write-Output '{"avInstall":"17.0.0","avRollback":"OK","torchUnchanged":true}'
