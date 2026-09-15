param(
    [string]$RequestPath = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$script:utf8 = New-Object System.Text.UTF8Encoding($false)
$script:statusPath = ""
$script:logPath = ""
$script:targetVersion = ""
$script:currentStage = "idle"
$script:lastPercent = -1
$script:backupPath = ""
$script:downloadSha256 = ""
$script:downloadSourceUrl = ""
$script:rollbackPerformed = $false
$script:destructiveMaintenanceEnabled = $true

# Jobs may inherit a module search path without Microsoft.PowerShell.Utility.
# Keep checksum verification independent of cmdlet discovery; never skip it.
function Get-FileHash {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [ValidateSet('SHA256')][string]$Algorithm = 'SHA256'
    )
    $stream = [System.IO.File]::OpenRead($LiteralPath)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '')
        return [pscustomobject]@{ Algorithm = $Algorithm; Hash = $hash; Path = $LiteralPath }
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Get-CoreDirectoryNames {
    return @(
        "alembic_db",
        "api_server",
        "app",
        "blueprints",
        "comfy",
        "comfy_api",
        "comfy_api_nodes",
        "comfy_config",
        "comfy_execution",
        "comfy_extras",
        "middleware",
        "utils"
    )
}

function Get-CoreFileNames {
    return @(
        "alembic.ini",
        "comfyui_version.py",
        "cuda_malloc.py",
        "execution.py",
        "folder_paths.py",
        "hook_breaker_ac10a0.py",
        "latent_preview.py",
        "LICENSE",
        "main.py",
        "manager_requirements.txt",
        "nodes.py",
        "node_helpers.py",
        "openapi.yaml",
        "protocol.py",
        "pyproject.toml",
        "requirements.txt",
        "server.py"
    )
}

function Get-ProtectedNames {
    return @(
        ".cache",
        ".ext",
        ".msvc",
        "assets",
        "config",
        "custom_nodes",
        "docs",
        "git",
        "input",
        "models",
        "output",
        "styles",
        "temp",
        "tools",
        "user",
        "web",
        "extra_model_paths.yaml",
        "styles.csv",
        "使用说明.txt",
        "启动_ComfyUI.lnk"
    )
}

function Test-DirectChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $normalizedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\")
    return [System.IO.Path]::GetDirectoryName($normalizedPath).Equals(
        $normalizedParent,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $normalizedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\")
    if (-not $normalizedPath.StartsWith(
        $normalizedParent + "\",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "路径超出允许范围：$normalizedPath"
    }
    return $normalizedPath
}

function Remove-TreeWithoutFollowingReparse {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ApprovedRoot
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($ApprovedRoot).TrimEnd("\")
    $normalizedPath = Assert-ChildPath -Path $Path -Parent $normalizedRoot
    if (-not [System.IO.Directory]::Exists($normalizedPath)) {
        return
    }

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Path = $normalizedPath; Expanded = $false })
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $itemPath = Assert-ChildPath -Path ([string]$item.Path) -Parent $normalizedRoot
        $attributes = [System.IO.File]::GetAttributes($itemPath)
        $isReparse = (
            ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        )
        if ($isReparse) {
            [System.IO.Directory]::Delete($itemPath, $false)
            continue
        }

        if ([bool]$item.Expanded) {
            [System.IO.File]::SetAttributes(
                $itemPath,
                $attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            )
            [System.IO.Directory]::Delete($itemPath, $false)
            continue
        }

        $stack.Push([pscustomobject]@{ Path = $itemPath; Expanded = $true })
        foreach ($childPath in [System.IO.Directory]::EnumerateFileSystemEntries($itemPath)) {
            $childPath = Assert-ChildPath -Path $childPath -Parent $normalizedRoot
            $childAttributes = [System.IO.File]::GetAttributes($childPath)
            $isDirectory = (
                ($childAttributes -band [System.IO.FileAttributes]::Directory) -ne 0
            )
            $childIsReparse = (
                ($childAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            )
            if ($isDirectory) {
                if ($childIsReparse) {
                    [System.IO.Directory]::Delete($childPath, $false)
                }
                else {
                    $stack.Push([pscustomobject]@{ Path = $childPath; Expanded = $false })
                }
            }
            else {
                [System.IO.File]::SetAttributes(
                    $childPath,
                    $childAttributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                )
                [System.IO.File]::Delete($childPath)
            }
        }
    }
}

function Remove-SafePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ApprovedRoot
    )

    $normalizedPath = Assert-ChildPath -Path $Path -Parent $ApprovedRoot
    if ([System.IO.Directory]::Exists($normalizedPath)) {
        Remove-TreeWithoutFollowingReparse -Path $normalizedPath -ApprovedRoot $ApprovedRoot
    }
    elseif ([System.IO.File]::Exists($normalizedPath)) {
        $attributes = [System.IO.File]::GetAttributes($normalizedPath)
        [System.IO.File]::SetAttributes(
            $normalizedPath,
            $attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        )
        [System.IO.File]::Delete($normalizedPath)
    }
}

function Write-Utf8Atomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if (-not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    $temporaryPath = $Path + ".tmp-" + [Guid]::NewGuid().ToString("N")
    [System.IO.File]::WriteAllText($temporaryPath, $Text, $script:utf8)
    try {
        if ([System.IO.File]::Exists($Path)) {
            $backupPath = $Path + ".replace-bak"
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
            if ([System.IO.File]::Exists($backupPath)) {
                [System.IO.File]::Delete($backupPath)
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }
}

function ConvertTo-SafeMessage {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $safe = [regex]::Replace(
        $Text,
        "(?i)(https?://)([^/@:\s]+):([^/@\s]+)@",
        '$1***:***@'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?i)\b(token|password|passwd|cookie|authorization|api[_-]?key)\s*[:=]\s*[^\s;]+",
        '$1=***'
    )
    return $safe
}

function ConvertTo-UpdateError {
    param([object]$ErrorObject)

    if ($null -eq $ErrorObject) {
        return "更新过程中发生未知错误。"
    }
    $exception = $ErrorObject
    if ($null -ne $ErrorObject.Exception) {
        $exception = $ErrorObject.Exception
    }
    try {
        $baseException = $exception.GetBaseException()
        if ($null -ne $baseException) {
            $exception = $baseException
        }
    }
    catch {
    }
    $message = ConvertTo-SafeMessage ([string]$exception.Message)
    $lower = $message.ToLowerInvariant()
    if ($lower -match "外部进程执行超时") {
        return "依赖处理超时。请检查 PyPI 镜像或代理后重试；本次尚未写入核心文件。"
    }
    if ($exception -is [System.Threading.Tasks.TaskCanceledException] -or
        $lower -match "timed out|timeout|超时") {
        return "请求超时。"
    }
    if ($lower -match "name resolution|no such host|resolve|dns|找不到.*主机") {
        return "域名无法解析。"
    }
    if ($lower -match "proxy|407|代理") {
        return "代理连接失败。"
    }
    if ($lower -match "certificate|ssl|tls|secure channel|证书") {
        return "TLS 证书错误。"
    }
    if ($lower -match "refused|actively refused|connection.*failed|无法连接|发送请求时出错") {
        return "服务器连接失败。"
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        return "更新过程中发生未知错误。"
    }
    return $message
}

function Write-UpdateLog {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:logPath)) {
        return
    }
    $parent = [System.IO.Path]::GetDirectoryName($script:logPath)
    if (-not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    $line = "[{0}] {1}{2}" -f (
        [DateTimeOffset]::Now.ToString("yyyy-MM-dd HH:mm:ss zzz"),
        (ConvertTo-SafeMessage $Message),
        [Environment]::NewLine
    )
    [System.IO.File]::AppendAllText($script:logPath, $line, $script:utf8)
}

function Publish-Status {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Percent = -1,
        [bool]$Completed = $false,
        [bool]$Success = $false,
        [string]$ErrorMessage = ""
    )

    $script:currentStage = $Stage
    $script:lastPercent = $Percent
    if ([string]::IsNullOrWhiteSpace($script:statusPath)) {
        return
    }
    $status = [ordered]@{
        schemaVersion = 1
        stage = $Stage
        message = ConvertTo-SafeMessage $Message
        percent = $Percent
        completed = $Completed
        success = $Success
        targetVersion = $script:targetVersion
        backupPath = $script:backupPath
        archiveSha256 = $script:downloadSha256
        rollbackPerformed = $script:rollbackPerformed
        error = ConvertTo-SafeMessage $ErrorMessage
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    }
    Write-Utf8Atomic -Path $script:statusPath -Text (
        $status | ConvertTo-Json -Depth 5 -Compress
    )
    Write-UpdateLog ("{0}: {1}" -f $Stage, $Message)
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        throw "请求文件不存在。"
    }
    $json = [System.IO.File]::ReadAllText($Path, $script:utf8)
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "请求文件为空。"
    }
    return $json | ConvertFrom-Json
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "更新请求缺少字段：$Name"
    }
    return [string]$property.Value
}

function Test-HttpUrl {
    param([string]$Value)

    $uri = $null
    if (-not [System.Uri]::TryCreate($Value, [System.UriKind]::Absolute, [ref]$uri)) {
        return $false
    }
    return (
        $uri.Scheme -in @("http", "https") -and
        -not [string]::IsNullOrWhiteSpace($uri.Host) -and
        [string]::IsNullOrEmpty($uri.UserInfo)
    )
}

function New-UpdateHttpClient {
    param(
        [string]$ProxyMode,
        [string]$ProxyAddress,
        [int]$ProxyPort
    )

    Add-Type -AssemblyName System.Net.Http
    [System.Net.ServicePointManager]::SecurityProtocol = (
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls12
    )
    $handler = New-Object System.Net.Http.HttpClientHandler
    switch ($ProxyMode) {
        "none" {
            $handler.UseProxy = $false
        }
        "custom" {
            if ([string]::IsNullOrWhiteSpace($ProxyAddress) -or
                $ProxyPort -lt 1 -or $ProxyPort -gt 65535) {
                throw "自定义代理地址或端口无效。"
            }
            $address = $ProxyAddress.Trim()
            if ($address -notmatch "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
                $address = "http://" + $address
            }
            $builder = New-Object System.UriBuilder($address)
            $builder.Port = $ProxyPort
            $builder.UserName = ""
            $builder.Password = ""
            $handler.UseProxy = $true
            $handler.Proxy = New-Object System.Net.WebProxy($builder.Uri, $true)
        }
        default {
            $handler.UseProxy = $true
            $handler.Proxy = [System.Net.WebRequest]::DefaultWebProxy
        }
    }

    $client = New-Object System.Net.Http.HttpClient($handler, $true)
    # A source archive is currently only a few megabytes.  A one-minute
    # ceiling keeps a dead route from making students wait indefinitely;
    # Download-UpdateArchiveWithFallback will then try the next safe route.
    $client.Timeout = [TimeSpan]::FromMinutes(1)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("ComfyUI-Desktop-Launcher/1.0")
    $client.DefaultRequestHeaders.Accept.ParseAdd("application/octet-stream")
    return $client
}

function Test-TransientArchiveDownloadError {
    param([object]$ErrorObject)

    if ($null -eq $ErrorObject) {
        return $false
    }
    $exception = $ErrorObject
    $exceptionProperty = $ErrorObject.PSObject.Properties["Exception"]
    if ($null -ne $exceptionProperty -and $null -ne $exceptionProperty.Value) {
        $exception = $exceptionProperty.Value
    }
    try {
        $baseException = $exception.GetBaseException()
        if ($null -ne $baseException) {
            $exception = $baseException
        }
    }
    catch {
    }
    Add-Type -AssemblyName System.Net.Http
    if ($exception -is [System.Net.Http.HttpRequestException] -or
        $exception -is [System.IO.IOException] -or
        $exception -is [System.IO.InvalidDataException] -or
        $exception -is [System.Threading.Tasks.TaskCanceledException]) {
        return $true
    }
    $message = ([string]$exception.Message).ToLowerInvariant()
    return (
        $message -match (
            "unexpected.*eof|unexpected end|0 bytes|connection.*reset|" +
            "forcibly closed|transport stream|response ended prematurely|" +
            "请求超时|连接.*中断|连接.*重置"
        )
    )
}

