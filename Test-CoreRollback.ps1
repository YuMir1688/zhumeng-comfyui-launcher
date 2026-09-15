param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
$python=Join-Path $root '.ext/python.exe'
$utf8=New-Object Text.UTF8Encoding($false)
$before=& $python -s -m pip list --format=json --disable-pip-version-check
if($LASTEXITCODE){throw 'Cannot enumerate baseline'}
$updater=Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Core-Updater.ps1'
$code=[IO.File]::ReadAllText($updater)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
$health=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CoreHealthCheck'},$false)
$code=$code.Substring(0,$health.Extent.StartOffset) + 'function Invoke-CoreHealthCheck { throw "INJECTED_HEALTH_FAILURE" }' + $code.Substring($health.Extent.EndOffset)
$testScript=Join-Path $root 'failure-fixture.ps1'
[IO.File]::WriteAllText($testScript,$code,(New-Object Text.UTF8Encoding($true)))
$request=[pscustomobject]@{
    root=$Root; pythonPath=$python; targetVersion=''; currentVersion=''; sourceUrl=''; sourceUrls=@()
    statusPath=''; logPath=''; workRoot=(Join-Path $Root '.cache/rollback-test')
    backupsRoot=(Join-Path $Root '.cache/backups'); pypiIndexUrl='https://pypi.tuna.tsinghua.edu.cn/simple'
    proxyMode='none'; proxyAddress=''; proxyPort=0
}
$request.targetVersion='0.33.1'; $request.currentVersion='0.35.0'
$request.sourceUrl='https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/v0.33.1.zip'
$request.sourceUrls=@($request.sourceUrl,('https://gh-proxy.com/'+$request.sourceUrl),('https://ghfast.top/'+$request.sourceUrl))
$request.statusPath=Join-Path $root 'rollback-status.json'
$request.logPath=Join-Path $root 'rollback-test.log'
$requestPath=Join-Path $root 'rollback-request.json'
[IO.File]::WriteAllText($requestPath,($request|ConvertTo-Json -Depth 5),$utf8)
$sentinels=foreach($name in @('models','custom_nodes','user','input','output')){
    $directory=Join-Path $root $name
    [void][IO.Directory]::CreateDirectory($directory)
    $path=Join-Path $directory 'regression-sentinel.txt'
    [IO.File]::WriteAllText($path,'must survive update rollback',$utf8)
    $path
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $testScript -RequestPath $requestPath
$exit=$LASTEXITCODE
$status=Get-Content $request.statusPath -Raw -Encoding UTF8|ConvertFrom-Json
if($exit -eq 0 -or $status.error -notmatch 'INJECTED_HEALTH_FAILURE' -or -not $status.rollbackPerformed){throw 'Rollback was not exercised'}
if((Get-Content (Join-Path $root 'comfyui_version.py') -Raw) -notmatch '0.35.0'){throw 'Core version was not restored'}
$after=& $python -s -m pip list --format=json --disable-pip-version-check
if($LASTEXITCODE -or ($before -join '') -cne ($after -join '')){throw 'Installed distributions were not restored exactly'}
foreach($path in $sentinels){if([IO.File]::ReadAllText($path) -cne 'must survive update rollback'){throw 'Protected data changed'}}
[IO.File]::WriteAllText((Join-Path $root 'rollback-result.json'),'{"result":"OK","coreRestored":"0.35.0","allDistributionVersionsRestored":true,"protectedDataPreserved":true}',$utf8)
Write-Output 'Actual core and dependency rollback: OK'
