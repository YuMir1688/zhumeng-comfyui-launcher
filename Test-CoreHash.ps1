param()
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Core-Updater.ps1'
$job = Start-Job -ArgumentList $path -ScriptBlock {
    param($path)
    $ErrorActionPreference = 'Stop'
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-FileHash'},$true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $PSModuleAutoLoadingPreference='None'
    $testFile=[IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($testFile,'abc',[Text.UTF8Encoding]::new($false))
        $hash=(Get-FileHash -LiteralPath $testFile -Algorithm SHA256).Hash
        if ($hash -ne 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD') { throw 'SHA256 mismatch' }
    } finally { [IO.File]::Delete($testFile) }
    'Background SHA256 without module autoload: OK'
}
try {
    $job | Wait-Job -Timeout 30 | Out-Null
    Receive-Job $job -ErrorAction Stop
    if ($job.State -ne 'Completed') { throw 'Background checksum test failed' }
} finally { Remove-Job $job -Force }