function Assert-DownloadedArchiveEnvelope {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$DownloadedBytes,
        [Nullable[long]]$ExpectedBytes
    )

    if (-not [System.IO.File]::Exists($Path) -or $DownloadedBytes -lt 1024) {
        throw (New-Object System.IO.InvalidDataException(
            "下载得到的源码归档为空或过小。"
        ))
    }
    if ($null -ne $ExpectedBytes -and
        [long]$ExpectedBytes -gt 0 -and
        $DownloadedBytes -ne [long]$ExpectedBytes) {
        throw (New-Object System.IO.IOException(
            (
                "下载连接提前结束：应接收 {0} 字节，实际接收 {1} 字节。" -f
                [long]$ExpectedBytes,
                $DownloadedBytes
            )
        ))
    }

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        if ($archive.Entries.Count -lt 10) {
            throw (New-Object System.IO.InvalidDataException(
                "下载得到的源码归档内容不完整。"
            ))
        }
    }
    catch [System.IO.InvalidDataException] {
        throw
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Invoke-UpdateArchiveDownloadAttempt {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [string]$ProxyMode,
        [string]$ProxyAddress,
        [int]$ProxyPort
    )

    $client = New-UpdateHttpClient $ProxyMode $ProxyAddress $ProxyPort
    $response = $null
    $inputStream = $null
    $outputStream = $null
    [long]$downloaded = 0
    [Nullable[long]]$totalLength = $null
    try {
        $response = $client.GetAsync(
            $Uri,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        if ($null -ne $response.Content.Headers.ContentLength) {
            $totalLength = [long]$response.Content.Headers.ContentLength
        }
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = New-Object System.IO.FileStream(
            $DestinationPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $buffer = New-Object byte[] 131072
        $lastPublish = [DateTimeOffset]::MinValue
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
            $downloaded += $read
            if (([DateTimeOffset]::UtcNow - $lastPublish).TotalMilliseconds -ge 350) {
                $percent = -1
                if ($null -ne $totalLength -and [long]$totalLength -gt 0) {
                    $percent = [Math]::Min(
                        99,
                        [int][Math]::Floor(($downloaded * 100.0) / [long]$totalLength)
                    )
                }
                Publish-Status `
                    -Stage "download" `
                    -Message "正在下载官方源码归档…" `
                    -Percent $percent
                $lastPublish = [DateTimeOffset]::UtcNow
            }
        }
        $outputStream.Flush()
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $inputStream) {
            $inputStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
        $client.Dispose()
    }

    Assert-DownloadedArchiveEnvelope `
        -Path $DestinationPath `
        -DownloadedBytes $downloaded `
        -ExpectedBytes $totalLength
    return $downloaded
}

function Download-UpdateArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][object]$Request
    )

    if (-not (Test-HttpUrl $Uri)) {
        throw "源码下载地址无效。"
    }
    $proxyMode = [string]$Request.proxyMode
    $proxyAddress = [string]$Request.proxyAddress
    $proxyPort = [int]$Request.proxyPort
    $partialPath = $DestinationPath + ".part"
    $maximumAttempts = 2
    $lastFailure = ""
    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        if ([System.IO.File]::Exists($partialPath)) {
            [System.IO.File]::Delete($partialPath)
        }
        try {
            Publish-Status `
                -Stage "download" `
                -Message (
                    "正在下载官方源码归档（第 {0}/{1} 次）…" -f
                    $attempt,
                    $maximumAttempts
                ) `
                -Percent -1
            [long]$downloaded = Invoke-UpdateArchiveDownloadAttempt `
                -Uri $Uri `
                -DestinationPath $partialPath `
                -ProxyMode $proxyMode `
                -ProxyAddress $proxyAddress `
                -ProxyPort $proxyPort
            Write-UpdateLog (
                "源码归档下载成功：第 {0}/{1} 次尝试，共 {2} 字节。" -f
                $attempt,
                $maximumAttempts,
                $downloaded
            )
            if ([System.IO.File]::Exists($DestinationPath)) {
                [System.IO.File]::Delete($DestinationPath)
            }
            [System.IO.File]::Move($partialPath, $DestinationPath)
            break
        }
        catch {
            $lastFailure = ConvertTo-UpdateError $_
            Write-UpdateLog (
                "源码归档下载第 {0}/{1} 次尝试失败：{2}" -f
                $attempt,
                $maximumAttempts,
                $lastFailure
            )
            if ([System.IO.File]::Exists($partialPath)) {
                [System.IO.File]::Delete($partialPath)
            }
            if (-not (Test-TransientArchiveDownloadError $_) -or
                $attempt -ge $maximumAttempts) {
                throw (
                    "下载官方源码归档失败（已尝试 {0} 次）：{1}" -f
                    $attempt,
                    $lastFailure
                )
            }
            $delaySeconds = [int][Math]::Pow(2, $attempt - 1)
            Publish-Status `
                -Stage "download" `
                -Message (
                    "下载连接中断，{0} 秒后自动重试…" -f
                    $delaySeconds
                ) `
                -Percent -1
            Start-Sleep -Seconds $delaySeconds
        }
    }

    if (-not [System.IO.File]::Exists($DestinationPath)) {
        throw (
            "下载官方源码归档失败（已尝试 {0} 次）：{1}" -f
            $maximumAttempts,
            $lastFailure
        )
    }
    Publish-Status -Stage "download" -Message "源码归档下载完成。" -Percent 100
}

function Download-UpdateArchiveWithFallback {
    param(
        [Parameter(Mandatory = $true)][string[]]$Uris,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][object]$Request
    )

    $validUris = @(
        $Uris |
            Where-Object { Test-HttpUrl ([string]$_) } |
            Select-Object -Unique
    )
    if ($validUris.Count -eq 0) {
        throw "源码下载地址无效。"
    }

    $failures = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $validUris.Count; $index++) {
        $candidate = [string]$validUris[$index]
        $label = if ($index -eq 0) { "官方通道" } else { "备用通道 $index" }
        try {
            Publish-Status `
                -Stage "download" `
                -Message ("正在尝试{0}…" -f $label) `
                -Percent -1
            Download-UpdateArchive `
                -Uri $candidate `
                -DestinationPath $DestinationPath `
                -Request $Request
            $script:downloadSourceUrl = $candidate
            Write-UpdateLog ("源码下载通道成功：{0}" -f $candidate)
            return
        }
        catch {
            $safeFailure = ConvertTo-UpdateError $_
            $failures.Add(("{0}: {1}" -f $label, $safeFailure))
            Write-UpdateLog (
                "源码下载通道失败：{0}；{1}" -f
                $candidate,
                $safeFailure
            )
            if ([System.IO.File]::Exists($DestinationPath)) {
                [System.IO.File]::Delete($DestinationPath)
            }
        }
    }
    throw (
        "所有源码下载通道均失败。" +
        ($failures -join "；")
    )
}

function Expand-ValidatedZip {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not [System.IO.Directory]::Exists($DestinationPath)) {
        [void][System.IO.Directory]::CreateDirectory($DestinationPath)
    }
    $destinationRoot = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd("\")
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -lt 10) {
            throw "源码归档内容不完整。"
        }
        foreach ($entry in $archive.Entries) {
            $unixMode = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixMode -eq 0xA000) {
                throw "源码归档包含不允许的符号链接。"
            }
            $relative = $entry.FullName.Replace(
                [System.IO.Path]::AltDirectorySeparatorChar,
                [System.IO.Path]::DirectorySeparatorChar
            )
            $targetPath = [System.IO.Path]::GetFullPath((Join-Path $destinationRoot $relative))
            if (-not $targetPath.StartsWith(
                $destinationRoot + "\",
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                throw "源码归档包含不安全路径。"
            }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                if (-not [System.IO.Directory]::Exists($targetPath)) {
                    [void][System.IO.Directory]::CreateDirectory($targetPath)
                }
                continue
            }
            $parent = [System.IO.Path]::GetDirectoryName($targetPath)
            if (-not [System.IO.Directory]::Exists($parent)) {
                [void][System.IO.Directory]::CreateDirectory($parent)
            }
            $entryStream = $entry.Open()
            $fileStream = New-Object System.IO.FileStream(
                $targetPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            try {
                $entryStream.CopyTo($fileStream)
            }
            finally {
                $fileStream.Dispose()
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-CoreSourceRoot {
    param([Parameter(Mandatory = $true)][string]$ExtractRoot)

    foreach ($candidate in @(Get-ChildItem -LiteralPath $ExtractRoot -Directory -Force)) {
        if ([System.IO.File]::Exists((Join-Path $candidate.FullName "main.py")) -and
            [System.IO.File]::Exists((Join-Path $candidate.FullName "comfyui_version.py"))) {
            return $candidate.FullName
        }
    }
    throw "源码归档中未找到有效的 ComfyUI 根目录。"
}

function Get-VersionFromSource {
    param([Parameter(Mandatory = $true)][string]$SourceRoot)

    $versionPath = Join-Path $SourceRoot "comfyui_version.py"
    $text = [System.IO.File]::ReadAllText($versionPath, $script:utf8)
    $match = [regex]::Match($text, '__version__\s*=\s*["'']([^"'']+)["'']')
    if (-not $match.Success) {
        throw "源码归档没有有效版本号。"
    }
    return $match.Groups[1].Value
}

function Get-CoreSizeBytes {
    param([Parameter(Mandatory = $true)][string]$Root)

    [long]$total = 0
    foreach ($name in @((Get-CoreDirectoryNames) + (Get-CoreFileNames))) {
        $path = Join-Path $Root $name
        if ([System.IO.File]::Exists($path)) {
            $total += (Get-Item -LiteralPath $path -Force).Length
        }
        elseif ([System.IO.Directory]::Exists($path)) {
            $total += (
                Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum
            ).Sum
        }
    }
    return $total
}

function Test-FreeSpace {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [long]$CoreBytes
    )

    $rootPath = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Root))
    $drive = New-Object System.IO.DriveInfo($rootPath)
    [long]$required = [Math]::Max(
        [long]512MB,
        ([long]$CoreBytes * [long]4) + [long]256MB
    )
    if ($drive.AvailableFreeSpace -lt $required) {
        throw (
            "磁盘空间不足：至少需要 {0:N0} MB 可用空间，当前仅有 {1:N0} MB。" -f
            ($required / 1MB),
            ($drive.AvailableFreeSpace / 1MB)
        )
    }
}

function Test-ComfyUIProcessRunning {
    param([Parameter(Mandatory = $true)][string]$Root)

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root)
    try {
        $processes = Get-CimInstance Win32_Process -Filter (
            "Name='python.exe' OR Name='pythonw.exe'"
        ) -ErrorAction Stop
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            if ($commandLine.IndexOf(
                $normalizedRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0 -and $commandLine -match "(?i)main\.py") {
                return $true
            }
        }
    }
    catch {
        Write-UpdateLog ("进程检查警告：" + $_.Exception.Message)
    }
    return $false
}

function Quote-ProcessArgument {
    param([string]$Value)

    if ($Value -match "[`r`n`"]") {
        throw "外部进程参数包含不允许的字符。"
    }
    return '"' + $Value + '"'
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 600,
        [string]$StatusStage = "",
        [string]$StatusMessage = "",
        [switch]$SuppressOutputLog
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ($Arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($name in $Environment.Keys) {
        $value = $Environment[$name]
        if ($null -eq $value) {
            [void]$startInfo.EnvironmentVariables.Remove([string]$name)
        }
        else {
            $startInfo.EnvironmentVariables[[string]$name] = [string]$value
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastStatusSecond = -10
    while (-not $process.WaitForExit(500)) {
        if ($stopwatch.Elapsed.TotalSeconds -ge [Math]::Max(1, $TimeoutSeconds)) {
            try { $process.Kill() } catch {}
            $stageLabel = if ([string]::IsNullOrWhiteSpace($StatusStage)) {
                "未指定阶段"
            }
            else {
                $StatusStage
            }
            throw (
                "外部进程执行超时（阶段：{0}；已等待 {1} 秒）。" -f
                $stageLabel,
                $TimeoutSeconds
            )
        }
        $elapsedSeconds = [int][Math]::Floor($stopwatch.Elapsed.TotalSeconds)
        if (-not [string]::IsNullOrWhiteSpace($StatusStage) -and
            -not [string]::IsNullOrWhiteSpace($StatusMessage) -and
            ($elapsedSeconds - $lastStatusSecond) -ge 5) {
            Publish-Status `
                -Stage $StatusStage `
                -Message ("{0}（已用时 {1} 秒）" -f $StatusMessage, $elapsedSeconds)
            $lastStatusSecond = $elapsedSeconds
        }
    }
    $stopwatch.Stop()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    if (-not $SuppressOutputLog) {
        Write-UpdateLog ("命令输出：" + $stdout)
        Write-UpdateLog ("命令错误：" + $stderr)
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Get-RequirementLines {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        throw "依赖清单不存在：$Path"
    }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path, $script:utf8)) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }
        $result.Add($line)
    }
    return @($result)
}

function Normalize-PythonPackageName {
    param([Parameter(Mandatory = $true)][string]$Name)

    return (
        $Name.Trim().ToLowerInvariant() -replace "[-_.]+", "-"
    )
}

function Get-RequirementEntryMap {
    param([Parameter(Mandatory = $true)][string]$Path)

    $packages = @{}
    $options = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-RequirementLines -Path $Path)) {
        if ($line.StartsWith("-")) {
            $options.Add($line)
            continue
        }
        if ($line -notmatch (
            "^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)" +
            "(?:\[[^\]]+\])?(?:\s*(?:===|==|~=|!=|<=|>=|<|>|@)|\s*$)"
        )) {
            throw "无法安全识别依赖项：$line"
        }
        $name = Normalize-PythonPackageName -Name $Matches["name"]
        if ($packages.ContainsKey($name)) {
            throw "依赖清单包含重复包：$name"
        }
        $packages[$name] = $line
    }
    return [pscustomobject]@{
        Packages = $packages
        Options = $options.ToArray()
    }
}

