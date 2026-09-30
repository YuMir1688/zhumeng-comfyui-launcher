$ErrorActionPreference='Stop'
$worker=Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Core-Updater.ps1'
$destination=Join-Path $PSScriptRoot ('test-artifacts/stall-' + [guid]::NewGuid().ToString('N') + '.part')
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$port=$listener.LocalEndpoint.Port
$accept=$listener.AcceptTcpClientAsync()
$job=Start-Job -ArgumentList $worker,$destination,$port -ScriptBlock {
    param($worker,$destination,$port)
    $ErrorActionPreference='Stop'
    $t=$null;$e=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($worker,[ref]$t,[ref]$e)
    foreach($name in @('New-UpdateHttpClient','Assert-DownloadedArchiveEnvelope','Invoke-UpdateArchiveDownloadAttempt','Test-TransientArchiveDownloadError')) {
        $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    function Publish-Status($Stage,$Message,$Percent) {}
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $failed=$false
    try { Invoke-UpdateArchiveDownloadAttempt -Uri "http://127.0.0.1:$port/test.zip" -DestinationPath $destination -ProxyMode none -ReadTimeoutSeconds 1 | Out-Null }
    catch {
        if (-not (Test-TransientArchiveDownloadError $_)) { throw 'Stall did not qualify for retry' }
        if ($_.Exception.Message -notlike '*未收到数据*') { throw }
        $failed=$true
    }
    if (-not $failed -or $timer.Elapsed.TotalSeconds -gt 10) { throw 'Body stall timeout ineffective' }
    'PASS: HTTP headers succeeded but stalled body was interrupted and classified for retry'
}
$client=$null
try {
    if (-not $accept.Wait(15000)) { throw 'Test client failed to connect' }
    $client=$accept.GetAwaiter().GetResult()
    $bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 100000`r`nConnection: close`r`n`r`n")
    $client.GetStream().Write($bytes,0,$bytes.Length)
    $job | Wait-Job -Timeout 15 | Out-Null
    Receive-Job $job -ErrorAction Stop
    if ($job.State -ne 'Completed') { throw 'Stall test did not finish' }
} finally {
    if ($client) {$client.Dispose()}
    $listener.Stop()
    Remove-Job $job -Force
}
