param([string]$PythonPath = (Get-Command python.exe -ErrorAction Stop).Source)
$ErrorActionPreference = 'Stop'
$worker = Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Core-Updater.ps1'
$job = Start-Job -ArgumentList $worker,$PythonPath -ScriptBlock {
    param($worker,$python)
    $ErrorActionPreference='Stop'
    $t=$null;$e=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($worker,[ref]$t,[ref]$e)
    if ($e.Count) { throw $e[0] }
    foreach($name in @('Quote-ProcessArgument','ConvertTo-WindowsCommandLineArgument','Invoke-CapturedProcess')) {
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        if ($fn) { . ([scriptblock]::Create($fn.Extent.Text)) }
    }
    function Write-UpdateLog($Message) {}
    $script:messages = New-Object Collections.Generic.List[string]
    function Publish-Status($Stage,$Message) { $script:messages.Add($Message) }
    $r=Invoke-CapturedProcess -FilePath $python -Arguments @('-u','-c',"import time,sys; print('Collecting test_package'); print('stderr OK',file=sys.stderr); time.sleep(6); print('TAIL',end='')") -WorkingDirectory ([IO.Path]::GetDirectoryName($python)) -TimeoutSeconds 15 -StatusStage dependencies -StatusMessage 'Checking'
    if ($r.ExitCode -ne 0 -or $r.StdOut -notmatch 'TAIL' -or $r.StdErr -notmatch 'stderr OK') { throw 'Pipe output lost' }
    if (-not ($script:messages -match 'Collecting test_package')) { throw 'No live package progress before exit' }
    $r=Invoke-CapturedProcess -FilePath $python -Arguments @('-u','-c',"import sys; [(print('x'*200),print('y'*200,file=sys.stderr)) for _ in range(3000)]") -WorkingDirectory ([IO.Path]::GetDirectoryName($python)) -TimeoutSeconds 20
    if ($r.ExitCode -ne 0 -or $r.StdOut.Length -lt 600000 -or $r.StdErr.Length -lt 600000) { throw 'Concurrent large output lost' }
    $timedOut=$false
    try { Invoke-CapturedProcess -FilePath $python -Arguments @('-c','import time;time.sleep(10)') -WorkingDirectory ([IO.Path]::GetDirectoryName($python)) -TimeoutSeconds 1 | Out-Null } catch { $timedOut=$true }
    if (-not $timedOut) { throw 'Timeout guard failed' }
    'PASS: background live progress, unterminated final line, both large pipes, timeout guard'
}
try {
    $job | Wait-Job -Timeout 55 | Out-Null
    Receive-Job $job -ErrorAction Stop
    if ($job.State -ne 'Completed') { throw 'Progress test failed' }
} finally { Remove-Job $job -Force }