function Get-SafeRequirementMigrationPlan {
    param(
        [Parameter(Mandatory = $true)][string]$BaselineRequirementsPath,
        [Parameter(Mandatory = $true)][string]$TargetRequirementsPath
    )

    $baseline = Get-RequirementEntryMap -Path $BaselineRequirementsPath
    $target = Get-RequirementEntryMap -Path $TargetRequirementsPath
    $baselineOptions = @($baseline.Options | Sort-Object)
    $targetOptions = @($target.Options | Sort-Object)
    if (($baselineOptions -join "`n") -cne ($targetOptions -join "`n")) {
        throw (
            "目标版本改变了依赖源或安装选项，无法执行安全自动迁移。" +
            "请等待整合包维护版更新。"
        )
    }
    if ($baseline.Packages.Count -ne $target.Packages.Count) {
        throw (
            "目标版本新增或删除了 Python 依赖，无法保证完整回滚。" +
            "请等待整合包维护版更新。"
        )
    }

    $changes = New-Object System.Collections.Generic.List[object]
    foreach ($name in @($baseline.Packages.Keys | Sort-Object)) {
        if (-not $target.Packages.ContainsKey($name)) {
            throw (
                "目标版本新增或删除了 Python 依赖，无法保证完整回滚。" +
                "请等待整合包维护版更新。"
            )
        }
        $oldLine = [string]$baseline.Packages[$name]
        $newLine = [string]$target.Packages[$name]
        if ($oldLine.Equals(
            $newLine,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            continue
        }

        # Requirement constraints are not installed versions. Resolve ranges
        # with pip; the preflight records exact installed/target pins and
        # caches both wheel sets before any mutation.
        if ($newLine -match '@|;|https?://') {
            throw "依赖 $name 使用了暂不支持自动迁移的来源或条件表达式。"
        }
        if (-not ($name.StartsWith("comfyui-") -or
            $name.StartsWith("comfy-") -or $name -eq "av")) {
            throw (
                "目标版本需要调整底层运行依赖 $name。" +
                "为保护显卡与 Python 环境，请等待整合包维护版更新。"
            )
        }
        $changes.Add([pscustomobject]@{
            Name = $name
            OldVersion = ""
            NewVersion = ""
            OldRequirement = $oldLine
            NewRequirement = $newLine
        })
    }
    return [pscustomobject]@{
        Count = $changes.Count
        Changes = $changes.ToArray()
    }
}

function New-RequirementInstallPlan {
    param(
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [string]$BaselineRequirementsPath = ""
    )

    $targetLines = @(Get-RequirementLines -Path $RequirementsPath)
    $targetPackages = @($targetLines | Where-Object { -not $_.StartsWith("-") })
    if ([string]::IsNullOrWhiteSpace($BaselineRequirementsPath) -or
        -not [System.IO.File]::Exists($BaselineRequirementsPath)) {
        return [pscustomobject]@{
            Path = $RequirementsPath
            Count = $targetPackages.Count
            IsDelta = $false
        }
    }

    $baselineSet = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($line in @(Get-RequirementLines -Path $BaselineRequirementsPath)) {
        if (-not $line.StartsWith("-")) {
            [void]$baselineSet.Add($line)
        }
    }

    $optionLines = @($targetLines | Where-Object { $_.StartsWith("-") })
    $changedLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $targetPackages) {
        if (-not $baselineSet.Contains($line)) {
            $changedLines.Add($line)
        }
    }
    if ($changedLines.Count -eq 0) {
        return [pscustomobject]@{
            Path = ""
            Count = 0
            IsDelta = $true
        }
    }

    $deltaPath = Join-Path (
        [System.IO.Path]::GetDirectoryName($RequirementsPath)
    ) "launcher-requirements.delta.txt"
    $deltaLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $optionLines) {
        $deltaLines.Add($line)
    }
    foreach ($line in $changedLines) {
        $deltaLines.Add($line)
    }
    [System.IO.File]::WriteAllLines(
        $deltaPath,
        $deltaLines.ToArray(),
        $script:utf8
    )
    return [pscustomobject]@{
        Path = $deltaPath
        Count = $changedLines.Count
        IsDelta = $true
    }
}

function Get-PipProcessEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Request,
        [string]$CacheDirectory = ""
    )

    $environment = @{}
    if (-not [string]::IsNullOrWhiteSpace($CacheDirectory)) {
        if (-not [System.IO.Directory]::Exists($CacheDirectory)) {
            [void][System.IO.Directory]::CreateDirectory($CacheDirectory)
        }
        $environment["PIP_CACHE_DIR"] = $CacheDirectory
    }
    # pip can occasionally stall indefinitely while opening its HTTP cache on
    # portable/removable package volumes. Update transactions already prepare
    # explicit, checksum-verified wheel directories, so the HTTP cache is not
    # needed for safety or rollback.
    $environment["PIP_NO_CACHE_DIR"] = "1"
    switch ([string]$Request.proxyMode) {
        "none" {
            foreach ($name in @(
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "all_proxy"
            )) {
                $environment[$name] = $null
            }
        }
        "custom" {
            $address = ([string]$Request.proxyAddress).Trim()
            if ($address -notmatch "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
                $address = "http://" + $address
            }
            $builder = New-Object System.UriBuilder($address)
            $builder.Port = [int]$Request.proxyPort
            $builder.UserName = ""
            $builder.Password = ""
            $proxyUri = $builder.Uri.AbsoluteUri
            $environment["HTTP_PROXY"] = $proxyUri
            $environment["HTTPS_PROXY"] = $proxyUri
            $environment["http_proxy"] = $proxyUri
            $environment["https_proxy"] = $proxyUri
        }
    }
    return $environment
}

function Invoke-CheckedPythonCommand {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 300,
        [string]$StatusStage = "",
        [string]$StatusMessage = "",
        [string]$FailureLabel = "Python 命令执行失败",
        [switch]$SuppressOutputLog
    )

    $result = Invoke-CapturedProcess `
        -FilePath $PythonPath `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -Environment $Environment `
        -TimeoutSeconds $TimeoutSeconds `
        -StatusStage $StatusStage `
        -StatusMessage $StatusMessage `
        -SuppressOutputLog:$SuppressOutputLog
    if ($result.ExitCode -ne 0) {
        $reason = ([string]$result.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = ([string]$result.StdOut).Trim()
        }
        if ($reason.Length -gt 700) {
            $reason = $reason.Substring($reason.Length - 700)
        }
        throw ($FailureLabel + "：" + $reason)
    }
    return $result
}

function Get-InstalledPythonPackageMap {
    param([Parameter(Mandatory = $true)][string]$PythonPath)

    $result = Invoke-CheckedPythonCommand `
        -PythonPath $PythonPath `
        -Arguments @(
            "-s", "-m", "pip", "list",
            "--disable-pip-version-check", "--format", "json"
        ) `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName($PythonPath)) `
        -TimeoutSeconds 120 `
        -FailureLabel "无法读取内置 Python 包版本" `
        -SuppressOutputLog
    $items = @(([string]$result.StdOut | ConvertFrom-Json))
    $installed = @{}
    foreach ($item in $items) {
        $name = Normalize-PythonPackageName -Name ([string]$item.name)
        $installed[$name] = [pscustomobject]@{
            Name = [string]$item.name
            Version = [string]$item.version
        }
    }
    return $installed
}

function Get-ProtectedPythonRuntimePackageNames {
    return @(
        "torch",
        "torchvision",
        "torchaudio",
        "triton",
        "xformers"
    )
}

function New-DependencyRepairTransactionPlan {
    param(
        [Parameter(Mandatory = $true)][object[]]$InstallItems,
        [Parameter(Mandatory = $true)][hashtable]$InstalledPackages
    )

    $protectedPackages = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in Get-ProtectedPythonRuntimePackageNames) {
        [void]$protectedPackages.Add($name)
    }

    $targetPins = New-Object System.Collections.Generic.List[string]
    $rollbackPins = New-Object System.Collections.Generic.List[string]
    $addedPackages = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($item in @($InstallItems)) {
        $displayName = [string]$item.metadata.name
        $targetVersion = [string]$item.metadata.version
        if ($displayName -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
            $targetVersion -notmatch "^[A-Za-z0-9][A-Za-z0-9._+!-]*$") {
            throw "依赖修复计划包含无法安全处理的包版本。"
        }
        $name = Normalize-PythonPackageName -Name $displayName
        if (-not $seen.Add($name)) {
            continue
        }
        if ($protectedPackages.Contains($name)) {
            throw (
                "依赖修复需要改动显卡运行时包 $name。" +
                "为避免破坏内置 CUDA 环境，请获取整合包维护版。"
            )
        }

        $targetPins.Add($displayName + "==" + $targetVersion)
        if ($InstalledPackages.ContainsKey($name)) {
            $installedName = [string]$InstalledPackages[$name].Name
            $installedVersion = [string]$InstalledPackages[$name].Version
            if ($installedName -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
                $installedVersion -notmatch "^[A-Za-z0-9][A-Za-z0-9._+!-]*$") {
                throw "已安装依赖包含无法安全回滚的包版本：$name"
            }
            $rollbackPins.Add($installedName + "==" + $installedVersion)
        }
        else {
            $addedPackages.Add($displayName)
        }
    }

    return [pscustomobject]@{
        Count = $targetPins.Count
        TargetPins = $targetPins.ToArray()
        RollbackPins = $rollbackPins.ToArray()
        AddedPackageNames = $addedPackages.ToArray()
    }
}

function Assert-PreparedDependencyWheelSet {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][ValidateSet("target", "rollback")]
        [string]$SetName
    )

    if (-not [System.IO.Directory]::Exists($Directory) -or
        -not [System.IO.File]::Exists($ManifestPath)) {
        throw "依赖修复离线材料不完整：$SetName"
    }
    $manifestItems = @(
        [System.IO.File]::ReadAllText($ManifestPath, $script:utf8) |
        ConvertFrom-Json
    )
    $expectedItems = @(
        $manifestItems | Where-Object { [string]$_.set -eq $SetName }
    )
    $actualFiles = @(Get-ChildItem -LiteralPath $Directory -File)
    if ($actualFiles.Count -ne $expectedItems.Count) {
        throw "依赖修复离线材料数量校验失败：$SetName"
    }
    foreach ($item in $expectedItems) {
        $fileName = [string]$item.file
        $expectedHash = [string]$item.sha256
        $path = Join-Path $Directory $fileName
        if (-not (Test-DirectChildPath -Path $path -Parent $Directory) -or
            -not [System.IO.File]::Exists($path) -or
            $expectedHash -notmatch "^[a-fA-F0-9]{64}$") {
            throw "依赖修复离线材料清单无效：$SetName"
        }
        $actualHash = (
            Get-FileHash -LiteralPath $path -Algorithm SHA256
        ).Hash
        if (-not $actualHash.Equals(
            $expectedHash,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "依赖修复离线材料校验值不匹配：$fileName"
        }
    }
}

