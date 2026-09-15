param([string]$PythonPath = (Get-Command python.exe -ErrorAction Stop).Source)
$ErrorActionPreference='Stop'
foreach($worker in @('ComfyUI-Core-Updater.ps1','ComfyUI-Extension-Worker.ps1')) {
 $path=Join-Path $PSScriptRoot ('launcher/tools/' + $worker)
 $job=Start-Job -ArgumentList $path,$PythonPath -ScriptBlock {
  param($path,$python)
  $ErrorActionPreference='Stop'
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
  foreach($name in @('Quote-ProcessArgument','ConvertTo-WindowsCommandLineArgument','Invoke-CapturedProcess')) {
   $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
   if($null -ne $fn){ . ([scriptblock]::Create($fn.Extent.Text)) }
  }
  function Write-UpdateLog($Message) {}
  $result=Invoke-CapturedProcess -FilePath $python -Arguments @('-c',"import sys; print('PIPE_OK'); print(len(sys.stdin.read()))") -WorkingDirectory ([IO.Path]::GetDirectoryName($python)) -TimeoutSeconds 10
  if($result.ExitCode -ne 0 -or $result.StdOut -notmatch 'PIPE_OK' -or $result.StdOut -notmatch '0'){throw 'Background Python failed'}
  'Background Python stdin EOF verified'
 }
 try {
  $job|Wait-Job -Timeout 25|Out-Null
  Receive-Job $job -ErrorAction Stop
  if($job.State -ne 'Completed'){throw "Worker test failed: $worker"}
 } finally {Remove-Job $job -Force}
}