function Invoke-DependencyRepairPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [Parameter(Mandatory = $true)][string]$IndexUrl,
        [Parameter(Mandatory = $true)][object]$Request,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    if (-not (Test-HttpUrl $IndexUrl)) {
        throw "PyPI 镜像地址无效。"
    }
    if (-not [System.IO.Directory]::Exists($StageRoot)) {
        [void][System.IO.Directory]::CreateDirectory($StageRoot)
    }

    $cacheDirectory = Join-Path $StageRoot "pip-cache"
    $environment = Get-PipProcessEnvironment `
        -Request $Request `
        -CacheDirectory $cacheDirectory
    $reportPath = Join-Path $StageRoot "repair-report.json"
    $statusMessage = "正在分析依赖修复并准备回滚材料"
    Publish-Status -Stage "dependencies" -Message ($statusMessage + "…")
    [void](Invoke-CheckedPythonCommand `
        -PythonPath $PythonPath `
        -Arguments @(
            "-s", "-m", "pip", "install",
            "--disable-pip-version-check",
            "--no-input",
            "--prefer-binary",
            "--upgrade-strategy", "only-if-needed",
            "--retries", "2",
            "--timeout", "15",
            "--index-url", $IndexUrl,
            "--dry-run",
            "--report", $reportPath,
            "-r", $RequirementsPath
        ) `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName($RequirementsPath)) `
        -Environment $environment `
        -TimeoutSeconds 300 `
        -StatusStage "dependencies" `
        -StatusMessage $statusMessage `
        -FailureLabel "依赖修复预检失败")

    if (-not [System.IO.File]::Exists($reportPath)) {
        throw "依赖修复预检没有生成安装报告。"
    }
    $report = (
        [System.IO.File]::ReadAllText($reportPath, $script:utf8) |
        ConvertFrom-Json
    )
    $installItems = @($report.install)
    if ($installItems.Count -eq 0) {
        Write-UpdateLog "当前版本依赖已满足，无需修改内置 Python 环境。"
        return [pscustomobject]@{
            Count = 0
            TargetRequirementsPath = ""
            TargetWheelDirectory = ""
            RollbackRequirementsPath = ""
            RollbackWheelDirectory = ""
            AddedPackageNames = @()
            WheelManifestPath = ""
        }
    }

    $installed = Get-InstalledPythonPackageMap -PythonPath $PythonPath
    $plan = New-DependencyRepairTransactionPlan `
        -InstallItems $installItems `
        -InstalledPackages $installed
    $targetPinPath = Join-Path $StageRoot "repair-target-pins.txt"
    $rollbackPinPath = Join-Path $StageRoot "repair-rollback-pins.txt"
    [System.IO.File]::WriteAllLines(
        $targetPinPath,
        [string[]]$plan.TargetPins,
        $script:utf8
    )
    [System.IO.File]::WriteAllLines(
        $rollbackPinPath,
        [string[]]$plan.RollbackPins,
        $script:utf8
    )

    $targetWheelDirectory = Join-Path $StageRoot "repair-target-wheels"
    $rollbackWheelDirectory = Join-Path $StageRoot "repair-rollback-wheels"
    foreach ($path in @($targetWheelDirectory, $rollbackWheelDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($path)
    }
    $downloadBase = @(
        "-s", "-m", "pip", "download",
        "--disable-pip-version-check",
        "--no-input",
        "--prefer-binary",
        "--only-binary", ":all:",
        "--no-deps",
        "--retries", "3",
        "--timeout", "30",
        "--index-url", $IndexUrl
    )
    [void](Invoke-CheckedPythonCommand `
        -PythonPath $PythonPath `
        -Arguments (@($downloadBase) + @(
            "--dest", $targetWheelDirectory
        ) + @($plan.TargetPins)) `
        -WorkingDirectory $StageRoot `
        -Environment $environment `
        -TimeoutSeconds 600 `
        -StatusStage "dependencies" `
        -StatusMessage "正在缓存依赖修复目标版本" `
        -FailureLabel "依赖修复目标 wheel 缓存失败")

    if (@($plan.RollbackPins).Count -gt 0) {
        [void](Invoke-CheckedPythonCommand `
            -PythonPath $PythonPath `
            -Arguments (@($downloadBase) + @(
                "--dest", $rollbackWheelDirectory
            ) + @($plan.RollbackPins)) `
            -WorkingDirectory $StageRoot `
            -Environment $environment `
            -TimeoutSeconds 600 `
            -StatusStage "dependencies" `
            -StatusMessage "正在缓存依赖修复回滚版本" `
            -FailureLabel "依赖修复回滚 wheel 缓存失败")
    }

    $wheelManifest = foreach ($set in @(
        [pscustomobject]@{
            Name = "target"
            Directory = $targetWheelDirectory
        },
        [pscustomobject]@{
            Name = "rollback"
            Directory = $rollbackWheelDirectory
        }
    )) {
        foreach ($file in Get-ChildItem -LiteralPath $set.Directory -File) {
            [pscustomobject]@{
                set = $set.Name
                file = $file.Name
                sha256 = (
                    Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
                ).Hash.ToLowerInvariant()
            }
        }
    }
    $wheelManifestPath = Join-Path $StageRoot "repair-wheel-manifest.json"
    Write-Utf8Atomic `
        -Path $wheelManifestPath `
        -Text ($wheelManifest | ConvertTo-Json -Depth 4)
    Assert-PreparedDependencyWheelSet `
        -Directory $targetWheelDirectory `
        -ManifestPath $wheelManifestPath `
        -SetName "target"
    Assert-PreparedDependencyWheelSet `
        -Directory $rollbackWheelDirectory `
        -ManifestPath $wheelManifestPath `
        -SetName "rollback"
    Write-UpdateLog (
        "依赖修复事务已准备：目标 {0} 包，回滚 {1} 包，新增 {2} 包。" -f
        @($plan.TargetPins).Count,
        @($plan.RollbackPins).Count,
        @($plan.AddedPackageNames).Count
    )
    return [pscustomobject]@{
        Count = [int]$plan.Count
        TargetRequirementsPath = $targetPinPath
        TargetWheelDirectory = $targetWheelDirectory
        RollbackRequirementsPath = $rollbackPinPath
        RollbackWheelDirectory = $rollbackWheelDirectory
        AddedPackageNames = @($plan.AddedPackageNames)
        WheelManifestPath = $wheelManifestPath
    }
}

function Invoke-DependencyRepairRollback {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][object]$Transaction
    )

    $addedPackages = @($Transaction.AddedPackageNames)
    Assert-PreparedDependencyWheelSet `
        -Directory ([string]$Transaction.RollbackWheelDirectory) `
        -ManifestPath ([string]$Transaction.WheelManifestPath) `
        -SetName "rollback"
    if ($addedPackages.Count -gt 0) {
        Publish-Status -Stage "rollback" -Message "正在移除本次修复新增的依赖…"
        [void](Invoke-CheckedPythonCommand `
            -PythonPath $PythonPath `
            -Arguments (@(
                "-s", "-m", "pip", "uninstall",
                "--disable-pip-version-check",
                "--yes"
            ) + $addedPackages) `
            -WorkingDirectory ([System.IO.Path]::GetDirectoryName($PythonPath)) `
            -TimeoutSeconds 300 `
            -StatusStage "rollback" `
            -StatusMessage "正在移除本次修复新增的依赖" `
            -FailureLabel "新增依赖移除失败")
    }

    $rollbackRequirementsPath = [string]$Transaction.RollbackRequirementsPath
    if (-not [string]::IsNullOrWhiteSpace($rollbackRequirementsPath) -and
        [System.IO.File]::Exists($rollbackRequirementsPath) -and
        @(Get-RequirementLines -Path $rollbackRequirementsPath).Count -gt 0) {
        Invoke-PreparedDependencySet `
            -PythonPath $PythonPath `
            -RequirementsPath $rollbackRequirementsPath `
            -WheelDirectory ([string]$Transaction.RollbackWheelDirectory) `
            -StatusMessage "正在恢复修复前依赖版本"
    }

    $installed = Get-InstalledPythonPackageMap -PythonPath $PythonPath
    foreach ($displayName in $addedPackages) {
        $name = Normalize-PythonPackageName -Name ([string]$displayName)
        if ($installed.ContainsKey($name)) {
            throw "依赖回滚校验失败：本次新增包 $name 仍然存在。"
        }
    }
    $script:rollbackPerformed = $true
    Write-UpdateLog "依赖修复失败后的自动回滚已完成并通过版本校验。"
}

function Invoke-DependencyMigrationPreflight {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$TargetRequirementsPath,
        [Parameter(Mandatory = $true)][string]$BaselineRequirementsPath,
        [Parameter(Mandatory = $true)][string]$IndexUrl,
        [Parameter(Mandatory = $true)][object]$Request,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    if (-not (Test-HttpUrl $IndexUrl)) {
        throw "PyPI 镜像地址无效。"
    }
    $installPlan = New-RequirementInstallPlan `
        -RequirementsPath $TargetRequirementsPath `
        -BaselineRequirementsPath $BaselineRequirementsPath
    if ([int]$installPlan.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0
            TargetRequirementsPath = ""
            TargetWheelDirectory = ""
            RollbackRequirementsPath = ""
            RollbackWheelDirectory = ""
        }
    }
    if (-not [System.IO.Directory]::Exists($StageRoot)) {
        [void][System.IO.Directory]::CreateDirectory($StageRoot)
    }

    $cacheDirectory = Join-Path $StageRoot "pip-cache"
    $environment = Get-PipProcessEnvironment `
        -Request $Request `
        -CacheDirectory $cacheDirectory
    $reportPath = Join-Path $StageRoot "target-report.json"
    $statusMessage = "正在解析目标依赖并准备离线迁移"
    Publish-Status -Stage "dependencies" -Message ($statusMessage + "…")
    $dryRunArguments = @(
        "-s", "-m", "pip", "install",
        "--disable-pip-version-check",
        "--no-input",
        "--prefer-binary",
        "--upgrade-strategy", "only-if-needed",
        "--retries", "3",
        "--timeout", "30",
        "--index-url", $IndexUrl,
        "--dry-run",
        "--report", $reportPath,
        "-r", [string]$installPlan.Path
    )
    [void](Invoke-CheckedPythonCommand `
        -PythonPath $PythonPath `
        -Arguments $dryRunArguments `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName(
            $TargetRequirementsPath
        )) `
        -Environment $environment `
        -TimeoutSeconds 900 `
        -StatusStage "dependencies" `
        -StatusMessage $statusMessage `
        -FailureLabel "目标依赖预检失败")

    if (-not [System.IO.File]::Exists($reportPath)) {
        throw "目标依赖预检没有生成安装报告。"
    }
    $report = (
        [System.IO.File]::ReadAllText($reportPath, $script:utf8) |
        ConvertFrom-Json
    )
    $installItems = @($report.install)
    if ($installItems.Count -eq 0) {
        Write-UpdateLog "目标依赖版本已安装，无需修改内置 Python 环境。"
        return [pscustomobject]@{
            Count = 0
            TargetRequirementsPath = ""
            TargetWheelDirectory = ""
            RollbackRequirementsPath = ""
            RollbackWheelDirectory = ""
        }
    }

    $installed = Get-InstalledPythonPackageMap -PythonPath $PythonPath
    $targetPins = New-Object System.Collections.Generic.List[string]
    $rollbackPins = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($item in $installItems) {
        $displayName = [string]$item.metadata.name
        $targetVersion = [string]$item.metadata.version
        if ($displayName -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
            $targetVersion -notmatch "^[A-Za-z0-9][A-Za-z0-9._+!-]*$") {
            throw "目标依赖报告包含无法安全处理的包版本。"
        }
        $name = Normalize-PythonPackageName -Name $displayName
        if (-not ($name.StartsWith("comfyui-") -or
            $name.StartsWith("comfy-") -or $name -eq "av")) {
            throw (
                "目标依赖会连带修改底层运行包 $name。" +
                "为保护显卡与 Python 环境，请等待整合包维护版更新。"
            )
        }
        if (-not $installed.ContainsKey($name)) {
            throw (
                "目标依赖需要新增 Python 包 $name，无法保证完整回滚。" +
                "请等待整合包维护版更新。"
            )
        }
        if (-not $seen.Add($name)) {
            continue
        }
        $targetPins.Add($displayName + "==" + $targetVersion)
        $rollbackPins.Add(
            ([string]$installed[$name].Name) + "==" +
            ([string]$installed[$name].Version)
        )
    }

    $targetPinPath = Join-Path $StageRoot "target-pins.txt"
    $rollbackPinPath = Join-Path $StageRoot "rollback-pins.txt"
    [System.IO.File]::WriteAllLines(
        $targetPinPath,
        $targetPins.ToArray(),
        $script:utf8
    )
    [System.IO.File]::WriteAllLines(
        $rollbackPinPath,
        $rollbackPins.ToArray(),
        $script:utf8
    )
    $targetWheelDirectory = Join-Path $StageRoot "target-wheels"
    $rollbackWheelDirectory = Join-Path $StageRoot "rollback-wheels"
    foreach ($path in @($targetWheelDirectory, $rollbackWheelDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($path)
    }

    $downloadBase = @(
        "-s", "-m", "pip", "download",
        "--disable-pip-version-check",
        "--no-input",
        "--prefer-binary",
        "--only-binary", ":all:",
        "--no-deps",
        "--retries", "3",
        "--timeout", "30",
        "--index-url", $IndexUrl
    )
    $targetDownloadArguments = @($downloadBase) + @(
        "--dest", $targetWheelDirectory
    ) + @($targetPins)
    [void](Invoke-CheckedPythonCommand `
        -PythonPath $PythonPath `
        -Arguments $targetDownloadArguments `
        -WorkingDirectory $StageRoot `
        -Environment $environment `
        -TimeoutSeconds 900 `
        -StatusStage "dependencies" `
        -StatusMessage "正在缓存目标版本依赖" `
        -FailureLabel "目标依赖缓存失败")

    $rollbackDownloadArguments = @($downloadBase) + @(
        "--dest", $rollbackWheelDirectory
    ) + @($rollbackPins)
    [void](Invoke-CheckedPythonCommand `
        -PythonPath $PythonPath `
        -Arguments $rollbackDownloadArguments `
        -WorkingDirectory $StageRoot `
        -Environment $environment `
        -TimeoutSeconds 900 `
        -StatusStage "dependencies" `
        -StatusMessage "正在缓存回滚依赖" `
        -FailureLabel "回滚依赖缓存失败")

    $wheelManifest = foreach ($set in @(
        [pscustomobject]@{
            Name = "target"
            Directory = $targetWheelDirectory
        },
        [pscustomobject]@{
            Name = "rollback"
            Directory = $rollbackWheelDirectory
        }
    )) {
        foreach ($file in Get-ChildItem -LiteralPath $set.Directory -File) {
            [pscustomobject]@{
                set = $set.Name
                file = $file.Name
                sha256 = (
                    Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
                ).Hash.ToLowerInvariant()
            }
        }
    }
    Write-Utf8Atomic `
        -Path (Join-Path $StageRoot "wheel-manifest.json") `
        -Text ($wheelManifest | ConvertTo-Json -Depth 4)
    Write-UpdateLog (
        "依赖事务已准备：{0} 个发行包，目标与回滚 wheel 均已缓存。" -f
        $targetPins.Count
    )
    return [pscustomobject]@{
        Count = $targetPins.Count
        TargetRequirementsPath = $targetPinPath
        TargetWheelDirectory = $targetWheelDirectory
        RollbackRequirementsPath = $rollbackPinPath
        RollbackWheelDirectory = $rollbackWheelDirectory
    }
}

function Invoke-PreparedDependencySet {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [Parameter(Mandatory = $true)][string]$WheelDirectory,
        [Parameter(Mandatory = $true)][string]$StatusMessage
    )

    if (-not [System.IO.File]::Exists($RequirementsPath) -or
        -not [System.IO.Directory]::Exists($WheelDirectory)) {
        throw "离线依赖事务材料不完整。"
    }
    Publish-Status -Stage "dependencies" -Message ($StatusMessage + "…")
    [void](Invoke-CheckedPythonCommand `
        -PythonPath $PythonPath `
        -Arguments @(
            "-s", "-m", "pip", "install",
            "--disable-pip-version-check",
            "--no-input",
            "--no-index",
            "--find-links", $WheelDirectory,
            "--no-deps",
            "-r", $RequirementsPath
        ) `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName(
            $RequirementsPath
        )) `
        -TimeoutSeconds 300 `
        -StatusStage "dependencies" `
        -StatusMessage $StatusMessage `
        -FailureLabel "离线依赖安装失败")

    $installed = Get-InstalledPythonPackageMap -PythonPath $PythonPath
    foreach ($line in @(Get-RequirementLines -Path $RequirementsPath)) {
        if ($line -notmatch (
            "^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)==" +
            "(?<version>[A-Za-z0-9][A-Za-z0-9._+!-]*)$"
        )) {
            throw "离线依赖校验遇到无效版本项：$line"
        }
        $name = Normalize-PythonPackageName -Name $Matches["name"]
        $version = $Matches["version"]
        if (-not $installed.ContainsKey($name) -or
            -not ([string]$installed[$name].Version).Equals(
                $version,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            throw "依赖版本校验失败：$name 应为 $version。"
        }
    }
    Write-UpdateLog ($StatusMessage + "完成，版本校验通过。")
}

function Invoke-PortableEntrypointRepair {
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $repairPath = Join-Path $Root "tools\Repair-Portable-Entrypoints.ps1"
    if (-not [System.IO.File]::Exists($repairPath)) {
        Write-UpdateLog "未找到便携命令修复工具，已跳过入口修复。"
        return
    }
    Write-UpdateLog "正在刷新内置 Python 的便携命令入口。"
    $repairOutput = & $repairPath -Root $Root
    if (-not [string]::IsNullOrWhiteSpace([string]$repairOutput)) {
        Write-UpdateLog ("便携命令入口修复完成：" + [string]$repairOutput)
    }
}

function Invoke-DependencyInstall {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [Parameter(Mandatory = $true)][string]$IndexUrl,
        [Parameter(Mandatory = $true)][object]$Request,
        [string]$BaselineRequirementsPath = "",
        [string]$CacheDirectory = ""
    )

    if (-not [System.IO.File]::Exists($PythonPath)) {
        throw "内置 Python 不存在。"
    }
    if (-not (Test-HttpUrl $IndexUrl)) {
        throw "PyPI 镜像地址无效。"
    }
    $installPlan = New-RequirementInstallPlan `
        -RequirementsPath $RequirementsPath `
        -BaselineRequirementsPath $BaselineRequirementsPath
    if ([int]$installPlan.Count -eq 0) {
        Write-UpdateLog "依赖差异检查完成：没有需要安装的变更。"
        Publish-Status `
            -Stage "dependencies" `
            -Message "依赖已满足，已跳过重复安装。" `
            -Percent 100
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($CacheDirectory) -and
        -not [System.IO.Directory]::Exists($CacheDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($CacheDirectory)
    }
    $sourceHost = ([System.Uri]$IndexUrl).Host
    $dependencyLabel = if ([bool]$installPlan.IsDelta) {
        "{0} 项变更依赖" -f [int]$installPlan.Count
    }
    else {
        "{0} 项核心依赖" -f [int]$installPlan.Count
    }
    $statusMessage = "正在通过 {0} 安装{1}" -f $sourceHost, $dependencyLabel
    Publish-Status -Stage "dependencies" -Message ($statusMessage + "…")
    Write-UpdateLog (
        "依赖安装计划：{0}；源：{1}；清单：{2}" -f
        $dependencyLabel,
        $IndexUrl,
        [string]$installPlan.Path
    )
    $processArguments = @(
        "-s",
        "-m",
        "pip",
        "install",
        "--disable-pip-version-check",
        "--no-input",
        "--prefer-binary",
        "--upgrade-strategy",
        "only-if-needed",
        "--retries",
        "2",
        "--timeout",
        "15",
        "--index-url",
        $IndexUrl,
        "-r",
        [string]$installPlan.Path
    )
    $environment = @{}
    if (-not [string]::IsNullOrWhiteSpace($CacheDirectory)) {
        $environment["PIP_CACHE_DIR"] = $CacheDirectory
    }
    switch ([string]$Request.proxyMode) {
        "none" {
            foreach ($name in @(
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "all_proxy"
            )) {
                $environment[$name] = $null
            }
        }
        "custom" {
            $address = ([string]$Request.proxyAddress).Trim()
            if ($address -notmatch "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
                $address = "http://" + $address
            }
            $builder = New-Object System.UriBuilder($address)
            $builder.Port = [int]$Request.proxyPort
            $builder.UserName = ""
            $builder.Password = ""
            $proxyUri = $builder.Uri.AbsoluteUri
            $environment["HTTP_PROXY"] = $proxyUri
            $environment["HTTPS_PROXY"] = $proxyUri
            $environment["http_proxy"] = $proxyUri
            $environment["https_proxy"] = $proxyUri
        }
    }
    $result = Invoke-CapturedProcess `
        -FilePath $PythonPath `
        -Arguments $processArguments `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName($RequirementsPath)) `
        -Environment $environment `
        -TimeoutSeconds 300 `
        -StatusStage "dependencies" `
        -StatusMessage $statusMessage
    if ($result.ExitCode -ne 0) {
        $reason = ([string]$result.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = ([string]$result.StdOut).Trim()
        }
        if ($reason.Length -gt 700) {
            $reason = $reason.Substring($reason.Length - 700)
        }
        throw "依赖安装失败：$reason"
    }
}

function Invoke-DependencyRepair {
    param([Parameter(Mandatory = $true)][object]$Request)

    $root = [System.IO.Path]::GetFullPath(
        (Get-RequiredProperty $Request "root")
    ).TrimEnd("\")
    if (-not [System.IO.Directory]::Exists($root)) {
        throw "ComfyUI 根目录不存在。"
    }

    $pythonPath = [System.IO.Path]::GetFullPath(
        (Get-RequiredProperty $Request "pythonPath")
    )
    $expectedPythonPath = [System.IO.Path]::GetFullPath(
        (Join-Path $root ".ext\python.exe")
    )
    if (-not $pythonPath.Equals(
        $expectedPythonPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "依赖恢复只能使用整合包内置 Python。"
    }

    $requirementsPath = Join-Path $root "requirements.txt"
    if (-not [System.IO.File]::Exists($requirementsPath)) {
        throw "当前 ComfyUI 版本缺少 requirements.txt。"
    }
    $indexUrl = Get-RequiredProperty $Request "pypiIndexUrl"
    if (-not (Test-HttpUrl $indexUrl)) {
        throw "PyPI 镜像地址无效。"
    }

    Publish-Status -Stage "preflight" -Message "正在检查当前版本与运行环境…"
    if (Test-ComfyUIProcessRunning -Root $root) {
        throw "检测到 ComfyUI 仍在运行，请停止后重试。"
    }
    Test-FreeSpace -Root $root -CoreBytes 0

    $transactionParent = Join-Path $root ".cache\launcher\dependency-repair"
    $transactionRoot = Join-Path $transactionParent (
        [Guid]::NewGuid().ToString("N")
    )
    $healthParent = Join-Path $root ".cache\launcher\dependency-health"
    $healthRoot = Join-Path $healthParent ([Guid]::NewGuid().ToString("N"))
    foreach ($path in @($transactionParent, $healthParent)) {
        if (-not [System.IO.Directory]::Exists($path)) {
            [void][System.IO.Directory]::CreateDirectory($path)
        }
    }
    $transaction = $null
    $mutationStarted = $false
    $retainTransaction = $false
    try {
        $transaction = Invoke-DependencyRepairPreflight `
            -PythonPath $pythonPath `
            -RequirementsPath $requirementsPath `
            -IndexUrl $indexUrl `
            -Request $Request `
            -StageRoot $transactionRoot
        if ([int]$transaction.Count -gt 0) {
            Assert-PreparedDependencyWheelSet `
                -Directory ([string]$transaction.TargetWheelDirectory) `
                -ManifestPath ([string]$transaction.WheelManifestPath) `
                -SetName "target"
            Assert-PreparedDependencyWheelSet `
                -Directory ([string]$transaction.RollbackWheelDirectory) `
                -ManifestPath ([string]$transaction.WheelManifestPath) `
                -SetName "rollback"
            $mutationStarted = $true
            Invoke-PreparedDependencySet `
                -PythonPath $pythonPath `
                -RequirementsPath ([string]$transaction.TargetRequirementsPath) `
                -WheelDirectory ([string]$transaction.TargetWheelDirectory) `
                -StatusMessage "正在应用依赖修复事务"
        }
        else {
            Publish-Status `
                -Stage "dependencies" `
                -Message "当前版本依赖已满足，未改动内置 Python。" `
                -Percent 100
        }
        Invoke-PortableEntrypointRepair -Root $root

        Publish-Status -Stage "verify" -Message "正在执行隔离核心启动检查…"
        Invoke-CoreHealthCheck `
            -PythonPath $pythonPath `
            -Root $root `
            -HealthRoot $healthRoot `
            -ExpectedVersion $script:targetVersion

        Publish-Status `
            -Stage "complete" `
            -Message "当前 ComfyUI 版本依赖已恢复，核心启动检查通过。" `
            -Percent 100 `
            -Completed $true `
            -Success $true
    }
    catch {
        $repairFailure = ConvertTo-UpdateError $_
        if ($mutationStarted -and $null -ne $transaction) {
            $rollbackFailure = ""
            try {
                Publish-Status `
                    -Stage "rollback" `
                    -Message "依赖修复失败，正在恢复修复前环境…"
                Invoke-DependencyRepairRollback `
                    -PythonPath $pythonPath `
                    -Transaction $transaction
                Invoke-PortableEntrypointRepair -Root $root
            }
            catch {
                $rollbackFailure = ConvertTo-UpdateError $_
            }
            if (-not [string]::IsNullOrWhiteSpace($rollbackFailure)) {
                $retainTransaction = $true
                Write-UpdateLog (
                    "依赖修复自动回滚未完全成功，事务材料保留于 {0}：{1}" -f
                    $transactionRoot,
                    $rollbackFailure
                )
                throw (
                    $repairFailure +
                    "；自动回滚未完全成功：" +
                    $rollbackFailure +
                    "。恢复材料已保留，请勿继续启动或修复，联系整合包维护者。"
                )
            }
            throw (
                $repairFailure +
                "；本次依赖变更已自动恢复到修复前版本。"
            )
        }
        throw $repairFailure
    }
    finally {
        if ([System.IO.Directory]::Exists($healthRoot)) {
            try {
                Remove-TreeWithoutFollowingReparse `
                    -Path $healthRoot `
                    -ApprovedRoot $healthParent
            }
            catch {
                Write-UpdateLog (
                    "依赖修复健康检查目录清理警告：" +
                    (ConvertTo-SafeMessage $_.Exception.Message)
                )
            }
        }
        if (-not $retainTransaction -and
            [System.IO.Directory]::Exists($transactionRoot)) {
            try {
                Remove-TreeWithoutFollowingReparse `
                    -Path $transactionRoot `
                    -ApprovedRoot $transactionParent
            }
            catch {
                Write-UpdateLog (
                    "依赖修复事务目录清理警告：" +
                    (ConvertTo-SafeMessage $_.Exception.Message)
                )
            }
        }
    }
}

function Move-Path {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if ([System.IO.Directory]::Exists($Source)) {
        [System.IO.Directory]::Move($Source, $Destination)
    }
    elseif ([System.IO.File]::Exists($Source)) {
        [System.IO.File]::Move($Source, $Destination)
    }
    else {
        throw "待移动路径不存在：$Source"
    }
}

function Restore-CoreTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    $statePath = Join-Path $BackupRoot "transaction-state.json"
    $originalState = @{}
    if ([System.IO.File]::Exists($statePath)) {
        $stateItems = (
            [System.IO.File]::ReadAllText($statePath, $script:utf8) |
            ConvertFrom-Json
        )
        foreach ($stateItem in @($stateItems)) {
            $originalState[[string]$stateItem.name] = [bool]$stateItem.present
        }
    }

    foreach ($name in @((Get-CoreDirectoryNames) + (Get-CoreFileNames))) {
        $targetPath = Join-Path $Root $name
        $backupItem = Join-Path $BackupRoot $name
        $backupExists = (
            [System.IO.Directory]::Exists($backupItem) -or
            [System.IO.File]::Exists($backupItem)
        )
        $originallyPresent = if ($originalState.ContainsKey($name)) {
            [bool]$originalState[$name]
        }
        else {
            $backupExists
        }

        if ($backupExists) {
            if ([System.IO.Directory]::Exists($targetPath) -or
                [System.IO.File]::Exists($targetPath)) {
                Remove-SafePath -Path $targetPath -ApprovedRoot $Root
            }
            Move-Path -Source $backupItem -Destination $targetPath
        }
        elseif (-not $originallyPresent -and (
            [System.IO.Directory]::Exists($targetPath) -or
            [System.IO.File]::Exists($targetPath)
        )) {
            Remove-SafePath -Path $targetPath -ApprovedRoot $Root
        }
    }
    $script:rollbackPerformed = $true
}

function Apply-CoreTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    if (-not [System.IO.Directory]::Exists($BackupRoot)) {
        [void][System.IO.Directory]::CreateDirectory($BackupRoot)
    }
    $entries = @((Get-CoreDirectoryNames) + (Get-CoreFileNames))
    foreach ($name in $entries) {
        $sourceItem = Join-Path $SourceRoot $name
        if (-not [System.IO.Directory]::Exists($sourceItem) -and
            -not [System.IO.File]::Exists($sourceItem)) {
            throw "官方源码缺少必要核心项：$name"
        }
    }

    $transactionState = foreach ($name in $entries) {
        $targetItem = Join-Path $Root $name
        [pscustomobject]@{
            name = $name
            present = (
                [System.IO.Directory]::Exists($targetItem) -or
                [System.IO.File]::Exists($targetItem)
            )
        }
    }
    Write-Utf8Atomic `
        -Path (Join-Path $BackupRoot "transaction-state.json") `
        -Text ($transactionState | ConvertTo-Json -Depth 3)

    try {
        foreach ($name in $entries) {
            $targetItem = Join-Path $Root $name
            $backupItem = Join-Path $BackupRoot $name
            if (-not (Test-DirectChildPath -Path $targetItem -Parent $Root)) {
                throw "核心目标不是根目录的直接子项：$name"
            }
            if (-not (Test-DirectChildPath -Path $backupItem -Parent $BackupRoot)) {
                throw "备份目标不是备份目录的直接子项：$name"
            }
            if ([System.IO.Directory]::Exists($targetItem) -or
                [System.IO.File]::Exists($targetItem)) {
                Move-Path -Source $targetItem -Destination $backupItem
            }
        }
        foreach ($name in $entries) {
            $sourceItem = Join-Path $SourceRoot $name
            $targetItem = Join-Path $Root $name
            Move-Path -Source $sourceItem -Destination $targetItem
        }
        foreach ($name in Get-CoreFileNames) {
            $backupItem = Join-Path $BackupRoot $name
            $targetItem = Join-Path $Root $name
            if ([System.IO.File]::Exists($backupItem) -and
                [System.IO.File]::Exists($targetItem)) {
                $oldAttributes = [System.IO.File]::GetAttributes($backupItem)
                if (($oldAttributes -band [System.IO.FileAttributes]::Hidden) -ne 0) {
                    $newAttributes = [System.IO.File]::GetAttributes($targetItem)
                    [System.IO.File]::SetAttributes(
                        $targetItem,
                        ($newAttributes -bor [System.IO.FileAttributes]::Hidden)
                    )
                }
            }
        }
    }
    catch {
        try {
            Restore-CoreTransaction -Root $Root -BackupRoot $BackupRoot
        }
        catch {
            Write-UpdateLog ("应用阶段回滚失败：" + $_.Exception.Message)
        }
        throw
    }
}

function Invoke-CoreHealthCheck {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$HealthRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    if (-not [System.IO.Directory]::Exists($HealthRoot)) {
        [void][System.IO.Directory]::CreateDirectory($HealthRoot)
    }
    foreach ($name in @("input", "output", "temp", "user", "models")) {
        [void][System.IO.Directory]::CreateDirectory((Join-Path $HealthRoot $name))
    }
    $arguments = @(
        "-s",
        (Join-Path $Root "main.py"),
        "--quick-test-for-ci",
        "--cpu",
        "--disable-all-custom-nodes",
        "--disable-api-nodes",
        "--disable-auto-launch",
        "--base-directory",
        $HealthRoot
    )
    $result = Invoke-CapturedProcess `
        -FilePath $PythonPath `
        -Arguments $arguments `
        -WorkingDirectory $Root `
        -TimeoutSeconds 240 `
        -StatusStage "health" `
        -StatusMessage "正在执行隔离启动健康检查"
    if ($result.ExitCode -ne 0) {
        $reason = ([string]$result.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = ([string]$result.StdOut).Trim()
        }
        if ($reason.Length -gt 800) {
            $reason = $reason.Substring($reason.Length - 800)
        }
        throw "启动健康检查失败：$reason"
    }
    $combinedOutput = ([string]$result.StdOut) + [Environment]::NewLine + (
        [string]$result.StdErr
    )
    if ($combinedOutput -match "(?i)failed to initialize database|traceback \(most recent call last\)|modulenotfounderror|importerror") {
        throw "启动健康检查检测到核心初始化错误。"
    }
    if ($combinedOutput -match "(?i)lower than the recommended version") {
        throw "启动健康检查检测到依赖版本仍低于新核心要求。"
    }
    if ($combinedOutput -notmatch (
        "(?i)ComfyUI version:\s*" + [regex]::Escape($ExpectedVersion)
    )) {
        throw "启动健康检查没有确认目标版本。"
    }
}

function Invoke-UpdaterSelfTest {
    $coreNames = @((Get-CoreDirectoryNames) + (Get-CoreFileNames))
    foreach ($protected in Get-ProtectedNames) {
        if ($protected -in $coreNames) {
            throw "受保护路径误入核心清单：$protected"
        }
    }

    $tempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\")
    $testRoot = Join-Path $tempParent (
        "ComfyUI-Core-Updater-Test-" + [Guid]::NewGuid().ToString("N")
    )
    try {
        $root = Join-Path $testRoot "root"
        $source = Join-Path $testRoot "source"
        $backup = Join-Path $testRoot "backup"
        foreach ($path in @($root, $source, $backup)) {
            [void][System.IO.Directory]::CreateDirectory($path)
        }

        $pipEnvironment = Get-PipProcessEnvironment `
            -Request ([pscustomobject]@{ proxyMode = "system" }) `
            -CacheDirectory (Join-Path $testRoot "pip-cache")
        if ([string]$pipEnvironment["PIP_NO_CACHE_DIR"] -ne "1") {
            throw "依赖预检没有禁用不可靠的 pip HTTP 缓存。"
        }

        $baselineRequirements = Join-Path $testRoot "requirements-old.txt"
        $targetRequirements = Join-Path $testRoot "requirements-new.txt"
        [System.IO.File]::WriteAllLines(
            $baselineRequirements,
            @("package-a==1.0", "package-b==1.0"),
            $script:utf8
        )
        [System.IO.File]::WriteAllLines(
            $targetRequirements,
            @("package-a==1.0", "package-b==2.0", "package-c==1.0"),
            $script:utf8
        )
        $dependencyPlan = New-RequirementInstallPlan `
            -RequirementsPath $targetRequirements `
            -BaselineRequirementsPath $baselineRequirements
        $dependencyDelta = @(
            [System.IO.File]::ReadAllLines(
                [string]$dependencyPlan.Path,
                $script:utf8
            )
        )
        if (-not [bool]$dependencyPlan.IsDelta -or
            [int]$dependencyPlan.Count -ne 2 -or
            "package-b==2.0" -notin $dependencyDelta -or
            "package-c==1.0" -notin $dependencyDelta -or
            "package-a==1.0" -in $dependencyDelta) {
            throw "依赖增量计划测试失败。"
        }

        $repairInstalled = @{
            "package-a" = [pscustomobject]@{
                Name = "package-a"
                Version = "1.0"
            }
        }
        $repairItems = @(
            [pscustomobject]@{
                metadata = [pscustomobject]@{
                    name = "package-a"
                    version = "2.0"
                }
            },
            [pscustomobject]@{
                metadata = [pscustomobject]@{
                    name = "package-b"
                    version = "1.0"
                }
            }
        )
        $repairPlan = New-DependencyRepairTransactionPlan `
            -InstallItems $repairItems `
            -InstalledPackages $repairInstalled
        if ([int]$repairPlan.Count -ne 2 -or
            "package-a==2.0" -notin @($repairPlan.TargetPins) -or
            "package-b==1.0" -notin @($repairPlan.TargetPins) -or
            "package-a==1.0" -notin @($repairPlan.RollbackPins) -or
            "package-b" -notin @($repairPlan.AddedPackageNames)) {
            throw "依赖修复回滚计划测试失败。"
        }
        $runtimeRepairBlocked = $false
        try {
            [void](New-DependencyRepairTransactionPlan `
                -InstallItems @(
                    [pscustomobject]@{
                        metadata = [pscustomobject]@{
                            name = "torch"
                            version = "99.0.0"
                        }
                    }
                ) `
                -InstalledPackages @{})
        }
        catch {
            if ($_.Exception.Message -like "*显卡运行时包 torch*") {
                $runtimeRepairBlocked = $true
            }
        }
        if (-not $runtimeRepairBlocked) {
            throw "依赖修复显卡运行时保护测试失败。"
        }

        $repairWheelRoot = Join-Path $testRoot "repair-wheel-test"
        $repairTargetWheels = Join-Path $repairWheelRoot "target"
        $repairRollbackWheels = Join-Path $repairWheelRoot "rollback"
        foreach ($path in @($repairTargetWheels, $repairRollbackWheels)) {
            [void][System.IO.Directory]::CreateDirectory($path)
        }
        $repairWheelPath = Join-Path $repairTargetWheels "package-a.whl"
        [System.IO.File]::WriteAllText(
            $repairWheelPath,
            "wheel-test",
            $script:utf8
        )
        $repairWheelManifestPath = Join-Path $repairWheelRoot "manifest.json"
        Write-Utf8Atomic `
            -Path $repairWheelManifestPath `
            -Text (@(
                [pscustomobject]@{
                    set = "target"
                    file = "package-a.whl"
                    sha256 = (
                        Get-FileHash `
                            -LiteralPath $repairWheelPath `
                            -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                }
            ) | ConvertTo-Json -Depth 4)
        Assert-PreparedDependencyWheelSet `
            -Directory $repairTargetWheels `
            -ManifestPath $repairWheelManifestPath `
            -SetName "target"
        Assert-PreparedDependencyWheelSet `
            -Directory $repairRollbackWheels `
            -ManifestPath $repairWheelManifestPath `
            -SetName "rollback"
        [System.IO.File]::AppendAllText(
            $repairWheelPath,
            "tampered",
            $script:utf8
        )
        $tamperedWheelBlocked = $false
        try {
            Assert-PreparedDependencyWheelSet `
                -Directory $repairTargetWheels `
                -ManifestPath $repairWheelManifestPath `
                -SetName "target"
        }
        catch {
            if ($_.Exception.Message -like "*校验值不匹配*") {
                $tamperedWheelBlocked = $true
            }
        }
        if (-not $tamperedWheelBlocked) {
            throw "依赖修复离线材料校验测试失败。"
        }

        $safeOldRequirements = Join-Path $testRoot "requirements-safe-old.txt"
        $safeNewRequirements = Join-Path $testRoot "requirements-safe-new.txt"
        [System.IO.File]::WriteAllLines(
            $safeOldRequirements,
            @(
                "comfyui-frontend-package==1.0.0",
                "comfy-kitchen==2.0.0",
                "torch"
            ),
            $script:utf8
        )
        [System.IO.File]::WriteAllLines(
            $safeNewRequirements,
            @(
                "torch",
                "comfy-kitchen==2.1.0",
                "comfyui-frontend-package==1.1.0"
            ),
            $script:utf8
        )
        $safeMigration = Get-SafeRequirementMigrationPlan `
            -BaselineRequirementsPath $safeOldRequirements `
            -TargetRequirementsPath $safeNewRequirements
        if ([int]$safeMigration.Count -ne 2) {
            throw "可逆依赖迁移识别测试失败。"
        }

        # Regression: an installed av 17.1 satisfies both ranges. A changed
        # lower bound must reach pip's dry-run instead of failing on syntax.
        $avOld = Join-Path $testRoot "av-old.txt"
        $avNew = Join-Path $testRoot "av-new.txt"
        [System.IO.File]::WriteAllText($avOld, "av>=16.0.0", $script:utf8)
        [System.IO.File]::WriteAllText($avNew, "av>=17.0.0", $script:utf8)
        $avPlan = Get-SafeRequirementMigrationPlan $avOld $avNew
        if ($avPlan.Count -ne 1 -or $avPlan.Changes[0].Name -ne "av") {
            throw "av 范围依赖回归测试失败。"
        }

        [System.IO.File]::WriteAllLines(
            $safeNewRequirements,
            @(
                "comfyui-frontend-package==1.0.0",
                "comfy-kitchen==2.0.0",
                "torch==2.13.0"
            ),
            $script:utf8
        )
        $runtimeChangeBlocked = $false
        try {
            [void](Get-SafeRequirementMigrationPlan `
                -BaselineRequirementsPath $safeOldRequirements `
                -TargetRequirementsPath $safeNewRequirements)
        }
        catch {
            $runtimeChangeBlocked = $true
        }
        if (-not $runtimeChangeBlocked) {
            throw "底层运行依赖拦截测试失败。"
        }

        [System.IO.File]::WriteAllLines(
            $safeNewRequirements,
            @(
                "comfyui-frontend-package==1.0.0",
                "comfy-kitchen==2.0.0",
                "torch",
                "comfyui-new-package==1.0.0"
            ),
            $script:utf8
        )
        $packageSetChangeBlocked = $false
        try {
            [void](Get-SafeRequirementMigrationPlan `
                -BaselineRequirementsPath $safeOldRequirements `
                -TargetRequirementsPath $safeNewRequirements)
        }
        catch {
            $packageSetChangeBlocked = $true
        }
        if (-not $packageSetChangeBlocked) {
            throw "依赖新增删除拦截测试失败。"
        }

        foreach ($directoryName in Get-CoreDirectoryNames) {
            $oldDirectory = Join-Path $root $directoryName
            $newDirectory = Join-Path $source $directoryName
            [void][System.IO.Directory]::CreateDirectory($oldDirectory)
            [void][System.IO.Directory]::CreateDirectory($newDirectory)
            [System.IO.File]::WriteAllText(
                (Join-Path $oldDirectory "marker.txt"),
                "old",
                $script:utf8
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $newDirectory "marker.txt"),
                "new",
                $script:utf8
            )
        }
        foreach ($fileName in Get-CoreFileNames) {
            [System.IO.File]::WriteAllText(
                (Join-Path $root $fileName),
                "old",
                $script:utf8
            )
            [System.IO.File]::WriteAllText(
                (Join-Path $source $fileName),
                "new",
                $script:utf8
            )
        }
        $protectedPath = Join-Path $root "models"
        [void][System.IO.Directory]::CreateDirectory($protectedPath)
        $sentinel = Join-Path $protectedPath "keep.safetensors"
        [System.IO.File]::WriteAllText($sentinel, "keep", $script:utf8)

        Apply-CoreTransaction -Root $root -SourceRoot $source -BackupRoot $backup
        if ([System.IO.File]::ReadAllText((Join-Path $root "main.py"), $script:utf8) -ne "new") {
            throw "核心换入测试失败。"
        }
        Restore-CoreTransaction -Root $root -BackupRoot $backup
        if ([System.IO.File]::ReadAllText((Join-Path $root "main.py"), $script:utf8) -ne "old") {
            throw "核心回滚测试失败。"
        }
        if (-not [System.IO.File]::Exists($sentinel)) {
            throw "受保护目录在事务测试中被修改。"
        }

        $partialBackup = Join-Path $testRoot "partial-backup"
        [void][System.IO.Directory]::CreateDirectory($partialBackup)
        $partialState = foreach ($name in $coreNames) {
            [pscustomobject]@{ name = $name; present = $true }
        }
        Write-Utf8Atomic `
            -Path (Join-Path $partialBackup "transaction-state.json") `
            -Text ($partialState | ConvertTo-Json -Depth 3)
        $firstDirectoryName = (Get-CoreDirectoryNames)[0]
        Move-Path `
            -Source (Join-Path $root $firstDirectoryName) `
            -Destination (Join-Path $partialBackup $firstDirectoryName)
        Restore-CoreTransaction -Root $root -BackupRoot $partialBackup
        if (-not [System.IO.File]::Exists((Join-Path $root "main.py")) -or
            [System.IO.File]::ReadAllText(
                (Join-Path $root "main.py"),
                $script:utf8
            ) -ne "old") {
            throw "部分事务回滚误修改了尚未处理的核心文件。"
        }

        $diskGuardVerified = $false
        try {
            Test-FreeSpace `
                -Root $root `
                -CoreBytes ([long]::MaxValue / 8)
        }
        catch {
            if ($_.Exception.Message -like "磁盘空间不足*") {
                $diskGuardVerified = $true
            }
        }
        if (-not $diskGuardVerified) {
            throw "磁盘空间不足保护测试失败。"
        }

        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $unsafeZipPath = Join-Path $testRoot "unsafe.zip"
        $unsafeZipStream = New-Object System.IO.FileStream(
            $unsafeZipPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::ReadWrite
        )
        $unsafeArchive = New-Object System.IO.Compression.ZipArchive(
            $unsafeZipStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            [void]$unsafeArchive.CreateEntry("../escape.txt")
            foreach ($index in 1..10) {
                [void]$unsafeArchive.CreateEntry(("safe/file-{0}.txt" -f $index))
            }
        }
        finally {
            $unsafeArchive.Dispose()
            $unsafeZipStream.Dispose()
        }
        $archiveGuardVerified = $false
        try {
            Expand-ValidatedZip `
                -ArchivePath $unsafeZipPath `
                -DestinationPath (Join-Path $testRoot "unsafe-extract")
        }
        catch {
            if ($_.Exception.Message -like "*不安全路径*") {
                $archiveGuardVerified = $true
            }
        }
        if (-not $archiveGuardVerified) {
            throw "归档路径穿越保护测试失败。"
        }
        if (-not (Test-TransientArchiveDownloadError (
            New-Object System.IO.IOException("unexpected EOF")
        ))) {
            throw "下载瞬时错误识别测试失败。"
        }
        if (Test-TransientArchiveDownloadError (
            New-Object System.UnauthorizedAccessException("access denied")
        )) {
            throw "下载永久错误识别测试失败。"
        }

        [pscustomobject]@{
            Result = "OK"
            CoreEntries = $coreNames.Count
            ProtectedEntries = @(Get-ProtectedNames).Count
            ApplyRollback = "Verified"
            PartialRollback = "Verified"
            ProtectedData = "Verified"
            DiskGuard = "Verified"
            ArchiveTraversalGuard = "Verified"
            DownloadRetryPolicy = "Verified"
            DependencyDelta = "Verified"
            DependencyRepairMechanics = "Verified"
            DependencyRepairRollbackPlan = "Verified"
            DependencyRepairRuntimeGuard = "Verified"
            DependencyRepairWheelIntegrity = "Verified"
            OnlineMutationPolicy = "Enabled"
        } | ConvertTo-Json -Compress
    }
    finally {
        if ([System.IO.Directory]::Exists($testRoot)) {
            Remove-TreeWithoutFollowingReparse -Path $testRoot -ApprovedRoot $tempParent
        }
    }
}

if ($SelfTest) {
    Invoke-UpdaterSelfTest
    exit 0
}

if ([string]::IsNullOrWhiteSpace($RequestPath)) {
    throw "必须提供更新请求文件。"
}

$request = Read-JsonFile -Path ([System.IO.Path]::GetFullPath($RequestPath))
$operation = "core-update"
if ($null -ne $request.PSObject.Properties["operation"] -and
    -not [string]::IsNullOrWhiteSpace([string]$request.operation)) {
    $operation = [string]$request.operation
}

if (-not $script:destructiveMaintenanceEnabled) {
    throw (
        "当前便携发布版仅支持只读版本检查，不在线改写 ComfyUI 核心或" +
        "内置 Python。请获取整合包维护版。"
    )
}

if ($operation -eq "repair-dependencies") {
    $repairRoot = [System.IO.Path]::GetFullPath(
        (Get-RequiredProperty $request "root")
    ).TrimEnd("\")
    $script:targetVersion = (
        Get-RequiredProperty $request "currentVersion"
    ).TrimStart("v", "V")
    $script:statusPath = [System.IO.Path]::GetFullPath(
        (Get-RequiredProperty $request "statusPath")
    )
    $script:logPath = [System.IO.Path]::GetFullPath(
        (Get-RequiredProperty $request "logPath")
    )
    [void](Assert-ChildPath `
        -Path $script:statusPath `
        -Parent (Join-Path $repairRoot "user\launcher\state"))
    [void](Assert-ChildPath `
        -Path $script:logPath `
        -Parent (Join-Path $repairRoot "user\launcher\logs"))
    try {
        Invoke-DependencyRepair -Request $request
        exit 0
    }
    catch {
        $failureMessage = ConvertTo-UpdateError $_
        Write-UpdateLog ("依赖恢复失败：" + $failureMessage)
        Publish-Status `
            -Stage "failed" `
            -Message ("依赖恢复失败：" + $failureMessage) `
            -Completed $true `
            -Success $false `
            -ErrorMessage $failureMessage
        exit 1
    }
}
elseif ($operation -ne "core-update") {
    throw "不支持的维护操作：$operation"
}

$root = [System.IO.Path]::GetFullPath((Get-RequiredProperty $request "root")).TrimEnd("\")
$script:targetVersion = (Get-RequiredProperty $request "targetVersion").TrimStart("v", "V")
$sourceUrl = Get-RequiredProperty $request "sourceUrl"
$sourceUrls = @($sourceUrl)
$sourceUrlsProperty = $request.PSObject.Properties["sourceUrls"]
if ($null -ne $sourceUrlsProperty -and $null -ne $sourceUrlsProperty.Value) {
    $sourceUrls = @($sourceUrlsProperty.Value | ForEach-Object { [string]$_ })
}
$pythonPath = [System.IO.Path]::GetFullPath((Get-RequiredProperty $request "pythonPath"))
$pypiIndexUrl = Get-RequiredProperty $request "pypiIndexUrl"
$script:statusPath = [System.IO.Path]::GetFullPath((Get-RequiredProperty $request "statusPath"))
$workRoot = [System.IO.Path]::GetFullPath((Get-RequiredProperty $request "workRoot")).TrimEnd("\")
$backupsRoot = [System.IO.Path]::GetFullPath((Get-RequiredProperty $request "backupsRoot")).TrimEnd("\")
$script:logPath = [System.IO.Path]::GetFullPath((Get-RequiredProperty $request "logPath"))
$currentVersion = (Get-RequiredProperty $request "currentVersion").TrimStart("v", "V")

if ($script:targetVersion -notmatch "^\d+\.\d+\.\d+(?:[-.][A-Za-z0-9.]+)?$") {
    throw "目标版本号格式无效。"
}
if (-not (Test-HttpUrl $sourceUrl)) {
    throw "源码下载地址无效。"
}
if (-not (Test-DirectChildPath -Path $workRoot -Parent (
    [System.IO.Path]::GetDirectoryName($workRoot)
))) {
    throw "更新临时目录无效。"
}
if (-not $workRoot.StartsWith(
    [System.IO.Path]::GetFullPath((Join-Path $root ".cache")) + "\",
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "更新临时目录必须位于整合包 .cache 内。"
}
if (-not $backupsRoot.StartsWith(
    [System.IO.Path]::GetFullPath((Join-Path $root ".cache")) + "\",
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "更新备份目录必须位于整合包 .cache 内。"
}

$archivePath = Join-Path $workRoot "source.zip"
$extractRoot = Join-Path $workRoot "extract"
$healthRoot = Join-Path $workRoot "health"
$transactionApplied = $false
$dependenciesChanged = $false
$dependencyInstallStarted = $false
$retainRecovery = $false
$dependencyMigration = $null
$requirementMigrationPlan = $null

try {
    Publish-Status -Stage "preflight" -Message "正在检查运行状态与磁盘空间…"
    if (-not [System.IO.Directory]::Exists($root)) {
        throw "ComfyUI 根目录不存在。"
    }
    if (Test-ComfyUIProcessRunning -Root $root) {
        throw "检测到 ComfyUI 仍在运行，请停止后重试。"
    }
    [long]$coreBytes = Get-CoreSizeBytes -Root $root
    Test-FreeSpace -Root $root -CoreBytes $coreBytes

    if ([System.IO.Directory]::Exists($workRoot)) {
        Remove-TreeWithoutFollowingReparse `
            -Path $workRoot `
            -ApprovedRoot ([System.IO.Path]::GetDirectoryName($workRoot))
    }
    [void][System.IO.Directory]::CreateDirectory($workRoot)
    if (-not [System.IO.Directory]::Exists($backupsRoot)) {
        [void][System.IO.Directory]::CreateDirectory($backupsRoot)
    }

    Publish-Status -Stage "download" -Message "正在下载官方源码归档…" -Percent 0
    Download-UpdateArchiveWithFallback `
        -Uris $sourceUrls `
        -DestinationPath $archivePath `
        -Request $request

    Publish-Status -Stage "verify" -Message "正在计算归档校验值并验证结构…"
    $script:downloadSha256 = (
        Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    Expand-ValidatedZip -ArchivePath $archivePath -DestinationPath $extractRoot
    $sourceRoot = Get-CoreSourceRoot -ExtractRoot $extractRoot
    $sourceVersion = Get-VersionFromSource -SourceRoot $sourceRoot
    if ($sourceVersion -ne $script:targetVersion) {
        throw (
            "源码版本与目标版本不一致：期望 {0}，实际 {1}。" -f
            $script:targetVersion,
            $sourceVersion
        )
    }
    foreach ($protected in Get-ProtectedNames) {
        if ($protected -in @((Get-CoreDirectoryNames) + (Get-CoreFileNames))) {
            throw "安全清单冲突：$protected"
        }
    }

    $oldRequirements = Join-Path $root "requirements.txt"
    $newRequirements = Join-Path $sourceRoot "requirements.txt"
    $oldRequirementHash = if ([System.IO.File]::Exists($oldRequirements)) {
        (Get-FileHash -LiteralPath $oldRequirements -Algorithm SHA256).Hash
    }
    else {
        ""
    }
    $newRequirementHash = (Get-FileHash -LiteralPath $newRequirements -Algorithm SHA256).Hash
    $requirementsFileChanged = ($oldRequirementHash -ne $newRequirementHash)
    $requirementMigrationPlan = Get-SafeRequirementMigrationPlan `
        -BaselineRequirementsPath $oldRequirements `
        -TargetRequirementsPath $newRequirements
    $dependenciesChanged = ([int]$requirementMigrationPlan.Count -gt 0)
    if ($dependenciesChanged) {
        $dependencyMigration = Invoke-DependencyMigrationPreflight `
            -PythonPath $pythonPath `
            -TargetRequirementsPath $newRequirements `
            -BaselineRequirementsPath $oldRequirements `
            -IndexUrl $pypiIndexUrl `
            -Request $request `
            -StageRoot (Join-Path $workRoot "dependency-transaction")
    }
    elseif ($requirementsFileChanged) {
        Write-UpdateLog (
            "requirements.txt 仅有顺序、注释或格式变化，" +
            "无需修改内置 Python 环境。"
        )
    }

    Publish-Status -Stage "backup" -Message "正在创建上一版本核心备份…"
    $backupName = "core-{0}-{1}" -f (
        $currentVersion,
        [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss")
    )
    $script:backupPath = Join-Path $backupsRoot $backupName
    if ([System.IO.Directory]::Exists($script:backupPath)) {
        throw "备份目录已存在。"
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        currentVersion = $currentVersion
        targetVersion = $script:targetVersion
        sourceUrl = $(if ([string]::IsNullOrWhiteSpace($script:downloadSourceUrl)) {
            $sourceUrl
        } else {
            $script:downloadSourceUrl
        })
        archiveSha256 = $script:downloadSha256
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        coreDirectories = Get-CoreDirectoryNames
        coreFiles = Get-CoreFileNames
        protectedNames = Get-ProtectedNames
        dependencyChanges = @($requirementMigrationPlan.Changes)
        preparedDependencyPackages = if ($null -ne $dependencyMigration) {
            [int]$dependencyMigration.Count
        }
        else {
            0
        }
    }
    [void][System.IO.Directory]::CreateDirectory($script:backupPath)
    Write-Utf8Atomic `
        -Path (Join-Path $script:backupPath "backup-manifest.json") `
        -Text ($manifest | ConvertTo-Json -Depth 6)

    Publish-Status -Stage "install" -Message "正在切换到新版本核心…"
    Apply-CoreTransaction `
        -Root $root `
        -SourceRoot $sourceRoot `
        -BackupRoot $script:backupPath
    $transactionApplied = $true

    if ($null -ne $dependencyMigration -and
        [int]$dependencyMigration.Count -gt 0) {
        $dependencyInstallStarted = $true
        Invoke-PreparedDependencySet `
            -PythonPath $pythonPath `
            -RequirementsPath (
                [string]$dependencyMigration.TargetRequirementsPath
            ) `
            -WheelDirectory (
                [string]$dependencyMigration.TargetWheelDirectory
            ) `
            -StatusMessage "正在应用目标版本依赖"
        Invoke-PortableEntrypointRepair -Root $root
    }

    Publish-Status -Stage "health" -Message "正在执行隔离启动健康检查…"
    Invoke-CoreHealthCheck `
        -PythonPath $pythonPath `
        -Root $root `
        -HealthRoot $healthRoot `
        -ExpectedVersion $script:targetVersion

    Publish-Status `
        -Stage "complete" `
        -Message ("ComfyUI 核心已成功更新到 " + $script:targetVersion + "。") `
        -Percent 100 `
        -Completed $true `
        -Success $true
}
catch {
    $failureMessage = ConvertTo-UpdateError $_
    Write-UpdateLog ("更新失败：" + $failureMessage)
    if ($transactionApplied -and
        -not [string]::IsNullOrWhiteSpace($script:backupPath) -and
        [System.IO.Directory]::Exists($script:backupPath)) {
        try {
            Publish-Status -Stage "rollback" -Message "更新失败，正在恢复上一版本…"
            Restore-CoreTransaction -Root $root -BackupRoot $script:backupPath
        }
        catch {
            $failureMessage += "；自动恢复未完全成功：" + (
                ConvertTo-SafeMessage $_.Exception.Message
            )
            $retainRecovery = $true
            Write-UpdateLog $failureMessage
        }
    }
    if ($dependencyInstallStarted -and
        $null -ne $dependencyMigration -and
        [int]$dependencyMigration.Count -gt 0) {
        try {
            Publish-Status -Stage "rollback" -Message "正在恢复上一版本依赖…"
            Invoke-PreparedDependencySet `
                -PythonPath $pythonPath `
                -RequirementsPath (
                    [string]$dependencyMigration.RollbackRequirementsPath
                ) `
                -WheelDirectory (
                    [string]$dependencyMigration.RollbackWheelDirectory
                ) `
                -StatusMessage "正在恢复上一版本依赖"
            Invoke-PortableEntrypointRepair -Root $root
        }
        catch {
            $failureMessage += "；依赖恢复失败：" + (
                ConvertTo-SafeMessage $_.Exception.Message
            )
            $retainRecovery = $true
            Write-UpdateLog $failureMessage
        }
    }
    Publish-Status `
        -Stage "failed" `
        -Message ("更新失败：" + $failureMessage) `
        -Completed $true `
        -Success $false `
        -ErrorMessage $failureMessage
    exit 1
}
finally {
    if ($retainRecovery) {
        Write-UpdateLog ("恢复未完成，离线恢复材料已保留：" + $workRoot)
    }
    if (-not $retainRecovery -and [System.IO.Directory]::Exists($workRoot)) {
        try {
            Remove-TreeWithoutFollowingReparse `
                -Path $workRoot `
                -ApprovedRoot ([System.IO.Path]::GetDirectoryName($workRoot))
        }
        catch {
            Write-UpdateLog ("临时目录清理警告：" + $_.Exception.Message)
        }
    }
}

exit 0
