param(
    [string]$Action = "",
    [string]$Root = "",
    [string]$Id = "",
    [string]$Name = "",
    [string]$Query = "",
    [string]$SettingsPath = "",
    [string]$RequestPath = "",
    [string]$ResultPath = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

$script:utf8 = New-Object System.Text.UTF8Encoding($false)
$script:settings = $null
$script:settingsPath = ""
$script:selfTestMode = $false
$script:logPath = ""
$script:workerResultPath = ""
$script:defaultCatalogUrl = (
    "https://raw.githubusercontent.com/ltdrdata/" +
    "ComfyUI-Manager/main/custom-node-list.json"
)
$script:knownGithubHosts = @(
    "github.com",
    "raw.githubusercontent.com",
    "codeload.github.com"
)
$script:mutationActions = @(
    "RefreshCatalog",
    "Enable",
    "Disable",
    "Install",
    "Remove",
    "Restore"
)
$script:corePythonPackages = @(
    "torch",
    "torchvision",
    "torchaudio",
    "xformers",
    "triton",
    "numpy",
    "pytorch-lightning",
    "onnxruntime",
    "onnxruntime-gpu"
)

function Get-ObjectValue {
    param(
        [object]$Object,
        [string]$Property,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Property)) {
            return $Object[$Property]
        }
        return $DefaultValue
    }
    $item = $Object.PSObject.Properties[$Property]
    if ($null -eq $item -or $null -eq $item.Value) {
        return $DefaultValue
    }
    return $item.Value
}

function Throw-WorkerError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data["WorkerCode"] = $Code
    throw $exception
}

function ConvertTo-SafeText {
    param(
        [string]$Text,
        [int]$MaximumLength = 1200
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $safe = [string]$Text
    if (Get-Command ConvertTo-LauncherSafeRunLogText -ErrorAction SilentlyContinue) {
        $safe = ConvertTo-LauncherSafeRunLogText $safe
    }
    else {
        $safe = [regex]::Replace(
            $safe,
            "(?i)(https?://)([^/@:\s]+):([^/@\s]+)@",
            '$1***:***@'
        )
        $safe = [regex]::Replace(
            $safe,
            "(?i)\b(token|password|passwd|cookie|authorization|api[_-]?key)" +
            "\s*[:=]\s*[^\s;]+",
            '$1=***'
        )
    }
    $safe = $safe.Replace(([string][char]0), "")
    if ($safe.Length -gt $MaximumLength) {
        $safe = $safe.Substring(0, $MaximumLength)
    }
    return $safe
}

function ConvertTo-PlainText {
    param(
        [string]$Text,
        [int]$MaximumLength = 420
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $plain = [regex]::Replace(
        [string]$Text,
        "\[a/([^\]]+)\]\([^)]+\)",
        '$1',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $plain = [regex]::Replace($plain, "\[([^\]]+)\]\([^)]+\)", '$1')
    $plain = [regex]::Replace($plain, "<[^>]+>", " ")
    $plain = [System.Net.WebUtility]::HtmlDecode($plain)
    $plain = [regex]::Replace($plain, "[\r\n\t]+", " ")
    $plain = [regex]::Replace($plain, "\s{2,}", " ").Trim()
    $plain = ConvertTo-SafeText -Text $plain -MaximumLength $MaximumLength
    return $plain
}

function New-WorkerResult {
    param(
        [Parameter(Mandatory = $true)][string]$ResultAction,
        [Parameter(Mandatory = $true)][bool]$Ok,
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Data = $null,
        [bool]$RestartRequired = $false,
        [bool]$RollbackAvailable = $false,
        [string]$TransactionId = ""
    )

    return [ordered]@{
        schemaVersion = 1
        action = $ResultAction
        ok = $Ok
        code = $Code
        message = ConvertTo-SafeText $Message
        data = $Data
        restartRequired = $RestartRequired
        rollbackAvailable = $RollbackAvailable
        transactionId = $TransactionId
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    }
}

function Write-WorkerResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    $json = $Result | ConvertTo-Json -Depth 12 -Compress
    if (-not [string]::IsNullOrWhiteSpace($script:workerResultPath)) {
        $temporaryPath = (
            $script:workerResultPath + ".tmp-" + [Guid]::NewGuid().ToString("N")
        )
        try {
            [System.IO.File]::WriteAllText($temporaryPath, $json, $script:utf8)
            [System.IO.File]::Move($temporaryPath, $script:workerResultPath)
        }
        finally {
            if ([System.IO.File]::Exists($temporaryPath)) {
                [System.IO.File]::Delete($temporaryPath)
            }
        }
        return
    }
    Write-Output $json
}

function Write-WorkerLog {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($script:logPath)) {
        return
    }
    try {
        $parent = [System.IO.Path]::GetDirectoryName($script:logPath)
        if (-not [System.IO.Directory]::Exists($parent)) {
            [void][System.IO.Directory]::CreateDirectory($parent)
        }
        $line = "[{0}] {1}{2}" -f (
            [DateTimeOffset]::Now.ToString("yyyy-MM-dd HH:mm:ss zzz"),
            (ConvertTo-SafeText -Text $Message -MaximumLength 3000),
            [Environment]::NewLine
        )
        [System.IO.File]::AppendAllText($script:logPath, $line, $script:utf8)
    }
    catch {
        # Logging must never turn a successful transaction into a failure.
    }
}

function Write-Utf8Atomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }
    $temporaryPath = Join-Path $parent (
        [System.IO.Path]::GetFileName($fullPath) +
        ".tmp-" +
        [Guid]::NewGuid().ToString("N")
    )
    $stream = New-Object System.IO.FileStream(
        $temporaryPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::WriteThrough
    )
    $writer = New-Object System.IO.StreamWriter($stream, $script:utf8)
    try {
        $writer.Write($Text)
        $writer.Flush()
        $stream.Flush($true)
    }
    finally {
        $writer.Dispose()
    }
    try {
        if ([System.IO.File]::Exists($fullPath)) {
            $backupPath = $fullPath + ".replace-bak"
            [System.IO.File]::Replace(
                $temporaryPath,
                $fullPath,
                $backupPath,
                $true
            )
            if ([System.IO.File]::Exists($backupPath)) {
                try {
                    [System.IO.File]::Delete($backupPath)
                }
                catch {
                    # File.Replace has already committed the destination.
                    # Failure to remove its safety copy is cleanup-only and
                    # must never be reported as a failed state commit.
                    Write-WorkerLog (
                        "原子写入备份清理警告：" +
                        (ConvertTo-SafeText $_.Exception.Message)
                    )
                }
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            try {
                [System.IO.File]::Delete($temporaryPath)
            }
            catch {
                # Preserve the original write error, or the already committed
                # result, rather than letting temporary cleanup mask it.
                Write-WorkerLog (
                    "原子写入临时文件清理警告：" +
                    (ConvertTo-SafeText $_.Exception.Message)
                )
            }
        }
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [long]$MaximumBytes = 4MB
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($fullPath)) {
        Throw-WorkerError "E_NOT_FOUND" "JSON 文件不存在。"
    }
    $length = (Get-Item -LiteralPath $fullPath -Force).Length
    if ($length -lt 1 -or $length -gt $MaximumBytes) {
        Throw-WorkerError "E_INVALID_JSON" "JSON 文件大小无效。"
    }
    try {
        $text = [System.IO.File]::ReadAllText($fullPath, $script:utf8)
        return $text | ConvertFrom-Json
    }
    catch {
        Throw-WorkerError "E_INVALID_JSON" "JSON 文件格式无效。"
    }
}

function Assert-WithinPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent,
        [switch]$AllowParent
    )

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $normalizedParent = [System.IO.Path]::GetFullPath($Parent).TrimEnd("\")
    if ($AllowParent -and $normalizedPath.Equals(
        $normalizedParent,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        return $normalizedPath
    }
    if (-not $normalizedPath.StartsWith(
        $normalizedParent + "\",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        Throw-WorkerError "E_PATH_UNSAFE" "路径超出启动器允许范围。"
    }
    return $normalizedPath
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

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path) -and
        -not [System.IO.Directory]::Exists($Path)) {
        return $false
    }
    $attributes = [System.IO.File]::GetAttributes($Path)
    return (
        ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    )
}

function Assert-NoReparseAncestors {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StopAt
    )

    $current = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $stop = [System.IO.Path]::GetFullPath($StopAt).TrimEnd("\")
    [void](Assert-WithinPath -Path $current -Parent $stop -AllowParent)
    while ($true) {
        if (([System.IO.File]::Exists($current) -or
            [System.IO.Directory]::Exists($current)) -and
            (Test-ReparsePoint $current)) {
            Throw-WorkerError "E_PATH_UNSAFE" "扩展路径包含不允许的重解析点。"
        }
        if ($current.Equals(
            $stop,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            break
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            Throw-WorkerError "E_PATH_UNSAFE" "无法验证扩展路径。"
        }
        $current = $parent.TrimEnd("\")
    }
}

function Test-SafeDirectoryName {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 120) {
        return $false
    }
    if ($Value -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
        $Value.EndsWith(".") -or $Value.EndsWith(" ")) {
        return $false
    }
    $baseName = $Value.Split(".")[0].ToUpperInvariant()
    if ($baseName -match "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$") {
        return $false
    }
    return $true
}

function Remove-TreeWithoutFollowingReparse {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ApprovedRoot
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($ApprovedRoot).TrimEnd("\")
    $normalizedPath = Assert-WithinPath -Path $Path -Parent $normalizedRoot
    if (-not [System.IO.Directory]::Exists($normalizedPath)) {
        return
    }
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{ Path = $normalizedPath; Expanded = $false })
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $itemPath = Assert-WithinPath -Path ([string]$item.Path) -Parent $normalizedRoot
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
        foreach ($child in [System.IO.Directory]::EnumerateFileSystemEntries($itemPath)) {
            $child = Assert-WithinPath -Path $child -Parent $normalizedRoot
            $childAttributes = [System.IO.File]::GetAttributes($child)
            $isDirectory = (
                ($childAttributes -band [System.IO.FileAttributes]::Directory) -ne 0
            )
            $childIsReparse = (
                ($childAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            )
            if ($isDirectory) {
                if ($childIsReparse) {
                    [System.IO.Directory]::Delete($child, $false)
                }
                else {
                    $stack.Push([pscustomobject]@{
                        Path = $child
                        Expanded = $false
                    })
                }
            }
            else {
                [System.IO.File]::SetAttributes(
                    $child,
                    $childAttributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                )
                [System.IO.File]::Delete($child)
            }
        }
    }
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (
            [System.BitConverter]::ToString($sha.ComputeHash($bytes))
        ).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-WorkerPaths {
    param([Parameter(Mandatory = $true)][string]$WorkerRoot)

    $rootPath = [System.IO.Path]::GetFullPath($WorkerRoot).TrimEnd("\")
    $customNodes = Join-Path $rootPath "custom_nodes"
    $launcherRoot = Join-Path $rootPath "user\launcher"
    $extensionsRoot = Join-Path $launcherRoot "extensions"
    return [pscustomobject]@{
        Root = $rootPath
        CustomNodes = $customNodes
        Disabled = Join-Path $customNodes ".disabled"
        Launcher = $launcherRoot
        Extensions = $extensionsRoot
        State = Join-Path $extensionsRoot "state.json"
        Catalog = Join-Path $extensionsRoot "catalog.json"
        Transactions = Join-Path $extensionsRoot "transactions"
        Lock = Join-Path $extensionsRoot "mutation.lock"
        Log = Join-Path $launcherRoot "logs\extension-worker.log"
        Staging = Join-Path $rootPath ".cache\launcher\extension-staging"
        BundledManifest = Join-Path $rootPath "tools\bundled-custom-nodes.json"
        Python = Join-Path $rootPath ".ext\python.exe"
    }
}

function Initialize-WorkerRoot {
    param([Parameter(Mandatory = $true)][string]$WorkerRoot)

    if ([string]::IsNullOrWhiteSpace($WorkerRoot)) {
        Throw-WorkerError "E_INVALID_REQUEST" "必须提供 ComfyUI 根目录。"
    }
    $paths = Get-WorkerPaths -WorkerRoot $WorkerRoot
    if (-not [System.IO.Directory]::Exists($paths.Root) -or
        -not [System.IO.Directory]::Exists($paths.CustomNodes) -or
        -not [System.IO.File]::Exists((Join-Path $paths.Root "main.py"))) {
        Throw-WorkerError "E_INVALID_ROOT" "指定目录不是有效的 ComfyUI 整合包。"
    }
    Assert-NoReparseAncestors -Path $paths.CustomNodes -StopAt $paths.Root
    if ([System.IO.Directory]::Exists($paths.Disabled)) {
        Assert-NoReparseAncestors -Path $paths.Disabled -StopAt $paths.Root
    }
    foreach ($directory in @(
        $paths.Launcher,
        $paths.Extensions,
        $paths.Transactions,
        $paths.Staging
    )) {
        if (-not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }
        Assert-NoReparseAncestors -Path $directory -StopAt $paths.Root
    }
    $script:logPath = $paths.Log
    return $paths
}

function Read-WorkerState {
    param([Parameter(Mandatory = $true)][object]$Paths)

    if (-not [System.IO.File]::Exists($Paths.State)) {
        return [pscustomobject]@{
            schemaVersion = 1
            generation = 0
            managed = @()
        }
    }
    $loaded = Read-JsonFile -Path $Paths.State -MaximumBytes 2MB
    if ([int](Get-ObjectValue $loaded "schemaVersion" 0) -ne 1) {
        Throw-WorkerError "E_STATE_INVALID" "扩展状态版本无效。"
    }
    $managed = New-Object System.Collections.Generic.List[object]
    foreach ($record in @(Get-ObjectValue $loaded "managed" @())) {
        $recordId = [string](Get-ObjectValue $record "id" "")
        $directory = [string](Get-ObjectValue $record "directory" "")
        if ($recordId -notmatch "^managed:[a-f0-9]{24}$" -or
            -not (Test-SafeDirectoryName $directory)) {
            Throw-WorkerError "E_STATE_INVALID" "扩展状态包含无效记录。"
        }
        $managed.Add($record)
    }
    return [pscustomobject]@{
        schemaVersion = 1
        generation = [int](Get-ObjectValue $loaded "generation" 0)
        managed = $managed.ToArray()
    }
}

function Save-WorkerState {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$State
    )

    $State.generation = [int]$State.generation + 1
    Write-Utf8Atomic -Path $Paths.State -Text (
        $State | ConvertTo-Json -Depth 10
    )
}

function Get-BundledNodeSet {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ([System.IO.File]::Exists($Paths.BundledManifest)) {
        try {
            $manifest = Read-JsonFile `
                -Path $Paths.BundledManifest `
                -MaximumBytes 4MB
            $nodes = @(Get-ObjectValue $manifest "nodes" @())
            $manifestValid = (
                [int](Get-ObjectValue $manifest "schemaVersion" 0) -eq 1 -and
                [string](Get-ObjectValue $manifest "policy" "") -eq
                    "protected-release-baseline" -and
                [int](Get-ObjectValue $manifest "count" -1) -eq $nodes.Count
            )
            foreach ($node in $nodes) {
                $directory = [string](
                    Get-ObjectValue $node "directory" ""
                )
                $relativePath = [string](
                    Get-ObjectValue $node "relativePath" ""
                )
                $initialState = [string](
                    Get-ObjectValue $node "initialState" ""
                )
                $expectedRelativePath = if ($initialState -eq "enabled") {
                    "custom_nodes\$directory"
                }
                elseif ($initialState -eq "disabled") {
                    "custom_nodes\.disabled\$directory"
                }
                else {
                    ""
                }
                if (-not (Test-SafeDirectoryName $directory) -or
                    [string]::IsNullOrWhiteSpace($expectedRelativePath) -or
                    -not $relativePath.Equals(
                        $expectedRelativePath,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    $manifestValid = $false
                    break
                }
                [void]$set.Add($directory)
            }
            if ($manifestValid) {
                # PowerShell enumerates collection objects written to the
                # pipeline.  Preserve the HashSet itself so callers always
                # receive an object with the expected Contains method,
                # including when the protected set is empty.
                return ,$set
            }
        }
        catch {
            Write-WorkerLog (
                "发布版扩展保护清单无效，已启用保守保护：{0}" -f
                (ConvertTo-SafeText $_.Exception.Message)
            )
        }
        $set.Clear()
    }

    # Fail safe for an older release or an invalid baseline manifest: every
    # existing directory is protected rather than allowing accidental removal.
    foreach ($parent in @($Paths.CustomNodes, $Paths.Disabled)) {
        if (-not [System.IO.Directory]::Exists($parent) -or
            (Test-ReparsePoint $parent)) {
            continue
        }
        foreach ($directory in @(
            Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction Stop
        )) {
            if ($directory.Name -notin @(".disabled", "__pycache__") -and
                (Test-SafeDirectoryName $directory.Name)) {
                [void]$set.Add($directory.Name)
            }
        }
    }
    return ,$set
}

function Get-ManagedRecordMap {
    param([Parameter(Mandatory = $true)][object]$State)

    $map = @{}
    foreach ($record in @($State.managed)) {
        $map[[string]$record.directory] = $record
    }
    return $map
}

function Test-ManagedRecordProvenance {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Record
    )

    try {
        $recordId = [string](Get-ObjectValue $Record "id" "")
        $directory = [string](Get-ObjectValue $Record "directory" "")
        $sourceUrl = [string](Get-ObjectValue $Record "sourceUrl" "")
        $catalogId = [string](Get-ObjectValue $Record "catalogId" "")
        $transactionId = [string](
            Get-ObjectValue $Record "installTransactionId" ""
        )
        if ($recordId -notmatch "^managed:[a-f0-9]{24}$" -or
            -not (Test-SafeDirectoryName $directory) -or
            -not (Test-TrustedGithubRepositoryUrl $sourceUrl) -or
            $catalogId -notmatch "^catalog:[a-f0-9]{24}$" -or
            $transactionId -notmatch "^[a-f0-9]{32}$") {
            return $false
        }
        $transactionRoot = Join-Path $Paths.Transactions $transactionId
        [void](Assert-WithinPath `
            -Path $transactionRoot `
            -Parent $Paths.Transactions)
        if (-not [System.IO.Directory]::Exists($transactionRoot)) {
            return $false
        }
        Assert-NoReparseAncestors `
            -Path $transactionRoot `
            -StopAt $Paths.Root
        $manifestPath = Join-Path $transactionRoot "transaction.json"
        $manifest = Read-JsonFile -Path $manifestPath -MaximumBytes 1MB
        return (
            [string](Get-ObjectValue $manifest "id" "") -eq $transactionId -and
            [string](Get-ObjectValue $manifest "operation" "") -eq "install" -and
            [string](Get-ObjectValue $manifest "phase" "") -eq "completed" -and
            ([string](Get-ObjectValue $manifest "directory" "")).Equals(
                $directory,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            ([string](Get-ObjectValue $manifest "sourceUrl" "")).Equals(
                (Normalize-GithubRepositoryUrl $sourceUrl),
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
    }
    catch {
        return $false
    }
}

function New-InstalledItem {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$StateName,
        [Parameter(Mandatory = $true)][string]$Path,
        [object]$ManagedRecord,
        [bool]$Bundled,
        [bool]$ManagedVerified = $false,
        [bool]$UnsafePath = $false
    )

    $isManaged = $null -ne $ManagedRecord
    $idValue = if ($isManaged) {
        [string]$ManagedRecord.id
    }
    elseif ($Bundled) {
        "bundled:" + $Directory
    }
    else {
        "external:" + (Get-Sha256Text $Directory).Substring(0, 24)
    }
    $sourceUrl = if ($isManaged) {
        [string](Get-ObjectValue $ManagedRecord "sourceUrl" "")
    }
    else {
        ""
    }
    $displayName = if ($isManaged -and
        -not [string]::IsNullOrWhiteSpace(
            [string](Get-ObjectValue $ManagedRecord "displayName" "")
        )) {
        [string]$ManagedRecord.displayName
    }
    else {
        $Directory
    }
    $effectiveState = if ($UnsafePath -or
        ($isManaged -and -not $ManagedVerified)) {
        "attention"
    }
    else {
        $StateName
    }
    $stateText = switch ($effectiveState) {
        "enabled" { "已启用" }
        "disabled" { "已停用" }
        "recoverable" { "已移除（已备份）" }
        default { "需要处理" }
    }
    if ($UnsafePath) {
        $stateText = "路径异常"
    }
    elseif ($isManaged -and -not $ManagedVerified) {
        $stateText = "管理记录异常"
    }
    $sourceText = if ($Bundled) {
        "发布版内置"
    }
    elseif ($isManaged -and $ManagedVerified) {
        "启动器安装"
    }
    elseif ($isManaged) {
        "管理记录异常"
    }
    else {
        "外部扩展"
    }
    $versionText = if ($Bundled) {
        "随发布版"
    }
    elseif ($isManaged) {
        [string](Get-ObjectValue $ManagedRecord "versionText" "GitHub HEAD")
    }
    else {
        "未知"
    }
    return [pscustomobject][ordered]@{
        Id = $idValue
        DisplayName = $displayName
        StateText = $stateText
        SourceText = $sourceText
        VersionText = $versionText
        Path = $Path
        SourceUrl = $sourceUrl
        CanEnable = ($effectiveState -eq "disabled")
        CanDisable = ($effectiveState -eq "enabled")
        CanOpenFolder = (-not $UnsafePath)
        CanRestore = (
            $effectiveState -eq "recoverable" -and
            $isManaged -and
            $ManagedVerified
        )
        CanRemove = (
            $isManaged -and
            $ManagedVerified -and
            -not $Bundled -and
            $effectiveState -in @("enabled", "disabled") -and
            -not $UnsafePath
        )
        Directory = $Directory
        State = $effectiveState
        Origin = if ($Bundled) {
            "bundled"
        }
        elseif ($isManaged -and $ManagedVerified) {
            "launcher"
        }
        elseif ($isManaged) {
            "attention"
        }
        else {
            "external"
        }
    }
}

function Test-RecoverableManagedBackup {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Record
    )

    try {
        if (-not (Test-ManagedRecordProvenance `
            -Paths $Paths `
            -Record $Record)) {
            return $false
        }
        $transactionId = [string](
            Get-ObjectValue $Record "backupTransactionId" ""
        )
        if ($transactionId -notmatch "^[a-f0-9]{32}$") {
            return $false
        }
        $transactionRoot = Join-Path $Paths.Transactions $transactionId
        if (-not (Test-DirectChildPath `
                -Path $transactionRoot `
                -Parent $Paths.Transactions) -or
            -not [System.IO.Directory]::Exists($transactionRoot) -or
            [System.IO.File]::Exists($transactionRoot) -or
            (Test-ReparsePoint $transactionRoot)) {
            return $false
        }
        Assert-NoReparseAncestors `
            -Path $transactionRoot `
            -StopAt $Paths.Transactions

        $manifestPath = Join-Path $transactionRoot "transaction.json"
        if (-not (Test-DirectChildPath `
                -Path $manifestPath `
                -Parent $transactionRoot) -or
            -not [System.IO.File]::Exists($manifestPath) -or
            (Test-ReparsePoint $manifestPath)) {
            return $false
        }
        $manifest = Read-JsonFile -Path $manifestPath -MaximumBytes 1MB
        $previousState = [string](
            Get-ObjectValue $Record "previousState" ""
        )
        $directory = [string](Get-ObjectValue $Record "directory" "")
        if ($previousState -notin @("enabled", "disabled") -or
            -not (Test-SafeDirectoryName $directory) -or
            [int](Get-ObjectValue $manifest "schemaVersion" 0) -ne 1 -or
            [string](Get-ObjectValue $manifest "id" "") -ne $transactionId -or
            [string](Get-ObjectValue $manifest "operation" "") -ne "remove" -or
            [string](Get-ObjectValue $manifest "phase" "") -ne "completed" -or
            [string](Get-ObjectValue $manifest "previousState" "") -ne
                $previousState -or
            -not ([string](
                Get-ObjectValue $manifest "directory" ""
            )).Equals(
                $directory,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            return $false
        }

        $backupParent = Join-Path $transactionRoot "backup"
        $backupPath = Join-Path $backupParent $directory
        if (-not (Test-DirectChildPath `
                -Path $backupParent `
                -Parent $transactionRoot) -or
            -not [System.IO.Directory]::Exists($backupParent) -or
            [System.IO.File]::Exists($backupParent) -or
            (Test-ReparsePoint $backupParent) -or
            -not (Test-DirectChildPath `
                -Path $backupPath `
                -Parent $backupParent) -or
            -not [System.IO.Directory]::Exists($backupPath) -or
            [System.IO.File]::Exists($backupPath) -or
            (Test-ReparsePoint $backupPath)) {
            return $false
        }
        Assert-NoReparseAncestors `
            -Path $backupPath `
            -StopAt $Paths.Transactions
        return $true
    }
    catch {
        return $false
    }
}

function Get-InstalledItems {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [object]$State = $null
    )

    if ($null -eq $State) {
        $State = Read-WorkerState $Paths
    }
    $bundled = Get-BundledNodeSet $Paths
    $managedMap = Get-ManagedRecordMap $State
    $items = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($definition in @(
        [pscustomobject]@{ Parent = $Paths.CustomNodes; State = "enabled" },
        [pscustomobject]@{ Parent = $Paths.Disabled; State = "disabled" }
    )) {
        if (-not [System.IO.Directory]::Exists($definition.Parent)) {
            continue
        }
        if (Test-ReparsePoint $definition.Parent) {
            Throw-WorkerError "E_PATH_UNSAFE" "扩展启停目录是重解析点。"
        }
        foreach ($directory in @(
            Get-ChildItem -LiteralPath $definition.Parent -Directory -Force |
                Sort-Object Name
        )) {
            if ($directory.Name -in @(".disabled", "__pycache__")) {
                continue
            }
            if (-not (Test-SafeDirectoryName $directory.Name)) {
                continue
            }
            [void]$seen.Add($directory.Name)
            $managedRecord = $null
            $managedVerified = $false
            if ($managedMap.ContainsKey($directory.Name)) {
                $managedRecord = $managedMap[$directory.Name]
                $managedVerified = Test-ManagedRecordProvenance `
                    -Paths $Paths `
                    -Record $managedRecord
            }
            $items.Add((New-InstalledItem `
                -Directory $directory.Name `
                -StateName $definition.State `
                -Path $directory.FullName `
                -ManagedRecord $managedRecord `
                -Bundled $bundled.Contains($directory.Name) `
                -ManagedVerified $managedVerified `
                -UnsafePath (Test-ReparsePoint $directory.FullName)))
        }
    }

    foreach ($record in @($State.managed)) {
        $recordState = [string](Get-ObjectValue $record "state" "")
        if ($recordState -ne "removed" -or
            $seen.Contains([string]$record.directory)) {
            continue
        }
        $transactionId = [string](
            Get-ObjectValue $record "backupTransactionId" ""
        )
        $backupPath = ""
        if ($transactionId -match "^[a-f0-9]{32}$") {
            $backupPath = Join-Path (
                Join-Path $Paths.Transactions $transactionId
            ) ("backup\" + [string]$record.directory)
        }
        $available = Test-RecoverableManagedBackup `
            -Paths $Paths `
            -Record $record
        $managedVerified = Test-ManagedRecordProvenance `
            -Paths $Paths `
            -Record $record
        $items.Add((New-InstalledItem `
            -Directory ([string]$record.directory) `
            -StateName $(if ($available) { "recoverable" } else { "attention" }) `
            -Path $backupPath `
            -ManagedRecord $record `
            -Bundled $false `
            -ManagedVerified $managedVerified `
            -UnsafePath (-not $available)))
    }

    return @($items | Sort-Object DisplayName)
}

function Resolve-InstalledItem {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [string]$ItemId,
        [string]$ItemName
    )

    $matches = @(
        Get-InstalledItems $Paths |
            Where-Object {
                (
                    -not [string]::IsNullOrWhiteSpace($ItemId) -and
                    $_.Id.Equals(
                        $ItemId,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                ) -or (
                    -not [string]::IsNullOrWhiteSpace($ItemName) -and
                    (
                        $_.Directory.Equals(
                            $ItemName,
                            [System.StringComparison]::OrdinalIgnoreCase
                        ) -or
                        $_.DisplayName.Equals(
                            $ItemName,
                            [System.StringComparison]::OrdinalIgnoreCase
                        )
                    )
                )
            }
    )
    if ($matches.Count -eq 0) {
        Throw-WorkerError "E_NOT_FOUND" "没有找到指定扩展。"
    }
    if ($matches.Count -gt 1) {
        Throw-WorkerError "E_AMBIGUOUS" "扩展名称不唯一，请使用 Id。"
    }
    return $matches[0]
}

function Test-TrustedGithubRepositoryUrl {
    param([string]$Value)

    $uri = $null
    if (-not [System.Uri]::TryCreate(
        ([string]$Value).Trim(),
        [System.UriKind]::Absolute,
        [ref]$uri
    )) {
        return $false
    }
    if ($uri.Scheme -ne "https" -or
        -not $uri.Host.Equals(
            "github.com",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        return $false
    }
    $segments = @(
        $uri.AbsolutePath.Trim("/").Split("/") |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($segments.Count -ne 2) {
        return $false
    }
    $owner = $segments[0]
    $repository = $segments[1] -replace "\.git$", ""
    return (
        $owner -match "^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$" -and
        $repository -match "^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$"
    )
}

function Normalize-GithubRepositoryUrl {
    param([Parameter(Mandatory = $true)][string]$Value)

    if (-not (Test-TrustedGithubRepositoryUrl $Value)) {
        Throw-WorkerError "E_SOURCE_UNTRUSTED" (
            "扩展来源不符合 GitHub HTTPS 仓库地址规则。"
        )
    }
    $uri = New-Object System.Uri($Value.Trim())
    $segments = @($uri.AbsolutePath.Trim("/").Split("/"))
    $repository = $segments[1] -replace "\.git$", ""
    return "https://github.com/{0}/{1}" -f $segments[0], $repository
}

function Get-RepositoryDirectoryName {
    param([Parameter(Mandatory = $true)][string]$SourceUrl)

    $normalized = Normalize-GithubRepositoryUrl $SourceUrl
    $uri = New-Object System.Uri($normalized)
    $name = $uri.AbsolutePath.Trim("/").Split("/")[1]
    if (-not (Test-SafeDirectoryName $name)) {
        Throw-WorkerError "E_SOURCE_UNTRUSTED" "GitHub 仓库名称不适合作为扩展目录。"
    }
    return $name
}

function Convert-CatalogDocument {
    param([Parameter(Mandatory = $true)][object]$Document)

    $rawItems = @(Get-ObjectValue $Document "custom_nodes" @())
    if ($rawItems.Count -eq 0 -or $rawItems.Count -gt 20000) {
        Throw-WorkerError "E_CATALOG_INVALID" "扩展目录结构无效。"
    }
    $items = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($raw in $rawItems) {
        if (-not ([string](Get-ObjectValue $raw "install_type" "")).Equals(
            "git-clone",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            continue
        }
        $title = ConvertTo-PlainText (
            [string](Get-ObjectValue $raw "title" "")
        ) 160
        if ($title -match "(?i)do not install|don't install|test nodepack") {
            continue
        }
        $sourceUrl = ""
        foreach ($candidate in @(
            @(Get-ObjectValue $raw "files" @()) +
            @([string](Get-ObjectValue $raw "reference" ""))
        )) {
            if (Test-TrustedGithubRepositoryUrl ([string]$candidate)) {
                $sourceUrl = Normalize-GithubRepositoryUrl ([string]$candidate)
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($sourceUrl) -or
            -not $seen.Add($sourceUrl)) {
            continue
        }
        $directory = Get-RepositoryDirectoryName $sourceUrl
        if ([string]::IsNullOrWhiteSpace($title) -or
            $title -notmatch "[\p{L}\p{Nd}]") {
            $title = $directory
        }
        $catalogId = "catalog:" + (
            Get-Sha256Text $sourceUrl
        ).Substring(0, 24)
        $items.Add([pscustomobject][ordered]@{
            Id = $catalogId
            DisplayName = $title
            Description = ConvertTo-PlainText (
                [string](Get-ObjectValue $raw "description" "")
            ) 420
            Author = ConvertTo-PlainText (
                [string](Get-ObjectValue $raw "author" "")
            ) 100
            SourceText = "GitHub"
            SourceUrl = $sourceUrl
            Directory = $directory
        })
    }
    if ($items.Count -eq 0) {
        Throw-WorkerError "E_CATALOG_INVALID" (
            "公开扩展目录中没有符合规则的 GitHub HTTPS 条目。"
        )
    }
    return @($items | Sort-Object DisplayName)
}

function Read-CatalogCache {
    param([Parameter(Mandatory = $true)][object]$Paths)

    if (-not [System.IO.File]::Exists($Paths.Catalog)) {
        return $null
    }
    $cache = Read-JsonFile -Path $Paths.Catalog -MaximumBytes 16MB
    if ([int](Get-ObjectValue $cache "schemaVersion" 0) -ne 1) {
        Throw-WorkerError "E_CATALOG_INVALID" "本地扩展目录版本无效。"
    }
    $items = @(Get-ObjectValue $cache "items" @())
    if ($items.Count -eq 0 -or $items.Count -gt 20000) {
        Throw-WorkerError "E_CATALOG_INVALID" "本地扩展目录内容无效。"
    }
    foreach ($item in $items) {
        if ([string](Get-ObjectValue $item "Id" "") -notmatch
            "^catalog:[a-f0-9]{24}$" -or
            -not (Test-TrustedGithubRepositoryUrl (
                [string](Get-ObjectValue $item "SourceUrl" "")
            ))) {
            Throw-WorkerError "E_CATALOG_INVALID" "本地扩展目录包含无效条目。"
        }
    }
    return $cache
}

function Resolve-CatalogItem {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$CatalogId
    )

    $cache = Read-CatalogCache $Paths
    if ($null -eq $cache) {
        Throw-WorkerError "E_CATALOG_MISSING" "请先刷新扩展目录。"
    }
    $matches = @(
        @(Get-ObjectValue $cache "items" @()) |
            Where-Object {
                ([string]$_.Id).Equals(
                    $CatalogId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
    )
    if ($matches.Count -ne 1) {
        Throw-WorkerError "E_NOT_FOUND" "扩展目录中没有找到指定条目。"
    }
    return $matches[0]
}

function Get-NetworkSettings {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [string]$RequestedSettingsPath
    )

    $candidate = $RequestedSettingsPath
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = Join-Path $Paths.Launcher "settings.json"
    }
    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    [void](Assert-WithinPath -Path $fullPath -Parent $Paths.Launcher)
    if ([System.IO.File]::Exists($fullPath)) {
        $length = (Get-Item -LiteralPath $fullPath -Force).Length
        if ($length -gt 1MB) {
            Throw-WorkerError "E_SETTINGS_INVALID" "网络设置文件过大。"
        }
        try {
            $raw = [System.IO.File]::ReadAllText($fullPath, $script:utf8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                [void]($raw | ConvertFrom-Json)
            }
        }
        catch {
            Throw-WorkerError "E_SETTINGS_INVALID" "网络设置文件格式无效。"
        }
    }
    $script:settingsPath = $fullPath
    $script:settings = Read-LauncherSettings $fullPath
    return $script:settings
}

function New-WorkerHttpClient {
    param(
        [Parameter(Mandatory = $true)][object]$Settings,
        [int]$TimeoutSeconds = 120
    )

    Add-Type -AssemblyName System.Net.Http
    [System.Net.ServicePointManager]::SecurityProtocol = (
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls12
    )
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    switch ([string]$Settings.network.proxy.mode) {
        "none" {
            $handler.UseProxy = $false
        }
        "custom" {
            $proxyUri = Get-LauncherProxyUri $Settings
            if ($null -eq $proxyUri) {
                Throw-WorkerError "E_SETTINGS_INVALID" "自定义代理地址或端口无效。"
            }
            $handler.UseProxy = $true
            $handler.Proxy = New-Object System.Net.WebProxy($proxyUri, $true)
        }
        default {
            $handler.UseProxy = $true
            $handler.Proxy = [System.Net.WebRequest]::DefaultWebProxy
        }
    }
    $client = New-Object System.Net.Http.HttpClient($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds(
        [Math]::Max(5, $TimeoutSeconds)
    )
    $client.DefaultRequestHeaders.UserAgent.ParseAdd(
        "ComfyUI-Desktop-Launcher/1.2"
    )
    return $client
}

function Get-TaskDownloadUrl {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalUrl,
        [Parameter(Mandatory = $true)][object]$Settings
    )

    $converted = ConvertTo-LauncherGithubDownloadUrl `
        -OriginalUrl $OriginalUrl `
        -Settings $Settings
    $uri = $null
    if (-not [System.Uri]::TryCreate(
        $converted,
        [System.UriKind]::Absolute,
        [ref]$uri
    ) -or $uri.Scheme -ne "https" -or
        -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        Throw-WorkerError "E_SOURCE_UNTRUSTED" "当前 GitHub 下载地址不符合 HTTPS 来源规则。"
    }
    return $uri.AbsoluteUri
}

function Invoke-LimitedHttpDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][object]$Settings,
        [long]$MaximumBytes,
        [string[]]$AdditionalAllowedHosts = @()
    )

    $current = New-Object System.Uri($Uri)
    $allowedHosts = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($hostName in @(
        $script:knownGithubHosts +
        $AdditionalAllowedHosts +
        @($current.Host)
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$hostName)) {
            [void]$allowedHosts.Add([string]$hostName)
        }
    }
    $client = New-WorkerHttpClient -Settings $Settings -TimeoutSeconds 180
    try {
        $response = $null
        foreach ($redirect in 0..5) {
            if ($current.Scheme -ne "https" -or
                -not $allowedHosts.Contains($current.Host) -or
                -not [string]::IsNullOrEmpty($current.UserInfo)) {
                Throw-WorkerError "E_SOURCE_UNTRUSTED" (
                    "下载跳转到了允许范围之外的地址。"
                )
            }
            $response = $client.GetAsync(
                $current,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()
            $status = [int]$response.StatusCode
            if ($status -in @(301, 302, 303, 307, 308)) {
                $location = $response.Headers.Location
                $response.Dispose()
                $response = $null
                if ($null -eq $location) {
                    Throw-WorkerError "E_NETWORK" "下载服务器返回了无效跳转。"
                }
                if (-not $location.IsAbsoluteUri) {
                    $location = New-Object System.Uri($current, $location)
                }
                $current = $location
                continue
            }
            break
        }
        if ($null -eq $response) {
            Throw-WorkerError "E_NETWORK" "下载跳转次数过多。"
        }
        try {
            [void]$response.EnsureSuccessStatusCode()
            $contentLength = $response.Content.Headers.ContentLength
            if ($null -ne $contentLength -and
                [long]$contentLength -gt $MaximumBytes) {
                Throw-WorkerError "E_DOWNLOAD_TOO_LARGE" "下载内容超过安全大小限制。"
            }
            $parent = [System.IO.Path]::GetDirectoryName($DestinationPath)
            if (-not [System.IO.Directory]::Exists($parent)) {
                [void][System.IO.Directory]::CreateDirectory($parent)
            }
            $input = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $output = New-Object System.IO.FileStream(
                $DestinationPath,
                [System.IO.FileMode]::Create,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            try {
                $buffer = New-Object byte[] 131072
                [long]$total = 0
                while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $total += $read
                    if ($total -gt $MaximumBytes) {
                        Throw-WorkerError "E_DOWNLOAD_TOO_LARGE" "下载内容超过安全大小限制。"
                    }
                    $output.Write($buffer, 0, $read)
                }
                $output.Flush()
            }
            finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
        finally {
            $response.Dispose()
        }
    }
    catch {
        if ([System.IO.File]::Exists($DestinationPath)) {
            [System.IO.File]::Delete($DestinationPath)
        }
        throw
    }
    finally {
        $client.Dispose()
    }
    if (-not [System.IO.File]::Exists($DestinationPath) -or
        (Get-Item -LiteralPath $DestinationPath).Length -lt 2) {
        Throw-WorkerError "E_NETWORK" "下载结果为空。"
    }
}

function Test-SafeArchiveComponent {
    param([string]$Component)

    if ([string]::IsNullOrWhiteSpace($Component) -or
        $Component.EndsWith(".") -or $Component.EndsWith(" ") -or
        $Component.Contains(":")) {
        return $false
    }
    $baseName = $Component.Split(".")[0].ToUpperInvariant()
    return $baseName -notmatch "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$"
}

function Expand-ValidatedExtensionZip {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [int]$MaximumEntries = 50000,
        [long]$MaximumUncompressedBytes = 2GB
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not [System.IO.Directory]::Exists($DestinationPath)) {
        [void][System.IO.Directory]::CreateDirectory($DestinationPath)
    }
    $destinationRoot = [System.IO.Path]::GetFullPath(
        $DestinationPath
    ).TrimEnd("\")
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -lt 1 -or
            $archive.Entries.Count -gt $MaximumEntries) {
            Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档文件数量异常。"
        }
        [long]$totalUncompressed = 0
        foreach ($entry in $archive.Entries) {
            $unixMode = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            if ($unixMode -eq 0xA000) {
                Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档包含符号链接。"
            }
            if ($entry.Length -gt 512MB) {
                Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档包含超大单文件。"
            }
            $totalUncompressed += [long]$entry.Length
            if ($totalUncompressed -gt $MaximumUncompressedBytes) {
                Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档解压体积超过限制。"
            }
            if ($entry.CompressedLength -eq 0 -and $entry.Length -gt 1MB) {
                Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档压缩比例异常。"
            }
            if ($entry.CompressedLength -gt 0 -and
                ($entry.Length / [double]$entry.CompressedLength) -gt 1200) {
                Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档压缩比例异常。"
            }
            $relative = $entry.FullName.Replace(
                [System.IO.Path]::AltDirectorySeparatorChar,
                [System.IO.Path]::DirectorySeparatorChar
            )
            foreach ($component in @(
                $relative.Split("\") |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )) {
                if (-not (Test-SafeArchiveComponent $component)) {
                    Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档包含非法文件名。"
                }
            }
            $target = [System.IO.Path]::GetFullPath(
                (Join-Path $destinationRoot $relative)
            )
            if (-not $target.StartsWith(
                $destinationRoot + "\",
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档包含路径穿越。"
            }
            if ([string]::IsNullOrEmpty($entry.Name)) {
                if (-not [System.IO.Directory]::Exists($target)) {
                    [void][System.IO.Directory]::CreateDirectory($target)
                }
                continue
            }
            $parent = [System.IO.Path]::GetDirectoryName($target)
            if (-not [System.IO.Directory]::Exists($parent)) {
                [void][System.IO.Directory]::CreateDirectory($parent)
            }
            $entryStream = $entry.Open()
            $fileStream = New-Object System.IO.FileStream(
                $target,
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

function Get-ValidatedExtensionSourceRoot {
    param([Parameter(Mandatory = $true)][string]$ExtractRoot)

    $rootFiles = @(
        Get-ChildItem -LiteralPath $ExtractRoot -File -Force -ErrorAction Stop
    )
    $directories = @(
        Get-ChildItem -LiteralPath $ExtractRoot -Directory -Force -ErrorAction Stop
    )
    if ($rootFiles.Count -ne 0 -or $directories.Count -ne 1) {
        Throw-WorkerError "E_ARCHIVE_UNSAFE" "GitHub 扩展归档根结构无效。"
    }
    $sourceRoot = $directories[0].FullName
    foreach ($entry in @(
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -ErrorAction Stop
    )) {
        if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展内容包含重解析点。"
        }
        if ($entry.Name -ieq ".gitmodules") {
            Throw-WorkerError "E_POLICY_BLOCKED" "暂不支持包含 Git 子模块的扩展。"
        }
        if ($entry.Name -ieq "install.py") {
            Throw-WorkerError "E_SCRIPT_REQUIRED" (
                "此扩展需要执行额外安装脚本，当前自动安装策略不支持。"
            )
        }
    }
    $pythonFiles = @(
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Filter "*.py"
    )
    if ($pythonFiles.Count -eq 0) {
        Throw-WorkerError "E_ARCHIVE_UNSAFE" "扩展归档中没有 Python 节点代码。"
    }
    return $sourceRoot
}

function Test-ComfyUIRunning {
    param([Parameter(Mandatory = $true)][object]$Paths)

    if ($script:selfTestMode) {
        return $false
    }
    try {
        $normalizedRoot = [System.IO.Path]::GetFullPath([string]$Paths.Root)
        $expectedPython = [System.IO.Path]::GetFullPath([string]$Paths.Python)
        $processes = Get-CimInstance Win32_Process -Filter (
            "Name='python.exe' OR Name='pythonw.exe'"
        ) -ErrorAction Stop
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            $rootMatches = $commandLine.IndexOf(
                $normalizedRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
            $pythonMatches = $false
            $processExecutable = [string]$process.ExecutablePath
            if (-not [string]::IsNullOrWhiteSpace($processExecutable)) {
                try {
                    $pythonMatches = (
                        [System.IO.Path]::GetFullPath($processExecutable)
                    ).Equals(
                        $expectedPython,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )
                }
                catch {
                    $pythonMatches = $false
                }
            }
            $mainMatches = $commandLine -match (
                '(?i)(?:^|[\\/"\s])main\.py(?:["\s]|$)'
            )
            if ($mainMatches -and ($pythonMatches -or $rootMatches)) {
                return $true
            }
        }
        return $false
    }
    catch {
        Throw-WorkerError "E_PROCESS_CHECK" (
            "无法确认 ComfyUI 是否已停止，为保护文件已阻止操作。"
        )
    }
}

function Assert-MutationAllowed {
    param([Parameter(Mandatory = $true)][object]$Paths)

    if (Test-ComfyUIRunning $Paths) {
        Throw-WorkerError "E_COMFY_RUNNING" "请先停止 ComfyUI，再执行此操作。"
    }
}

function Invoke-WithMutationLock {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Paths.Lock,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch {
        Throw-WorkerError "E_BUSY" "另一个扩展管理任务正在运行。"
    }
    try {
        return & $ScriptBlock
    }
    finally {
        $stream.Dispose()
    }
}

function ConvertTo-WindowsCommandLineArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        $Value = ""
    }
    if ($Value.IndexOf([char]0) -ge 0 -or
        $Value.Contains("`r") -or $Value.Contains("`n")) {
        Throw-WorkerError "E_INVALID_REQUEST" "外部进程参数包含非法字符。"
    }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    [int]$backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq "\") {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append("\" * (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append("\" * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append("\" * ($backslashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Stop-ProcessTree {
    param([int]$ProcessId)

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = "taskkill.exe"
        $startInfo.Arguments = "/PID $ProcessId /T /F"
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $killer = New-Object System.Diagnostics.Process
        $killer.StartInfo = $startInfo
        [void]$killer.Start()
        [void]$killer.WaitForExit(10000)
        $killer.Dispose()
    }
    catch {
    }
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 600
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (
        $Arguments |
            ForEach-Object { ConvertTo-WindowsCommandLineArgument $_ }
    ) -join " "
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) {
            [void]$startInfo.EnvironmentVariables.Remove([string]$key)
        }
        else {
            $startInfo.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
        }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $process.WaitForExit(500)) {
        if ($stopwatch.Elapsed.TotalSeconds -ge [Math]::Max(1, $TimeoutSeconds)) {
            Stop-ProcessTree $process.Id
            try { $process.Kill() } catch {}
            $process.Dispose()
            Throw-WorkerError "E_PROCESS_TIMEOUT" "外部进程执行超时。"
        }
    }
    $stopwatch.Stop()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Get-PipEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Settings,
        [string]$CacheDirectory = ""
    )

    $environment = @{}
    foreach ($environmentName in @(
        [Environment]::GetEnvironmentVariables().Keys
    )) {
        if ([string]$environmentName -match "^(?i)PIP_") {
            $environment[[string]$environmentName] = $null
        }
    }
    foreach ($environmentName in @(
        "PYTHONPATH",
        "PYTHONHOME",
        "VIRTUAL_ENV"
    )) {
        $environment[$environmentName] = $null
    }
    <#
        The child process inherits the rest of the launcher environment, but
        all pip-routing variables are explicitly removed above. The selected
        index and proxy are supplied only to the concrete subprocess.
    #>
    $requiredEnvironment = @{
        "PIP_CONFIG_FILE" = "NUL"
        "PIP_DISABLE_PIP_VERSION_CHECK" = "1"
        "PIP_NO_INPUT" = "1"
        "PYTHONNOUSERSITE" = "1"
    }
    foreach ($key in $requiredEnvironment.Keys) {
        $environment[$key] = $requiredEnvironment[$key]
    }
    if (-not [string]::IsNullOrWhiteSpace($CacheDirectory)) {
        if (-not [System.IO.Directory]::Exists($CacheDirectory)) {
            [void][System.IO.Directory]::CreateDirectory($CacheDirectory)
        }
        $environment["PIP_CACHE_DIR"] = $CacheDirectory
    }
    $environment["PIP_NO_CACHE_DIR"] = "1"
    switch ([string]$Settings.network.proxy.mode) {
        "none" {
            foreach ($key in @(
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "all_proxy"
            )) {
                $environment[$key] = $null
            }
        }
        "custom" {
            $proxyUri = Get-LauncherProxyUri $Settings
            if ($null -eq $proxyUri -or $proxyUri.Scheme -ne "http" -and
                $proxyUri.Scheme -ne "https") {
                Throw-WorkerError "E_SETTINGS_INVALID" "自定义代理设置无效。"
            }
            foreach ($key in @(
                "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"
            )) {
                $environment[$key] = $proxyUri.AbsoluteUri
            }
        }
    }
    return $environment
}

function Normalize-PythonPackageName {
    param([Parameter(Mandatory = $true)][string]$PackageName)

    return $PackageName.Trim().ToLowerInvariant() -replace "[-_.]+", "-"
}

function Get-SafeRequirementEntries {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        return @()
    }
    $entries = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path, $script:utf8)) {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }
        if ($line.StartsWith("-") -or
            $line -match "(?i)(^|[\s])(-e|--editable|--index|--extra-index)" -or
            $line.Contains("@") -or $line.Contains("://") -or
            $line.Contains("\") -or $line.Contains("/")) {
            Throw-WorkerError "E_DEPENDENCY_CHANGE_BLOCKED" (
                "依赖清单包含自定义源、路径或可编辑安装，已阻止。"
            )
        }
        if ($line -notmatch (
            "^(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)" +
            "(?:\[[A-Za-z0-9_,.-]+\])?" +
            "(?:\s*(?:===|==|~=|!=|<=|>=|<|>)[^;\s,]+" +
            "(?:\s*,\s*(?:===|==|~=|!=|<=|>=|<|>)[^;\s,]+)*)?" +
            "(?:\s*;\s*[A-Za-z0-9_ .<>=!'" + '"' + "()-]+)?$"
        )) {
            Throw-WorkerError "E_DEPENDENCY_CHANGE_BLOCKED" (
                "依赖清单包含无法按规则识别的条目。"
            )
        }
        $normalized = Normalize-PythonPackageName $Matches["name"]
        if (-not $seen.Add($normalized)) {
            Throw-WorkerError "E_DEPENDENCY_CHANGE_BLOCKED" (
                "依赖清单包含重复包：$normalized"
            )
        }
        $entries.Add([pscustomobject]@{
            Name = $normalized
            Line = $line
        })
    }
    return $entries.ToArray()
}

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 600,
        [string]$FailureCode = "E_DEPENDENCY_FAILED",
        [string]$FailureLabel = "Python 命令执行失败",
        [switch]$AllowPipCheckFailure
    )

    if (-not [System.IO.File]::Exists($Paths.Python)) {
        Throw-WorkerError "E_PYTHON_MISSING" "整合包内置 Python 不存在。"
    }
    $result = Invoke-CapturedProcess `
        -FilePath $Paths.Python `
        -Arguments $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -Environment $Environment `
        -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ne 0 -and -not $AllowPipCheckFailure) {
        $reason = ([string]$result.StdErr).Trim()
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = ([string]$result.StdOut).Trim()
        }
        Throw-WorkerError $FailureCode (
            $FailureLabel + "：" +
            (ConvertTo-SafeText -Text $reason -MaximumLength 800)
        )
    }
    return $result
}

function Get-InstalledPythonPackageMap {
    param([Parameter(Mandatory = $true)][object]$Paths)

    # Do not spawn `pip list` here.  On some Windows machines the embedded
    # Python process can be held by security scanning when it is started from
    # the launcher's background runspace.  The process then consumes no CPU
    # until this preflight's 120-second timeout, even though no network access
    # or package mutation is required.  Installed wheel metadata is the source
    # used by importlib/pip itself and can be read deterministically in-process.
    $pythonRoot = [System.IO.Path]::GetDirectoryName($Paths.Python)
    $sitePackages = Join-Path $pythonRoot "Lib\site-packages"
    if (-not [System.IO.Directory]::Exists($sitePackages)) {
        Throw-WorkerError `
            "E_PYTHON_MISSING" `
            "内置 Python 的 site-packages 目录不存在。"
    }
    $map = @{}
    $metadataDirectories = @(
        [System.IO.Directory]::GetDirectories($sitePackages, "*.dist-info")
    ) + @(
        [System.IO.Directory]::GetDirectories($sitePackages, "*.egg-info")
    )
    foreach ($metadataDirectory in $metadataDirectories) {
        $metadataPath = Join-Path $metadataDirectory "METADATA"
        if (-not [System.IO.File]::Exists($metadataPath)) {
            $metadataPath = Join-Path $metadataDirectory "PKG-INFO"
        }
        if (-not [System.IO.File]::Exists($metadataPath)) {
            continue
        }
        $displayName = ""
        $version = ""
        foreach ($line in [System.IO.File]::ReadLines($metadataPath)) {
            if ([string]::IsNullOrWhiteSpace($displayName) -and
                [string]$line -match "^(?i)Name:\s*(?<value>.+?)\s*$") {
                $displayName = [string]$Matches["value"]
            }
            elseif ([string]::IsNullOrWhiteSpace($version) -and
                [string]$line -match "^(?i)Version:\s*(?<value>.+?)\s*$") {
                $version = [string]$Matches["value"]
            }
            if (-not [string]::IsNullOrWhiteSpace($displayName) -and
                -not [string]::IsNullOrWhiteSpace($version)) {
                break
            }
        }
        if ($displayName -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
            [string]::IsNullOrWhiteSpace($version)) {
            continue
        }
        $normalized = Normalize-PythonPackageName $displayName
        $map[$normalized] = [pscustomobject]@{
            Name = $displayName
            Version = $version
        }
    }
    if ($map.Count -eq 0) {
        Throw-WorkerError `
            "E_DEPENDENCY_FAILED" `
            "无法从内置 Python 元数据读取已安装包版本。"
    }
    return $map
}

function Get-PipCheckLines {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][hashtable]$Environment
    )

    $result = Invoke-Python `
        -Paths $Paths `
        -Arguments @("-s", "-m", "pip", "check") `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName($Paths.Python)) `
        -Environment $Environment `
        -TimeoutSeconds 30 `
        -AllowPipCheckFailure
    $combined = (
        ([string]$result.StdOut) + [Environment]::NewLine +
        ([string]$result.StdErr)
    )
    $set = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($line in [System.Text.RegularExpressions.Regex]::Split(
        $combined,
        "\r?\n"
    )) {
        $normalized = ([string]$line).Trim()
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            [void]$set.Add($normalized)
        }
    }
    return $set
}

function Get-KnownPipConflictLines {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $knownPath = Join-Path $Paths.Root "tools\known-pip-conflicts.txt"
    if (-not [System.IO.File]::Exists($knownPath)) {
        return $set
    }
    foreach ($rawLine in [System.IO.File]::ReadAllLines(
        $knownPath,
        $script:utf8
    )) {
        $line = ([string]$rawLine).Trim()
        if (-not [string]::IsNullOrWhiteSpace($line) -and
            -not $line.StartsWith("#")) {
            [void]$set.Add($line)
        }
    }
    return $set
}

function Get-CorePackageSet {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in $script:corePythonPackages) {
        [void]$set.Add((Normalize-PythonPackageName $name))
    }
    $requirementsPath = Join-Path $Paths.Root "requirements.txt"
    if ([System.IO.File]::Exists($requirementsPath)) {
        foreach ($rawLine in [System.IO.File]::ReadAllLines(
            $requirementsPath,
            $script:utf8
        )) {
            if ([string]$rawLine -match
                "^\s*(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)") {
                [void]$set.Add(
                    (Normalize-PythonPackageName $Matches["name"])
                )
            }
        }
    }
    return $set
}

function Test-DependencyReportPolicy {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter(Mandatory = $true)][hashtable]$Installed,
        [Parameter(Mandatory = $true)][object]$CorePackages
    )

    $planned = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' (
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($item in @(Get-ObjectValue $Report "install" @())) {
        $metadata = Get-ObjectValue $item "metadata"
        $displayName = [string](Get-ObjectValue $metadata "name" "")
        $version = [string](Get-ObjectValue $metadata "version" "")
        if ($displayName -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
            $version -notmatch "^[A-Za-z0-9][A-Za-z0-9._+!-]*$") {
            Throw-WorkerError "E_DEPENDENCY_CHANGE_BLOCKED" (
                "pip 依赖报告包含无效包版本。"
            )
        }
        $normalized = Normalize-PythonPackageName $displayName
        if ($CorePackages.Contains($normalized)) {
            Throw-WorkerError "E_DEPENDENCY_CHANGE_BLOCKED" (
                "扩展需要修改核心依赖 $normalized，已阻止。"
            )
        }
        $wasInstalled = $Installed.ContainsKey($normalized)
        $previousVersion = if ($wasInstalled) {
            [string]$Installed[$normalized].Version
        }
        else {
            ""
        }
        $downloadInfo = Get-ObjectValue $item "download_info"
        $downloadUrl = [string](Get-ObjectValue $downloadInfo "url" "")
        $isDirect = [bool](Get-ObjectValue $downloadInfo "is_direct" $false)
        if ($isDirect -or $downloadUrl -notmatch "(?i)\.whl(?:$|[?#])") {
            Throw-WorkerError "E_DEPENDENCY_CHANGE_BLOCKED" (
                "扩展依赖没有可用的 wheel，已阻止源码构建。"
            )
        }
        if (-not $seen.Add($normalized)) {
            continue
        }
        $planned.Add([pscustomobject]@{
            Name = $normalized
            DisplayName = $displayName
            Version = $version
            Pin = $displayName + "==" + $version
            DownloadUrl = $downloadUrl
            WasInstalled = $wasInstalled
            PreviousVersion = $previousVersion
            PreviousPin = if ($wasInstalled) {
                $displayName + "==" + $previousVersion
            }
            else {
                ""
            }
        })
    }
    return $planned.ToArray()
}

function New-DependencyPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$RequirementsPath,
        [Parameter(Mandatory = $true)][object]$Settings,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$RollbackRoot
    )

    $requirements = @(Get-SafeRequirementEntries $RequirementsPath)
    $environment = Get-PipEnvironment `
        -Settings $Settings `
        -CacheDirectory (Join-Path $StageRoot "pip-cache")
    # The portable release is already verified against this exact baseline.
    # Reading it avoids a cold-start `pip check` that can be held by Windows
    # security scanning until the worker's timeout, before installation even
    # begins. A real `pip check` still runs after any dependency mutation and
    # rejects conflicts that are not present in this baseline.
    $baselineConflicts = Get-KnownPipConflictLines -Paths $Paths
    if ($requirements.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0
            Items = @()
            Pins = @()
            WheelDirectory = ""
            RollbackWheelDirectory = ""
            Environment = $environment
            BaselineConflicts = $baselineConflicts
        }
    }
    $indexUrl = Get-LauncherPypiIndexUrl $Settings
    $indexUri = $null
    if (-not [System.Uri]::TryCreate(
        $indexUrl,
        [System.UriKind]::Absolute,
        [ref]$indexUri
    ) -or $indexUri.Scheme -ne "https" -or
        -not [string]::IsNullOrEmpty($indexUri.UserInfo)) {
        Throw-WorkerError "E_SETTINGS_INVALID" "PyPI 软件源必须使用符合要求的 HTTPS 地址。"
    }
    $installed = Get-InstalledPythonPackageMap $Paths
    $reportPath = Join-Path $StageRoot "pip-dry-run-report.json"
    [void](Invoke-Python `
        -Paths $Paths `
        -Arguments @(
            "-s", "-m", "pip", "install",
            "--disable-pip-version-check",
            "--no-input",
            "--prefer-binary",
            "--only-binary", ":all:",
            "--upgrade-strategy", "only-if-needed",
            "--retries", "2",
            "--timeout", "20",
            "--index-url", $indexUrl,
            "--dry-run",
            "--report", $reportPath,
            "-r", $RequirementsPath
        ) `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName($RequirementsPath)) `
        -Environment $environment `
        -TimeoutSeconds 360 `
        -FailureCode "E_DEPENDENCY_CHANGE_BLOCKED" `
        -FailureLabel "依赖规则预检失败")
    $report = Read-JsonFile -Path $reportPath -MaximumBytes 8MB
    $items = @(Test-DependencyReportPolicy `
        -Report $report `
        -Installed $installed `
        -CorePackages (Get-CorePackageSet $Paths))
    if ($items.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0
            Items = @()
            Pins = @()
            WheelDirectory = ""
            RollbackWheelDirectory = ""
            Environment = $environment
            BaselineConflicts = $baselineConflicts
        }
    }
    $wheelDirectory = Join-Path $StageRoot "wheels"
    [void][System.IO.Directory]::CreateDirectory($wheelDirectory)
    $pins = @($items | ForEach-Object { [string]$_.Pin })
    $downloadArguments = @(
        "-s", "-m", "pip", "download",
        "--disable-pip-version-check",
        "--no-input",
        "--only-binary", ":all:",
        "--no-deps",
        "--retries", "2",
        "--timeout", "20",
        "--index-url", $indexUrl,
        "--dest", $wheelDirectory
    ) + $pins
    [void](Invoke-Python `
        -Paths $Paths `
        -Arguments $downloadArguments `
        -WorkingDirectory $StageRoot `
        -Environment $environment `
        -TimeoutSeconds 360 `
        -FailureCode "E_DEPENDENCY_CHANGE_BLOCKED" `
        -FailureLabel "依赖 wheel 下载失败")
    $wheelFiles = @(Get-ChildItem -LiteralPath $wheelDirectory -File -Force)
    if ($wheelFiles.Count -lt $items.Count -or
        @($wheelFiles | Where-Object { $_.Extension -ine ".whl" }).Count -gt 0) {
        Throw-WorkerError "E_DEPENDENCY_CHANGE_BLOCKED" (
            "依赖缓存未能得到完整的 wheel 集合。"
        )
    }
    $wheelManifest = @(
        $wheelFiles |
            Sort-Object Name |
            ForEach-Object {
                [pscustomobject]@{
                    file = $_.Name
                    sha256 = (
                        Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
                    ).Hash.ToLowerInvariant()
                }
            }
    )
    Write-Utf8Atomic `
        -Path (Join-Path $StageRoot "wheel-manifest.json") `
        -Text ($wheelManifest | ConvertTo-Json -Depth 4)
    $replacedItems = @($items | Where-Object { [bool]$_.WasInstalled })
    $rollbackWheelDirectory = ""
    if ($replacedItems.Count -gt 0) {
        $rollbackWheelDirectory = Join-Path $RollbackRoot "dependency-backup"
        [void][System.IO.Directory]::CreateDirectory($rollbackWheelDirectory)
        $rollbackPins = @(
            $replacedItems | ForEach-Object { [string]$_.PreviousPin }
        )
        [void](Invoke-Python `
            -Paths $Paths `
            -Arguments (@(
                "-s", "-m", "pip", "download",
                "--disable-pip-version-check",
                "--no-input",
                "--only-binary", ":all:",
                "--no-deps",
                "--retries", "2",
                "--timeout", "20",
                "--index-url", $indexUrl,
                "--dest", $rollbackWheelDirectory
            ) + $rollbackPins) `
            -WorkingDirectory $RollbackRoot `
            -Environment $environment `
            -TimeoutSeconds 360 `
            -FailureCode "E_DEPENDENCY_CHANGE_BLOCKED" `
            -FailureLabel "无法准备旧依赖回滚包")
        $rollbackWheels = @(
            Get-ChildItem -LiteralPath $rollbackWheelDirectory -File -Force
        )
        if ($rollbackWheels.Count -lt $replacedItems.Count -or
            @($rollbackWheels | Where-Object { $_.Extension -ine ".whl" }).Count -gt 0) {
            Throw-WorkerError "E_DEPENDENCY_CHANGE_BLOCKED" (
                "无法完整备份将被替换的 Python 依赖，已取消安装。"
            )
        }
    }
    return [pscustomobject]@{
        Count = $items.Count
        Items = $items
        Pins = $pins
        WheelDirectory = $wheelDirectory
        RollbackWheelDirectory = $rollbackWheelDirectory
        Environment = $environment
        BaselineConflicts = $baselineConflicts
    }
}

function Install-DependencyPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    if ([int]$Plan.Count -eq 0) {
        return
    }
    $arguments = @(
        "-s", "-m", "pip", "install",
        "--disable-pip-version-check",
        "--no-input",
        "--no-index",
        "--find-links", [string]$Plan.WheelDirectory,
        "--no-deps"
    ) + @($Plan.Pins)
    [void](Invoke-Python `
        -Paths $Paths `
        -Arguments $arguments `
        -WorkingDirectory $StageRoot `
        -Environment $Plan.Environment `
        -TimeoutSeconds 360 `
        -FailureLabel "离线安装扩展依赖失败")
    $installed = Get-InstalledPythonPackageMap $Paths
    foreach ($item in @($Plan.Items)) {
        if (-not $installed.ContainsKey([string]$item.Name) -or
            -not ([string]$installed[[string]$item.Name].Version).Equals(
                [string]$item.Version,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            Throw-WorkerError "E_DEPENDENCY_FAILED" (
                "依赖版本校验失败：" + [string]$item.Name
            )
        }
    }
    $afterConflicts = Get-PipCheckLines `
        -Paths $Paths `
        -Environment $Plan.Environment
    $newConflicts = @(
        $afterConflicts |
            Where-Object { -not $Plan.BaselineConflicts.Contains($_) }
    )
    if ($newConflicts.Count -gt 0) {
        Throw-WorkerError "E_DEPENDENCY_FAILED" (
            "安装扩展后出现新的 Python 依赖冲突：" +
            (ConvertTo-SafeText `
                -Text ([string]($newConflicts -join "；")) `
                -MaximumLength 600)
        )
    }
}

function Undo-DependencyPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [object]$Plan
    )

    if ($null -eq $Plan -or [int]$Plan.Count -eq 0) {
        return
    }
    try {
        $names = @($Plan.Items | ForEach-Object { [string]$_.DisplayName })
        [void](Invoke-Python `
            -Paths $Paths `
            -Arguments (@(
                "-s", "-m", "pip", "uninstall",
                "--disable-pip-version-check",
                "--yes"
            ) + $names) `
            -WorkingDirectory ([System.IO.Path]::GetDirectoryName($Paths.Python)) `
            -Environment $Plan.Environment `
            -TimeoutSeconds 240 `
            -FailureLabel "回退扩展新增依赖失败")
        $restorePins = @(
            $Plan.Items |
                Where-Object { [bool]$_.WasInstalled } |
                ForEach-Object { [string]$_.PreviousPin }
        )
        if ($restorePins.Count -gt 0) {
            if ([string]::IsNullOrWhiteSpace(
                [string]$Plan.RollbackWheelDirectory
            ) -or -not [System.IO.Directory]::Exists(
                [string]$Plan.RollbackWheelDirectory
            )) {
                Throw-WorkerError "E_ROLLBACK_FAILED" (
                    "旧依赖回滚包不存在，无法自动恢复。"
                )
            }
            [void](Invoke-Python `
                -Paths $Paths `
                -Arguments (@(
                    "-s", "-m", "pip", "install",
                    "--disable-pip-version-check",
                    "--no-input",
                    "--no-index",
                    "--find-links", [string]$Plan.RollbackWheelDirectory,
                    "--no-deps"
                ) + $restorePins) `
                -WorkingDirectory ([string]$Plan.RollbackWheelDirectory) `
                -Environment $Plan.Environment `
                -TimeoutSeconds 240 `
                -FailureCode "E_ROLLBACK_FAILED" `
                -FailureLabel "恢复扩展安装前的依赖版本失败")
            $installed = Get-InstalledPythonPackageMap $Paths
            foreach ($item in @($Plan.Items | Where-Object {
                [bool]$_.WasInstalled
            })) {
                if (-not $installed.ContainsKey([string]$item.Name) -or
                    -not ([string]$installed[[string]$item.Name].Version).Equals(
                        [string]$item.PreviousVersion,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    Throw-WorkerError "E_ROLLBACK_FAILED" (
                        "依赖版本未能恢复：" + [string]$item.Name
                    )
                }
            }
        }
    }
    catch {
        Write-WorkerLog (
            "依赖回退警告：" +
            (ConvertTo-SafeText $_.Exception.Message)
        )
        throw
    }
}

function Restore-InterruptedDependencyChanges {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][object]$Transaction
    )

    $changes = @(
        Get-ObjectValue $Transaction.Manifest "dependencyChanges" @()
    )
    if ($changes.Count -eq 0) {
        return
    }
    $names = New-Object System.Collections.Generic.List[string]
    $restorePins = New-Object System.Collections.Generic.List[string]
    foreach ($change in $changes) {
        $name = [string](Get-ObjectValue $change "name" "")
        $displayName = [string](Get-ObjectValue $change "displayName" "")
        $previousVersion = [string](
            Get-ObjectValue $change "previousVersion" ""
        )
        $wasInstalled = [bool](
            Get-ObjectValue $change "wasInstalled" $false
        )
        if ($name -notmatch "^[a-z0-9][a-z0-9-]*$" -or
            $displayName -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]*$" -or
            ($wasInstalled -and
                $previousVersion -notmatch "^[A-Za-z0-9][A-Za-z0-9._+!-]*$")) {
            Throw-RecoveryRequired "中断事务的依赖回滚清单无效。"
        }
        $names.Add($displayName)
        if ($wasInstalled) {
            $restorePins.Add($displayName + "==" + $previousVersion)
        }
    }
    [void](Invoke-Python `
        -Paths $Paths `
        -Arguments (@(
            "-s", "-m", "pip", "uninstall",
            "--disable-pip-version-check",
            "--yes"
        ) + $names.ToArray()) `
        -WorkingDirectory ([System.IO.Path]::GetDirectoryName($Paths.Python)) `
        -TimeoutSeconds 240 `
        -FailureCode "E_ROLLBACK_FAILED" `
        -FailureLabel "清理中断安装的依赖失败")
    if ($restorePins.Count -gt 0) {
        $backupDirectory = Join-Path $Transaction.Root "dependency-backup"
        Assert-RecoveryDirectorySlot `
            -Path $backupDirectory `
            -Parent $Transaction.Root `
            -Label "依赖回滚包目录"
        if (-not [System.IO.Directory]::Exists($backupDirectory) -or
            (Test-ReparsePoint $backupDirectory)) {
            Throw-RecoveryRequired "中断事务缺少旧依赖回滚包。"
        }
        [void](Invoke-Python `
            -Paths $Paths `
            -Arguments (@(
                "-s", "-m", "pip", "install",
                "--disable-pip-version-check",
                "--no-input",
                "--no-index",
                "--find-links", $backupDirectory,
                "--no-deps"
            ) + $restorePins.ToArray()) `
            -WorkingDirectory $backupDirectory `
            -TimeoutSeconds 240 `
            -FailureCode "E_ROLLBACK_FAILED" `
            -FailureLabel "恢复中断安装前的依赖失败")
    }
    Write-WorkerLog (
        "已恢复中断安装前的 Python 依赖：" +
        ([string]($names.ToArray() -join ", "))
    )
}

function Get-ExtensionHealthCheckArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$HealthRoot
    )

    if (-not (Test-SafeDirectoryName $Directory)) {
        Throw-WorkerError "E_HEALTH_CHECK" "扩展健康检查目录名称无效。"
    }
    return @(
        "-s",
        (Join-Path $Paths.Root "main.py"),
        "--quick-test-for-ci",
        "--cpu",
        "--disable-all-custom-nodes",
        "--whitelist-custom-nodes", $Directory,
        "--disable-api-nodes",
        "--disable-auto-launch",
        "--input-directory", (Join-Path $HealthRoot "input"),
        "--output-directory", (Join-Path $HealthRoot "output"),
        "--temp-directory", (Join-Path $HealthRoot "temp"),
        "--user-directory", (Join-Path $HealthRoot "user")
    )
}

function Invoke-ExtensionHealthCheck {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][hashtable]$Environment
    )

    $healthRoot = Join-Path $StageRoot "health"
    foreach ($name in @("input", "output", "temp", "user")) {
        [void][System.IO.Directory]::CreateDirectory(
            (Join-Path $healthRoot $name)
        )
    }
    $healthArguments = @(Get-ExtensionHealthCheckArguments `
        -Paths $Paths `
        -Directory $Directory `
        -HealthRoot $healthRoot)
    if ($script:selfTestMode) {
        return
    }
    $result = Invoke-CapturedProcess `
        -FilePath $Paths.Python `
        -Arguments $healthArguments `
        -WorkingDirectory $Paths.Root `
        -Environment $Environment `
        -TimeoutSeconds 300
    $combined = (
        ([string]$result.StdOut) + [Environment]::NewLine +
        ([string]$result.StdErr)
    )
    if ($result.ExitCode -ne 0 -or
        $combined -match (
            "(?i)traceback \(most recent call last\)|" +
            "modulenotfounderror|importerror|failed to import"
        )) {
        Throw-WorkerError "E_HEALTH_CHECK" (
            "扩展单节点启动检查失败：" +
            (ConvertTo-SafeText -Text $combined -MaximumLength 700)
        )
    }
}

function New-Transaction {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Directory
    )

    $transactionId = [Guid]::NewGuid().ToString("N")
    $transactionRoot = Join-Path $Paths.Transactions $transactionId
    [void][System.IO.Directory]::CreateDirectory($transactionRoot)
    $transaction = [pscustomobject][ordered]@{
        schemaVersion = 1
        id = $transactionId
        operation = $Operation
        directory = $Directory
        phase = "prepared"
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        updatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        sourceUrl = ""
        archiveSha256 = ""
        newPackages = @()
        dependencyChanges = @()
        previousState = ""
        error = ""
    }
    Write-Utf8Atomic `
        -Path (Join-Path $transactionRoot "transaction.json") `
        -Text ($transaction | ConvertTo-Json -Depth 8)
    return [pscustomobject]@{
        Id = $transactionId
        Root = $transactionRoot
        ManifestPath = Join-Path $transactionRoot "transaction.json"
        Manifest = $transaction
    }
}

function Update-Transaction {
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][string]$Phase,
        [string]$ErrorMessage = ""
    )

    $Transaction.Manifest.phase = $Phase
    $Transaction.Manifest.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    $Transaction.Manifest.error = ConvertTo-SafeText $ErrorMessage
    Write-Utf8Atomic `
        -Path $Transaction.ManifestPath `
        -Text ($Transaction.Manifest | ConvertTo-Json -Depth 8)
}

function Complete-TransactionBestEffort {
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][string]$Phase
    )

    try {
        Update-Transaction -Transaction $Transaction -Phase $Phase
    }
    catch {
        # state.json is the durable commit marker.  Once it has been
        # committed, a final transaction-label write must not turn a
        # successful user operation into a reported failure.  The recovery
        # pass will reconcile the non-terminal label on the next action.
        Write-WorkerLog (
            "扩展操作已提交，但事务封口暂未写入；稍后将自动协调：" +
            (ConvertTo-SafeText $_.Exception.Message)
        )
    }
}

function Throw-RecoveryRequired {
    param([Parameter(Mandatory = $true)][string]$Message)

    Throw-WorkerError "E_RECOVERY_REQUIRED" (
        "检测到未完成的扩展事务，但无法安全自动恢复：" + $Message
    )
}

function Assert-RecoveryDirectorySlot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-DirectChildPath -Path $Path -Parent $Parent)) {
        Throw-RecoveryRequired ($Label + "路径不在预期目录内。")
    }
    if ([System.IO.File]::Exists($Path)) {
        Throw-RecoveryRequired ($Label + "路径被同名文件占用。")
    }
    if ([System.IO.Directory]::Exists($Path)) {
        if (Test-ReparsePoint $Path) {
            Throw-RecoveryRequired ($Label + "路径是重解析点。")
        }
        Assert-NoReparseAncestors -Path $Path -StopAt $Parent
    }
}

function Test-InstallRecoveryRecord {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][object]$Transaction
    )

    try {
        $sourceUrl = Normalize-GithubRepositoryUrl (
            [string](Get-ObjectValue $Transaction.Manifest "sourceUrl" "")
        )
        $expectedId = "managed:" + (
            Get-Sha256Text $sourceUrl
        ).Substring(0, 24)
        return (
            ([string](Get-ObjectValue $Record "id" "")).Equals(
                $expectedId,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            ([string](Get-ObjectValue $Record "directory" "")).Equals(
                [string]$Transaction.Manifest.directory,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            ([string](Get-ObjectValue $Record "sourceUrl" "")).Equals(
                $sourceUrl,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string](Get-ObjectValue $Record "catalogId" "") -match
                "^catalog:[a-f0-9]{24}$" -and
            [string](Get-ObjectValue $Record "state" "") -eq "enabled" -and
            [string](Get-ObjectValue $Record "installTransactionId" "") -eq
                [string]$Transaction.Id -and
            [string](
                Get-ObjectValue $Record "backupTransactionId" ""
            ) -eq "" -and
            [string](Get-ObjectValue $Record "previousState" "") -eq ""
        )
    }
    catch {
        return $false
    }
}

function Invoke-InterruptedExtensionTransactionRecovery {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $terminalPhases = @{
        install = @("completed", "rolled-back")
        remove = @("completed", "restored", "rolled-back")
    }
    $allowedPhases = @{
        install = @(
            "prepared",
            "downloading",
            "validating",
            "dependency-preflight",
            "installing-dependencies",
            "activating",
            "health-check",
            "completed",
            "rolled-back"
        )
        remove = @(
            "prepared",
            "moving-to-backup",
            "completed",
            "restoring",
            "restored",
            "rolled-back"
        )
    }
    $transactions = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[object]
    $actions = New-Object System.Collections.Generic.List[object]

    foreach ($directoryInfo in @(
        Get-ChildItem `
            -LiteralPath $Paths.Transactions `
            -Directory `
            -Force `
            -ErrorAction Stop
    )) {
        if ($directoryInfo.Name -notmatch "^[a-f0-9]{32}$" -or
            (Test-ReparsePoint $directoryInfo.FullName) -or
            -not (Test-DirectChildPath `
                -Path $directoryInfo.FullName `
                -Parent $Paths.Transactions)) {
            Throw-RecoveryRequired "事务目录名称或路径无效。"
        }
        Assert-NoReparseAncestors `
            -Path $directoryInfo.FullName `
            -StopAt $Paths.Transactions
        $manifestPath = Join-Path $directoryInfo.FullName "transaction.json"
        if (-not [System.IO.File]::Exists($manifestPath)) {
            Throw-RecoveryRequired (
                "事务 {0} 缺少 transaction.json。" -f $directoryInfo.Name
            )
        }
        try {
            $manifest = Read-JsonFile -Path $manifestPath -MaximumBytes 1MB
        }
        catch {
            Throw-RecoveryRequired (
                "事务 {0} 的清单无法读取。" -f $directoryInfo.Name
            )
        }
        $operation = [string](Get-ObjectValue $manifest "operation" "")
        $phase = [string](Get-ObjectValue $manifest "phase" "")
        $extensionDirectory = [string](
            Get-ObjectValue $manifest "directory" ""
        )
        if ([int](Get-ObjectValue $manifest "schemaVersion" 0) -ne 1 -or
            [string](Get-ObjectValue $manifest "id" "") -ne
                $directoryInfo.Name -or
            $operation -notin @("install", "remove") -or
            -not (Test-SafeDirectoryName $extensionDirectory) -or
            $phase -notin $allowedPhases[$operation]) {
            Throw-RecoveryRequired (
                "事务 {0} 的清单字段或阶段无效。" -f $directoryInfo.Name
            )
        }
        $stageRoot = Join-Path $Paths.Staging $directoryInfo.Name
        Assert-RecoveryDirectorySlot `
            -Path $stageRoot `
            -Parent $Paths.Staging `
            -Label "事务临时目录"
        $transaction = [pscustomobject]@{
            Id = $directoryInfo.Name
            Root = $directoryInfo.FullName
            ManifestPath = $manifestPath
            Manifest = $manifest
            Operation = $operation
            Phase = $phase
            Directory = $extensionDirectory
            StageRoot = $stageRoot
        }
        [void]$transactions.Add($transaction)
        if ($phase -in $terminalPhases[$operation]) {
            if ([System.IO.Directory]::Exists($stageRoot)) {
                [void]$actions.Add([pscustomobject]@{
                    Kind = "cleanup-stage"
                    Transaction = $transaction
                    Source = ""
                    Destination = ""
                    TargetPhase = ""
                    ErrorMessage = ""
                })
            }
        }
        else {
            [void]$pending.Add($transaction)
        }
    }

    $duplicatePending = @(
        $pending |
            Group-Object { ([string]$_.Directory).ToLowerInvariant() } |
            Where-Object Count -gt 1
    )
    if ($duplicatePending.Count -gt 0) {
        Throw-RecoveryRequired "同一个扩展存在多个未完成事务。"
    }
    if ($pending.Count -eq 0) {
        foreach ($action in $actions.ToArray()) {
            try {
                Remove-TreeWithoutFollowingReparse `
                    -Path $action.Transaction.StageRoot `
                    -ApprovedRoot $Paths.Staging
            }
            catch {
                Write-WorkerLog (
                    "事务临时目录清理警告：" +
                    (ConvertTo-SafeText $_.Exception.Message)
                )
            }
        }
        return
    }

    $state = Read-WorkerState $Paths
    $recordsByDirectory = @{}
    foreach ($record in @($state.managed)) {
        $key = ([string]$record.directory).ToLowerInvariant()
        if ($recordsByDirectory.ContainsKey($key)) {
            Throw-RecoveryRequired "扩展状态中存在重复的管理记录。"
        }
        $recordsByDirectory[$key] = $record
    }

    foreach ($transaction in $pending.ToArray()) {
        $key = ([string]$transaction.Directory).ToLowerInvariant()
        $record = if ($recordsByDirectory.ContainsKey($key)) {
            $recordsByDirectory[$key]
        }
        else {
            $null
        }
        $activePath = Join-Path $Paths.CustomNodes $transaction.Directory
        $disabledPath = Join-Path $Paths.Disabled $transaction.Directory
        Assert-RecoveryDirectorySlot `
            -Path $activePath `
            -Parent $Paths.CustomNodes `
            -Label "启用扩展"
        Assert-RecoveryDirectorySlot `
            -Path $disabledPath `
            -Parent $Paths.Disabled `
            -Label "停用扩展"
        $activeExists = [System.IO.Directory]::Exists($activePath)
        $disabledExists = [System.IO.Directory]::Exists($disabledPath)

        if ($transaction.Operation -eq "install") {
            $failedPath = Join-Path $transaction.Root "failed-extension"
            Assert-RecoveryDirectorySlot `
                -Path $failedPath `
                -Parent $transaction.Root `
                -Label "失败扩展隔离目录"
            $failedExists = [System.IO.Directory]::Exists($failedPath)
            if ($transaction.Phase -ne "prepared") {
                $sourceUrl = [string](
                    Get-ObjectValue $transaction.Manifest "sourceUrl" ""
                )
                if (-not (Test-TrustedGithubRepositoryUrl $sourceUrl) -or
                    -not (Normalize-GithubRepositoryUrl $sourceUrl).Equals(
                        $sourceUrl,
                        [System.StringComparison]::OrdinalIgnoreCase
                    )) {
                    Throw-RecoveryRequired (
                        "安装事务 {0} 的来源地址无效。" -f $transaction.Id
                    )
                }
            }
            if ($null -ne $record) {
                if ($transaction.Phase -eq "health-check" -and
                    (Test-InstallRecoveryRecord `
                        -Record $record `
                        -Transaction $transaction) -and
                    $activeExists -and
                    -not $disabledExists -and
                    -not $failedExists) {
                    [void]$actions.Add([pscustomobject]@{
                        Kind = "update-only"
                        Transaction = $transaction
                        Source = ""
                        Destination = ""
                        TargetPhase = "completed"
                        ErrorMessage = ""
                    })
                    continue
                }
                Throw-RecoveryRequired (
                    "安装事务 {0} 与管理记录不一致。" -f $transaction.Id
                )
            }
            if ($transaction.Phase -in @(
                "installing-dependencies",
                "activating",
                "health-check"
            )) {
                Restore-InterruptedDependencyChanges `
                    -Paths $Paths `
                    -Transaction $transaction
            }
            if ($disabledExists -or ($activeExists -and $failedExists)) {
                Throw-RecoveryRequired (
                    "安装事务 {0} 存在冲突目录。" -f $transaction.Id
                )
            }
            if ($activeExists) {
                if ($transaction.Phase -notin @("activating", "health-check")) {
                    Throw-RecoveryRequired (
                        "安装事务 {0} 无法证明启用目录归属。" -f
                            $transaction.Id
                    )
                }
                [void]$actions.Add([pscustomobject]@{
                    Kind = "move-and-update"
                    Transaction = $transaction
                    Source = $activePath
                    Destination = $failedPath
                    TargetPhase = "rolled-back"
                    ErrorMessage = (
                        "启动恢复已隔离未提交的扩展目录；" +
                        "已按事务清单恢复安装前的 Python 依赖。"
                    )
                })
                continue
            }
            if ($failedExists -and
                $transaction.Phase -notin @("activating", "health-check")) {
                Throw-RecoveryRequired (
                    "安装事务 {0} 的隔离目录与阶段不匹配。" -f
                        $transaction.Id
                )
            }
            [void]$actions.Add([pscustomobject]@{
                Kind = "update-only"
                Transaction = $transaction
                Source = ""
                Destination = ""
                TargetPhase = "rolled-back"
                ErrorMessage = (
                    "启动恢复已取消未提交的安装；" +
                    "已按事务清单恢复安装前的 Python 依赖。"
                )
            })
            continue
        }

        $previousState = [string](
            Get-ObjectValue $transaction.Manifest "previousState" ""
        )
        $backupParent = Join-Path $transaction.Root "backup"
        if ([System.IO.File]::Exists($backupParent) -or
            (
                [System.IO.Directory]::Exists($backupParent) -and
                (Test-ReparsePoint $backupParent)
            )) {
            Throw-RecoveryRequired (
                "移除事务 {0} 的备份目录无效。" -f $transaction.Id
            )
        }
        $backupPath = Join-Path $backupParent $transaction.Directory
        Assert-RecoveryDirectorySlot `
            -Path $backupPath `
            -Parent $backupParent `
            -Label "扩展备份"
        $backupExists = [System.IO.Directory]::Exists($backupPath)

        if ($transaction.Phase -eq "prepared") {
            if ($null -eq $record -or
                [string]$record.state -notin @("enabled", "disabled") -or
                -not (Test-ManagedRecordProvenance `
                    -Paths $Paths `
                    -Record $record) -or
                $backupExists -or
                ($activeExists -eq $disabledExists) -or
                (
                    [string]$record.state -eq "enabled" -and
                    -not $activeExists
                ) -or (
                    [string]$record.state -eq "disabled" -and
                    -not $disabledExists
                )) {
                Throw-RecoveryRequired (
                    "移除事务 {0} 的准备阶段状态不一致。" -f
                        $transaction.Id
                )
            }
            [void]$actions.Add([pscustomobject]@{
                Kind = "update-only"
                Transaction = $transaction
                Source = ""
                Destination = ""
                TargetPhase = "rolled-back"
                ErrorMessage = "启动恢复确认移除操作尚未搬动扩展目录。"
            })
            continue
        }

        if ($previousState -notin @("enabled", "disabled") -or
            $null -eq $record -or
            -not (Test-ManagedRecordProvenance `
                -Paths $Paths `
                -Record $record)) {
            Throw-RecoveryRequired (
                "移除事务 {0} 的管理记录或原状态无效。" -f
                    $transaction.Id
            )
        }
        $sourcePath = if ($previousState -eq "disabled") {
            $disabledPath
        }
        else {
            $activePath
        }
        $otherPathExists = if ($previousState -eq "disabled") {
            $activeExists
        }
        else {
            $disabledExists
        }
        $sourceExists = [System.IO.Directory]::Exists($sourcePath)
        if ($otherPathExists) {
            Throw-RecoveryRequired (
                "移除事务 {0} 的扩展出现在错误状态目录。" -f
                    $transaction.Id
            )
        }

        if ($transaction.Phase -eq "moving-to-backup") {
            $recordRemoved = (
                [string]$record.state -eq "removed" -and
                [string]$record.backupTransactionId -eq $transaction.Id -and
                [string]$record.previousState -eq $previousState
            )
            $recordOriginal = (
                [string]$record.state -eq $previousState -and
                [string]$record.backupTransactionId -eq "" -and
                [string]$record.previousState -eq ""
            )
            if ($recordRemoved -and $backupExists -and -not $sourceExists) {
                [void]$actions.Add([pscustomobject]@{
                    Kind = "update-only"
                    Transaction = $transaction
                    Source = ""
                    Destination = ""
                    TargetPhase = "completed"
                    ErrorMessage = ""
                })
                continue
            }
            if ($recordOriginal -and $sourceExists -and -not $backupExists) {
                [void]$actions.Add([pscustomobject]@{
                    Kind = "update-only"
                    Transaction = $transaction
                    Source = ""
                    Destination = ""
                    TargetPhase = "rolled-back"
                    ErrorMessage = "启动恢复确认移除操作尚未搬动扩展目录。"
                })
                continue
            }
            if ($recordOriginal -and $backupExists -and -not $sourceExists) {
                [void]$actions.Add([pscustomobject]@{
                    Kind = "move-and-update"
                    Transaction = $transaction
                    Source = $backupPath
                    Destination = $sourcePath
                    TargetPhase = "rolled-back"
                    ErrorMessage = "启动恢复已撤销未提交的扩展移除。"
                })
                continue
            }
            Throw-RecoveryRequired (
                "移除事务 {0} 的目录与状态提交标记冲突。" -f
                    $transaction.Id
            )
        }

        if ($transaction.Phase -eq "restoring") {
            $recordRemoved = (
                [string]$record.state -eq "removed" -and
                [string]$record.backupTransactionId -eq $transaction.Id -and
                [string]$record.previousState -eq $previousState
            )
            $recordRestored = (
                [string]$record.state -eq $previousState -and
                [string]$record.backupTransactionId -eq "" -and
                [string]$record.previousState -eq ""
            )
            if ($recordRemoved -and $backupExists -and -not $sourceExists) {
                [void]$actions.Add([pscustomobject]@{
                    Kind = "update-only"
                    Transaction = $transaction
                    Source = ""
                    Destination = ""
                    TargetPhase = "completed"
                    ErrorMessage = "启动恢复确认重新安装操作尚未搬动备份。"
                })
                continue
            }
            if ($recordRemoved -and -not $backupExists -and $sourceExists) {
                [void]$actions.Add([pscustomobject]@{
                    Kind = "move-and-update"
                    Transaction = $transaction
                    Source = $sourcePath
                    Destination = $backupPath
                    TargetPhase = "completed"
                    ErrorMessage = "启动恢复已撤销未提交的扩展恢复。"
                })
                continue
            }
            if ($recordRestored -and -not $backupExists -and $sourceExists) {
                [void]$actions.Add([pscustomobject]@{
                    Kind = "update-only"
                    Transaction = $transaction
                    Source = ""
                    Destination = ""
                    TargetPhase = "restored"
                    ErrorMessage = ""
                })
                continue
            }
            Throw-RecoveryRequired (
                "恢复事务 {0} 的目录与状态提交标记冲突。" -f
                    $transaction.Id
            )
        }
    }

    Assert-MutationAllowed $Paths
    foreach ($action in $actions.ToArray()) {
        if ($action.Kind -eq "move-and-update") {
            if ([System.IO.Directory]::Exists($action.Destination) -or
                [System.IO.File]::Exists($action.Destination) -or
                -not [System.IO.Directory]::Exists($action.Source)) {
                Throw-RecoveryRequired (
                    "事务 {0} 的目录在恢复执行前发生变化。" -f
                        $action.Transaction.Id
                )
            }
            [System.IO.Directory]::Move(
                [string]$action.Source,
                [string]$action.Destination
            )
        }
        if ($action.Kind -ne "cleanup-stage") {
            Update-Transaction `
                -Transaction $action.Transaction `
                -Phase ([string]$action.TargetPhase) `
                -ErrorMessage ([string]$action.ErrorMessage)
            Write-WorkerLog (
                "已协调中断的扩展事务：{0} / {1} -> {2}" -f
                $action.Transaction.Id,
                $action.Transaction.Operation,
                $action.TargetPhase
            )
        }
        if ([System.IO.Directory]::Exists(
            [string]$action.Transaction.StageRoot
        )) {
            try {
                Remove-TreeWithoutFollowingReparse `
                    -Path $action.Transaction.StageRoot `
                    -ApprovedRoot $Paths.Staging
            }
            catch {
                Write-WorkerLog (
                    "事务临时目录清理警告：" +
                    (ConvertTo-SafeText $_.Exception.Message)
                )
            }
        }
    }
}

function Invoke-ListInstalled {
    param([Parameter(Mandatory = $true)][object]$Paths)

    $items = @(Get-InstalledItems $Paths)
    return New-WorkerResult `
        -ResultAction "ListInstalled" `
        -Ok $true `
        -Code "OK" `
        -Message ("已读取 {0} 个扩展。" -f $items.Count) `
        -Data ([ordered]@{
            items = $items
            count = $items.Count
            generation = (Read-WorkerState $Paths).generation
        })
}

function Add-CatalogLocalRelation {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Index,
        [string]$Value,
        [Parameter(Mandatory = $true)][object]$Descriptor
    )

    $key = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($key)) {
        return
    }
    if (-not $Index.ContainsKey($key)) {
        $Index[$key] = New-Object System.Collections.Generic.List[object]
    }
    foreach ($existing in $Index[$key]) {
        if ([string]$existing.Key -eq [string]$Descriptor.Key) {
            return
        }
    }
    $Index[$key].Add($Descriptor)
}

function Resolve-CatalogLocalRelation {
    param(
        [Parameter(Mandatory = $true)][hashtable]$SourceIndex,
        [Parameter(Mandatory = $true)][hashtable]$DirectoryIndex,
        [string]$SourceUrl,
        [string]$Directory
    )

    $matches = @{}
    $sourceKey = ([string]$SourceUrl).Trim()
    if (-not [string]::IsNullOrWhiteSpace($sourceKey) -and
        $SourceIndex.ContainsKey($sourceKey)) {
        foreach ($descriptor in $SourceIndex[$sourceKey]) {
            $matches[[string]$descriptor.Key] = $descriptor
        }
    }
    $directoryKey = ([string]$Directory).Trim()
    if (-not [string]::IsNullOrWhiteSpace($directoryKey) -and
        $DirectoryIndex.ContainsKey($directoryKey)) {
        foreach ($descriptor in $DirectoryIndex[$directoryKey]) {
            $matches[[string]$descriptor.Key] = $descriptor
        }
    }

    $localItems = @($matches.Values)
    if ($localItems.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Kind = "available"
            StateText = "可安装"
            CanInstall = $true
            CanReinstall = $false
            ReinstallId = ""
            DescriptorKey = ""
            Descriptor = $null
        }
    }
    if ($localItems.Count -ne 1) {
        return [pscustomobject][ordered]@{
            Kind = "attention"
            StateText = "需要处理"
            CanInstall = $false
            CanReinstall = $false
            ReinstallId = ""
            DescriptorKey = ""
            Descriptor = $null
        }
    }

    $item = $localItems[0]
    if ([bool]$item.Attention) {
        return [pscustomobject][ordered]@{
            Kind = "attention"
            StateText = "需要处理"
            CanInstall = $false
            CanReinstall = $false
            ReinstallId = ""
            DescriptorKey = [string]$item.Key
            Descriptor = $item
        }
    }
    if ([bool]$item.Present) {
        return [pscustomobject][ordered]@{
            Kind = "installed"
            StateText = "已存在"
            CanInstall = $false
            CanReinstall = $false
            ReinstallId = ""
            DescriptorKey = [string]$item.Key
            Descriptor = $item
        }
    }
    if ([bool]$item.CanReinstall -and
        [string]$item.Id -match "^managed:[a-f0-9]{24}$") {
        return [pscustomobject][ordered]@{
            Kind = "reinstall"
            StateText = "可重新安装"
            CanInstall = $false
            CanReinstall = $true
            ReinstallId = [string]$item.Id
            DescriptorKey = [string]$item.Key
            Descriptor = $item
        }
    }
    return [pscustomobject][ordered]@{
        Kind = "attention"
        StateText = "需要处理"
        CanInstall = $false
        CanReinstall = $false
        ReinstallId = ""
        DescriptorKey = [string]$item.Key
        Descriptor = $item
    }
}

function Test-CatalogCandidateMatches {
    param(
        [Parameter(Mandatory = $true)][object]$Candidate,
        [string]$Needle
    )

    if ([string]::IsNullOrWhiteSpace($Needle)) {
        return $true
    }
    foreach ($value in @(
        [string]$Candidate.DisplayName,
        [string]$Candidate.Description,
        [string]$Candidate.SourceUrl,
        [string]$Candidate.Directory,
        [string]$Candidate.LocalSearchText
    )) {
        if ($value.IndexOf(
                $Needle,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0) {
            return $true
        }
    }
    return $false
}

function Invoke-SearchCatalog {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [string]$SearchText
    )

    if ($SearchText.Length -gt 100) {
        Throw-WorkerError "E_INVALID_REQUEST" "搜索文字不能超过 100 个字符。"
    }
    $cache = Read-CatalogCache $Paths
    $state = Read-WorkerState $Paths
    $installed = @(Get-InstalledItems -Paths $Paths -State $state)
    $descriptors = @{}

    foreach ($item in $installed) {
        $itemId = [string](Get-ObjectValue $item "Id" "")
        $itemPath = [string](Get-ObjectValue $item "Path" "")
        $key = if (-not [string]::IsNullOrWhiteSpace($itemId)) {
            "item|" + $itemId.ToLowerInvariant()
        }
        else {
            "path|" + $itemPath.ToLowerInvariant()
        }
        $present = $false
        if ([System.IO.Directory]::Exists($itemPath)) {
            $present = (
                (Test-DirectChildPath -Path $itemPath -Parent $Paths.CustomNodes) -or
                (Test-DirectChildPath -Path $itemPath -Parent $Paths.Disabled)
            )
        }
        $descriptors[$key] = [pscustomobject][ordered]@{
            Key = $key
            Id = $itemId
            CatalogId = ""
            Directory = [string](Get-ObjectValue $item "Directory" "")
            DisplayName = [string](Get-ObjectValue $item "DisplayName" "")
            SourceUrl = [string](Get-ObjectValue $item "SourceUrl" "")
            PhysicalState = [string](Get-ObjectValue $item "State" "attention")
            Present = $present
            CanReinstall = [bool](Get-ObjectValue $item "CanRestore" $false)
            Attention = (
                [string](Get-ObjectValue $item "State" "attention") -eq
                "attention"
            )
        }
    }

    $recordOrdinal = 0
    foreach ($record in @($state.managed)) {
        $recordOrdinal++
        $recordId = [string](Get-ObjectValue $record "id" "")
        $key = if (-not [string]::IsNullOrWhiteSpace($recordId)) {
            "item|" + $recordId.ToLowerInvariant()
        }
        else {
            "record|" + $recordOrdinal
        }
        $recordDirectory = [string](Get-ObjectValue $record "directory" "")
        $recordSource = [string](Get-ObjectValue $record "sourceUrl" "")
        $recordState = [string](Get-ObjectValue $record "state" "")
        if (-not $descriptors.ContainsKey($key)) {
            $descriptors[$key] = [pscustomobject][ordered]@{
                Key = $key
                Id = $recordId
                CatalogId = [string](Get-ObjectValue $record "catalogId" "")
                Directory = $recordDirectory
                DisplayName = [string](
                    Get-ObjectValue $record "displayName" $recordDirectory
                )
                SourceUrl = $recordSource
                PhysicalState = ""
                Present = $false
                CanReinstall = $false
                Attention = $true
            }
        }
        $descriptor = $descriptors[$key]
        if ([string]::IsNullOrWhiteSpace([string]$descriptor.CatalogId)) {
            $descriptor.CatalogId = [string](
                Get-ObjectValue $record "catalogId" ""
            )
        }
        if (-not ([string]$descriptor.Directory).Equals(
                $recordDirectory,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            -not ([string]$descriptor.SourceUrl).Equals(
                $recordSource,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
            $descriptor.Attention = $true
        }
        if ($recordState -eq "removed") {
            if (-not [bool]$descriptor.CanReinstall -or
                [bool]$descriptor.Present) {
                $descriptor.Attention = $true
            }
        }
        elseif ($recordState -in @("enabled", "disabled")) {
            if (-not [bool]$descriptor.Present -or
                [string]$descriptor.PhysicalState -ne $recordState) {
                $descriptor.Attention = $true
            }
        }
        else {
            $descriptor.Attention = $true
        }
    }

    $sourceIndex = @{}
    $directoryIndex = @{}
    foreach ($descriptor in @($descriptors.Values)) {
        Add-CatalogLocalRelation `
            -Index $sourceIndex `
            -Value ([string]$descriptor.SourceUrl) `
            -Descriptor $descriptor
        Add-CatalogLocalRelation `
            -Index $directoryIndex `
            -Value ([string]$descriptor.Directory) `
            -Descriptor $descriptor
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    $representedDescriptors = New-Object `
        'System.Collections.Generic.HashSet[string]' (
            [System.StringComparer]::OrdinalIgnoreCase
        )
    $sequence = 0
    foreach ($catalogItem in @(
        Get-ObjectValue $cache "items" @()
    )) {
        $sequence++
        $relation = Resolve-CatalogLocalRelation `
            -SourceIndex $sourceIndex `
            -DirectoryIndex $directoryIndex `
            -SourceUrl ([string]$catalogItem.SourceUrl) `
            -Directory ([string]$catalogItem.Directory)
        if (-not [string]::IsNullOrWhiteSpace(
            [string]$relation.DescriptorKey
        )) {
            [void]$representedDescriptors.Add(
                [string]$relation.DescriptorKey
            )
        }
        $localSearchText = if ($null -ne $relation.Descriptor) {
            (
                [string]$relation.Descriptor.DisplayName + " " +
                [string]$relation.Descriptor.Directory
            )
        }
        else {
            ""
        }
        $candidates.Add([pscustomobject][ordered]@{
            Id = [string]$catalogItem.Id
            DisplayName = [string]$catalogItem.DisplayName
            Description = [string]$catalogItem.Description
            SourceText = "GitHub"
            StateText = [string]$relation.StateText
            SourceUrl = [string]$catalogItem.SourceUrl
            CanInstall = [bool]$relation.CanInstall
            CanReinstall = [bool]$relation.CanReinstall
            ReinstallId = [string]$relation.ReinstallId
            Directory = [string]$catalogItem.Directory
            LocalSearchText = $localSearchText
            LocalPriority = if ([bool]$relation.CanReinstall) { 0 } else { 1 }
            Sequence = $sequence
        })
    }

    foreach ($descriptor in @(
        $descriptors.Values |
            Sort-Object DisplayName, Directory
    )) {
        if (-not [bool]$descriptor.CanReinstall -or
            [bool]$descriptor.Present -or
            [bool]$descriptor.Attention -or
            $representedDescriptors.Contains([string]$descriptor.Key)) {
            continue
        }
        $relation = Resolve-CatalogLocalRelation `
            -SourceIndex $sourceIndex `
            -DirectoryIndex $directoryIndex `
            -SourceUrl ([string]$descriptor.SourceUrl) `
            -Directory ([string]$descriptor.Directory)
        if (-not [bool]$relation.CanReinstall -or
            [string]$relation.DescriptorKey -ne [string]$descriptor.Key) {
            continue
        }
        $sequence++
        $catalogId = [string]$descriptor.CatalogId
        if ($catalogId -notmatch "^catalog:[a-f0-9]{24}$") {
            $catalogId = "catalog:" + (
                Get-Sha256Text ([string]$descriptor.SourceUrl)
            ).Substring(0, 24)
        }
        $candidates.Add([pscustomobject][ordered]@{
            Id = $catalogId
            DisplayName = [string]$descriptor.DisplayName
            Description = (
                "已从本机移除，保留安全备份，可直接重新安装。"
            )
            SourceText = "本地备份"
            StateText = "可重新安装"
            SourceUrl = [string]$descriptor.SourceUrl
            CanInstall = $false
            CanReinstall = $true
            ReinstallId = [string]$descriptor.Id
            Directory = [string]$descriptor.Directory
            LocalSearchText = (
                [string]$descriptor.DisplayName + " " +
                [string]$descriptor.Directory
            )
            LocalPriority = 0
            Sequence = $sequence
        })
    }

    $needle = ([string]$SearchText).Trim()
    $matched = @(
        $candidates |
            Where-Object {
                Test-CatalogCandidateMatches -Candidate $_ -Needle $needle
            } |
            Sort-Object LocalPriority, Sequence
    )
    $output = @(
        $matched |
            Select-Object -First 500 |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    Id = [string]$_.Id
                    DisplayName = [string]$_.DisplayName
                    Description = [string]$_.Description
                    SourceText = [string]$_.SourceText
                    StateText = [string]$_.StateText
                    SourceUrl = [string]$_.SourceUrl
                    CanInstall = [bool]$_.CanInstall
                    CanReinstall = [bool]$_.CanReinstall
                    ReinstallId = [string]$_.ReinstallId
                    Directory = [string]$_.Directory
                }
            }
    )
    $fetchedAt = [string](Get-ObjectValue $cache "fetchedAtUtc" "")
    $stale = $true
    $parsedFetchedAt = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($fetchedAt, [ref]$parsedFetchedAt)) {
        $stale = (
            [DateTimeOffset]::UtcNow - $parsedFetchedAt
        ).TotalDays -gt 7
    }
    $resultMessage = if ($null -eq $cache -and $matched.Count -eq 0) {
        "本地尚无扩展目录，请先刷新目录。"
    }
    else {
        "找到 {0} 个扩展。" -f $matched.Count
    }
    return New-WorkerResult `
        -ResultAction "SearchCatalog" `
        -Ok $true `
        -Code "OK" `
        -Message $resultMessage `
        -Data ([ordered]@{
            items = $output
            count = $output.Count
            total = $matched.Count
            truncated = $matched.Count -gt 500
            stale = $stale
            fetchedAtUtc = $fetchedAt
        })
}

function Invoke-RefreshCatalog {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [string]$CatalogUrl
    )

    if ([string]::IsNullOrWhiteSpace($CatalogUrl)) {
        $CatalogUrl = $script:defaultCatalogUrl
    }
    if (-not $CatalogUrl.Equals(
        $script:defaultCatalogUrl,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        Throw-WorkerError "E_SOURCE_UNTRUSTED" (
            "只允许刷新启动器内置的公开扩展目录地址。"
        )
    }
    $settings = Get-NetworkSettings $Paths $script:settingsPath
    $downloadUrl = Get-TaskDownloadUrl `
        -OriginalUrl $CatalogUrl `
        -Settings $settings
    $temporary = Join-Path $Paths.Extensions (
        "catalog-download-" + [Guid]::NewGuid().ToString("N") + ".json"
    )
    try {
        Invoke-LimitedHttpDownload `
            -Uri $downloadUrl `
            -DestinationPath $temporary `
            -Settings $settings `
            -MaximumBytes 12MB
        $document = Read-JsonFile -Path $temporary -MaximumBytes 12MB
        $items = @(Convert-CatalogDocument $document)
        $sourceHash = (
            Get-FileHash -LiteralPath $temporary -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        $cache = [ordered]@{
            schemaVersion = 1
            sourceUrl = $CatalogUrl
            sourceSha256 = $sourceHash
            fetchedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
            count = $items.Count
            items = $items
        }
        Write-Utf8Atomic `
            -Path $Paths.Catalog `
            -Text ($cache | ConvertTo-Json -Depth 8)
        return New-WorkerResult `
            -ResultAction "RefreshCatalog" `
            -Ok $true `
            -Code "OK" `
            -Message ("扩展目录已更新，共 {0} 个符合本地规则的条目。" -f $items.Count) `
            -Data ([ordered]@{
                count = $items.Count
                fetchedAtUtc = $cache.fetchedAtUtc
                sourceUrl = $CatalogUrl
            })
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Set-ExtensionEnabledState {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [string]$ItemId,
        [string]$ItemName
    )

    Assert-MutationAllowed $Paths
    if (-not [System.IO.Directory]::Exists($Paths.Disabled)) {
        [void][System.IO.Directory]::CreateDirectory($Paths.Disabled)
    }
    Assert-NoReparseAncestors -Path $Paths.Disabled -StopAt $Paths.Root
    $item = Resolve-InstalledItem $Paths $ItemId $ItemName
    $expectedState = if ($Enabled) { "disabled" } else { "enabled" }
    if ($item.State -ne $expectedState) {
        $stateErrorMessage = if ($Enabled) {
            "此扩展当前不在停用状态。"
        }
        else {
            "此扩展当前不在启用状态。"
        }
        Throw-WorkerError "E_INVALID_STATE" $stateErrorMessage
    }
    $source = [string]$item.Path
    $destinationParent = if ($Enabled) {
        $Paths.CustomNodes
    }
    else {
        $Paths.Disabled
    }
    $destination = Join-Path $destinationParent ([string]$item.Directory)
    $sourceParent = if ($Enabled) {
        $Paths.Disabled
    }
    else {
        $Paths.CustomNodes
    }
    if (-not (Test-DirectChildPath $source $sourceParent) -or
        -not (Test-DirectChildPath $destination $destinationParent)) {
        Throw-WorkerError "E_PATH_UNSAFE" "扩展启停路径无效。"
    }
    Assert-NoReparseAncestors -Path $source -StopAt $Paths.Root
    if ([System.IO.Directory]::Exists($destination) -or
        [System.IO.File]::Exists($destination)) {
        Throw-WorkerError "E_ALREADY_EXISTS" "目标扩展目录已存在。"
    }
    $state = Read-WorkerState $Paths
    $managedMap = Get-ManagedRecordMap $state
    Assert-MutationAllowed $Paths
    [System.IO.Directory]::Move($source, $destination)
    try {
        if ($managedMap.ContainsKey([string]$item.Directory)) {
            $managedMap[[string]$item.Directory].state = if ($Enabled) {
                "enabled"
            }
            else {
                "disabled"
            }
            Save-WorkerState $Paths $state
        }
    }
    catch {
        if ([System.IO.Directory]::Exists($destination) -and
            -not [System.IO.Directory]::Exists($source)) {
            [System.IO.Directory]::Move($destination, $source)
        }
        throw
    }
    $verb = if ($Enabled) { "启用" } else { "停用" }
    Write-WorkerLog ("已{0}扩展：{1}" -f $verb, [string]$item.Directory)
    return New-WorkerResult `
        -ResultAction $(if ($Enabled) { "Enable" } else { "Disable" }) `
        -Ok $true `
        -Code "OK" `
        -Message ("扩展已{0}，将在下次启动 ComfyUI 时生效。" -f $verb) `
        -Data ([ordered]@{
            id = [string]$item.Id
            directory = [string]$item.Directory
            path = $destination
            state = if ($Enabled) { "enabled" } else { "disabled" }
        })
}

function Test-FreeSpace {
    param(
        [Parameter(Mandatory = $true)][string]$WorkerRoot,
        [long]$RequiredBytes = 1GB
    )

    $driveRoot = [System.IO.Path]::GetPathRoot(
        [System.IO.Path]::GetFullPath($WorkerRoot)
    )
    $drive = New-Object System.IO.DriveInfo($driveRoot)
    if ($drive.AvailableFreeSpace -lt $RequiredBytes) {
        Throw-WorkerError "E_DISK_FULL" (
            "磁盘空间不足，至少需要 {0:N0} MB 可用空间。" -f
            ($RequiredBytes / 1MB)
        )
    }
}

function Invoke-InstallExtension {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$CatalogId
    )

    Assert-MutationAllowed $Paths
    Test-FreeSpace $Paths.Root 1GB
    $catalogItem = Resolve-CatalogItem $Paths $CatalogId
    $sourceUrl = Normalize-GithubRepositoryUrl ([string]$catalogItem.SourceUrl)
    $directory = [string]$catalogItem.Directory
    if (-not (Test-SafeDirectoryName $directory)) {
        Throw-WorkerError "E_SOURCE_UNTRUSTED" "扩展目录名称无效。"
    }
    $activePath = Join-Path $Paths.CustomNodes $directory
    $disabledPath = Join-Path $Paths.Disabled $directory
    if ([System.IO.Directory]::Exists($activePath) -or
        [System.IO.Directory]::Exists($disabledPath)) {
        Throw-WorkerError "E_ALREADY_EXISTS" "同名扩展目录已经存在。"
    }
    $state = Read-WorkerState $Paths
    foreach ($record in @($state.managed)) {
        if (([string]$record.sourceUrl).Equals(
            $sourceUrl,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            if ([string]$record.state -eq "removed") {
                Throw-WorkerError "E_RECOVERABLE" (
                    "此扩展保留有本地安全备份，请在安装页选择【重新安装】。"
                )
            }
            Throw-WorkerError "E_ALREADY_EXISTS" "此扩展已经由启动器安装。"
        }
    }
    $settings = Get-NetworkSettings $Paths $script:settingsPath
    $transaction = New-Transaction $Paths "install" $directory
    $transaction.Manifest.sourceUrl = $sourceUrl
    Update-Transaction $transaction "downloading"
    $stageRoot = Join-Path $Paths.Staging $transaction.Id
    [void][System.IO.Directory]::CreateDirectory($stageRoot)
    $archivePath = Join-Path $stageRoot "source.zip"
    $extractRoot = Join-Path $stageRoot "extract"
    $dependencyPlan = $null
    $activated = $false
    $stateAdded = $false
    try {
        $archiveUrl = $sourceUrl.TrimEnd("/") + "/archive/HEAD.zip"
        $downloadUrl = Get-TaskDownloadUrl `
            -OriginalUrl $archiveUrl `
            -Settings $settings
        Update-Transaction $transaction "downloading"
        Invoke-LimitedHttpDownload `
            -Uri $downloadUrl `
            -DestinationPath $archivePath `
            -Settings $settings `
            -MaximumBytes 256MB
        $archiveLength = (Get-Item -LiteralPath $archivePath).Length
        Test-FreeSpace `
            -WorkerRoot $Paths.Root `
            -RequiredBytes ([Math]::Max(1GB, ($archiveLength * 8) + 512MB))
        $transaction.Manifest.archiveSha256 = (
            Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        Update-Transaction $transaction "validating"
        Expand-ValidatedExtensionZip `
            -ArchivePath $archivePath `
            -DestinationPath $extractRoot
        $sourceRoot = Get-ValidatedExtensionSourceRoot $extractRoot
        $requirementsPath = Join-Path $sourceRoot "requirements.txt"
        Update-Transaction $transaction "dependency-preflight"
        $dependencyPlan = New-DependencyPlan `
            -Paths $Paths `
            -RequirementsPath $requirementsPath `
            -Settings $settings `
            -StageRoot (Join-Path $stageRoot "dependencies") `
            -RollbackRoot $transaction.Root
        $transaction.Manifest.newPackages = @(
            $dependencyPlan.Items |
                ForEach-Object { [string]$_.Pin }
        )
        $transaction.Manifest.dependencyChanges = @(
            $dependencyPlan.Items |
                ForEach-Object {
                    [pscustomobject][ordered]@{
                        name = [string]$_.Name
                        displayName = [string]$_.DisplayName
                        newVersion = [string]$_.Version
                        wasInstalled = [bool]$_.WasInstalled
                        previousVersion = [string]$_.PreviousVersion
                    }
                }
        )
        Update-Transaction $transaction "installing-dependencies"
        Assert-MutationAllowed $Paths
        Install-DependencyPlan `
            -Paths $Paths `
            -Plan $dependencyPlan `
            -StageRoot $stageRoot
        Update-Transaction $transaction "activating"
        Assert-MutationAllowed $Paths
        [System.IO.Directory]::Move($sourceRoot, $activePath)
        $activated = $true
        Update-Transaction $transaction "health-check"
        Invoke-ExtensionHealthCheck `
            -Paths $Paths `
            -Directory $directory `
            -StageRoot $stageRoot `
            -Environment $dependencyPlan.Environment
        $managedId = "managed:" + (
            Get-Sha256Text $sourceUrl
        ).Substring(0, 24)
        $record = [pscustomobject][ordered]@{
            id = $managedId
            directory = $directory
            displayName = [string]$catalogItem.DisplayName
            sourceUrl = $sourceUrl
            catalogId = [string]$catalogItem.Id
            state = "enabled"
            versionText = "GitHub HEAD"
            installedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
            installTransactionId = $transaction.Id
            backupTransactionId = ""
            previousState = ""
            dependencies = @(
                $dependencyPlan.Items |
                    ForEach-Object { [string]$_.Pin }
            )
        }
        $state.managed = @($state.managed) + @($record)
        Save-WorkerState $Paths $state
        $stateAdded = $true
        Complete-TransactionBestEffort $transaction "completed"
        Write-WorkerLog (
            "扩展安装完成：{0}；来源：{1}；新增依赖：{2}" -f
            $directory,
            $sourceUrl,
            [int]$dependencyPlan.Count
        )
        return New-WorkerResult `
            -ResultAction "Install" `
            -Ok $true `
            -Code "OK" `
            -Message "扩展已通过本地规则检查并安装完成。" `
            -Data ([ordered]@{
                id = $managedId
                directory = $directory
                path = $activePath
                sourceUrl = $sourceUrl
                dependenciesAdded = [int]$dependencyPlan.Count
                archiveSha256 = $transaction.Manifest.archiveSha256
            }) `
            -TransactionId $transaction.Id
    }
    catch {
        $failure = $_
        if ($stateAdded) {
            try {
                $rollbackState = Read-WorkerState $Paths
                $rollbackState.managed = @(
                    $rollbackState.managed |
                        Where-Object {
                            -not ([string]$_.directory).Equals(
                                $directory,
                                [System.StringComparison]::OrdinalIgnoreCase
                            )
                        }
                )
                Save-WorkerState $Paths $rollbackState
            }
            catch {
                Write-WorkerLog "安装失败后的状态清理未完全成功。"
            }
        }
        if ($activated -and [System.IO.Directory]::Exists($activePath)) {
            try {
                $failedPath = Join-Path $transaction.Root "failed-extension"
                if (-not [System.IO.Directory]::Exists($failedPath)) {
                    [System.IO.Directory]::Move($activePath, $failedPath)
                }
            }
            catch {
                Write-WorkerLog "安装失败后的扩展目录隔离未完全成功。"
            }
        }
        $rollbackFailure = $null
        try {
            Undo-DependencyPlan $Paths $dependencyPlan
        }
        catch {
            $rollbackFailure = $_
            Write-WorkerLog (
                "依赖自动回滚失败：" +
                (ConvertTo-SafeText $_.Exception.Message)
            )
        }
        try {
            Update-Transaction `
                -Transaction $transaction `
                -Phase "rolled-back" `
                -ErrorMessage $(if ($null -ne $rollbackFailure) {
                    $failure.Exception.Message +
                    "；自动回滚失败：" +
                    $rollbackFailure.Exception.Message
                }
                else {
                    $failure.Exception.Message
                })
        }
        catch {
        }
        if ($null -ne $rollbackFailure) {
            Throw-WorkerError "E_ROLLBACK_FAILED" (
                "插件安装失败，且依赖未能自动恢复；请停止使用并联系整合包作者：" +
                (ConvertTo-SafeText $rollbackFailure.Exception.Message)
            )
        }
        throw $failure
    }
    finally {
        if ([System.IO.Directory]::Exists($stageRoot)) {
            try {
                Remove-TreeWithoutFollowingReparse `
                    -Path $stageRoot `
                    -ApprovedRoot $Paths.Staging
            }
            catch {
                Write-WorkerLog "扩展安装临时目录清理失败。"
            }
        }
    }
}

function Invoke-RemoveExtension {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [string]$ItemId,
        [string]$ItemName
    )

    Assert-MutationAllowed $Paths
    $item = Resolve-InstalledItem $Paths $ItemId $ItemName
    if (-not [bool]$item.CanRemove -or $item.Origin -ne "launcher") {
        Throw-WorkerError "E_PROTECTED_EXTENSION" (
            "只能移除由此启动器安装的扩展；发布版和外部扩展均受保护。"
        )
    }
    $source = [string]$item.Path
    $expectedParent = if ($item.State -eq "enabled") {
        $Paths.CustomNodes
    }
    else {
        $Paths.Disabled
    }
    if (-not (Test-DirectChildPath $source $expectedParent) -or
        (Test-ReparsePoint $source)) {
        Throw-WorkerError "E_PATH_UNSAFE" "扩展目录路径无效。"
    }
    $transaction = New-Transaction $Paths "remove" ([string]$item.Directory)
    $transaction.Manifest.previousState = [string]$item.State
    $backupParent = Join-Path $transaction.Root "backup"
    [void][System.IO.Directory]::CreateDirectory($backupParent)
    $backupPath = Join-Path $backupParent ([string]$item.Directory)
    Update-Transaction $transaction "moving-to-backup"
    Assert-MutationAllowed $Paths
    [System.IO.Directory]::Move($source, $backupPath)
    try {
        $state = Read-WorkerState $Paths
        $found = $false
        foreach ($record in @($state.managed)) {
            if (([string]$record.id).Equals(
                [string]$item.Id,
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                $record.state = "removed"
                $record.previousState = [string]$item.State
                $record.backupTransactionId = $transaction.Id
                $found = $true
                break
            }
        }
        if (-not $found) {
            Throw-WorkerError "E_STATE_INVALID" "找不到扩展管理记录。"
        }
        Save-WorkerState $Paths $state
    }
    catch {
        if ([System.IO.Directory]::Exists($backupPath) -and
            -not [System.IO.Directory]::Exists($source)) {
            [System.IO.Directory]::Move($backupPath, $source)
        }
        throw
    }
    Complete-TransactionBestEffort $transaction "completed"
    Write-WorkerLog ("扩展已移入本地安全备份：" + [string]$item.Directory)
    return New-WorkerResult `
        -ResultAction "Remove" `
        -Ok $true `
        -Code "OK" `
        -Message "扩展已移除，并保留本地安全备份；Python 依赖未删除。" `
        -Data ([ordered]@{
            id = [string]$item.Id
            directory = [string]$item.Directory
            dependenciesRetained = $true
        }) `
        -RollbackAvailable $true `
        -TransactionId $transaction.Id
}

function Invoke-RestoreExtension {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [string]$ItemId,
        [string]$ItemName
    )

    Assert-MutationAllowed $Paths
    $state = Read-WorkerState $Paths
    $matches = @(
        $state.managed |
            Where-Object {
                [string]$_.state -eq "removed" -and (
                    (
                        -not [string]::IsNullOrWhiteSpace($ItemId) -and
                        (
                            ([string]$_.id).Equals(
                                $ItemId,
                                [System.StringComparison]::OrdinalIgnoreCase
                            ) -or
                            ([string]$_.backupTransactionId).Equals(
                                $ItemId,
                                [System.StringComparison]::OrdinalIgnoreCase
                            )
                        )
                    ) -or (
                        -not [string]::IsNullOrWhiteSpace($ItemName) -and
                        (
                            ([string]$_.directory).Equals(
                                $ItemName,
                                [System.StringComparison]::OrdinalIgnoreCase
                            ) -or
                            ([string]$_.displayName).Equals(
                                $ItemName,
                                [System.StringComparison]::OrdinalIgnoreCase
                            )
                        )
                    )
                )
            }
    )
    if ($matches.Count -ne 1) {
        Throw-WorkerError "E_ROLLBACK_UNAVAILABLE" "没有找到唯一可用的扩展安全备份。"
    }
    $record = $matches[0]
    if (-not (Test-ManagedRecordProvenance `
        -Paths $Paths `
        -Record $record)) {
        Throw-WorkerError "E_TAMPERED_BACKUP" (
            "扩展管理记录无法验证，已阻止恢复。"
        )
    }
    $transactionId = [string]$record.backupTransactionId
    if ($transactionId -notmatch "^[a-f0-9]{32}$") {
        Throw-WorkerError "E_TAMPERED_BACKUP" "扩展备份标识无效。"
    }
    $transactionRoot = Join-Path $Paths.Transactions $transactionId
    if (-not (Test-DirectChildPath `
            -Path $transactionRoot `
            -Parent $Paths.Transactions) -or
        -not [System.IO.Directory]::Exists($transactionRoot) -or
        [System.IO.File]::Exists($transactionRoot) -or
        (Test-ReparsePoint $transactionRoot)) {
        Throw-WorkerError "E_TAMPERED_BACKUP" "扩展备份事务目录无效。"
    }
    Assert-NoReparseAncestors `
        -Path $transactionRoot `
        -StopAt $Paths.Transactions
    $manifestPath = Join-Path $transactionRoot "transaction.json"
    if (-not (Test-DirectChildPath `
            -Path $manifestPath `
            -Parent $transactionRoot) -or
        -not [System.IO.File]::Exists($manifestPath) -or
        (Test-ReparsePoint $manifestPath)) {
        Throw-WorkerError "E_TAMPERED_BACKUP" "扩展备份清单路径无效。"
    }
    $manifest = Read-JsonFile -Path $manifestPath -MaximumBytes 1MB
    $previousState = [string]$record.previousState
    if ($previousState -notin @("enabled", "disabled") -or
        [int](Get-ObjectValue $manifest "schemaVersion" 0) -ne 1 -or
        [string](Get-ObjectValue $manifest "id" "") -ne $transactionId -or
        [string](Get-ObjectValue $manifest "operation" "") -ne "remove" -or
        [string](Get-ObjectValue $manifest "phase" "") -ne "completed" -or
        [string](Get-ObjectValue $manifest "previousState" "") -ne
            $previousState -or
        -not ([string](Get-ObjectValue $manifest "directory" "")).Equals(
            [string]$record.directory,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        Throw-WorkerError "E_TAMPERED_BACKUP" "扩展备份清单不匹配。"
    }
    $backupPath = Join-Path $transactionRoot (
        "backup\" + [string]$record.directory
    )
    $backupParent = Join-Path $transactionRoot "backup"
    if (-not (Test-DirectChildPath `
            -Path $backupParent `
            -Parent $transactionRoot) -or
        -not [System.IO.Directory]::Exists($backupParent) -or
        [System.IO.File]::Exists($backupParent) -or
        (Test-ReparsePoint $backupParent) -or
        -not (Test-DirectChildPath `
            -Path $backupPath `
            -Parent $backupParent)) {
        Throw-WorkerError "E_TAMPERED_BACKUP" "扩展备份父目录无效。"
    }
    if (-not [System.IO.Directory]::Exists($backupPath) -or
        (Test-ReparsePoint $backupPath)) {
        Throw-WorkerError "E_TAMPERED_BACKUP" "扩展备份不存在或已被修改。"
    }
    Assert-NoReparseAncestors `
        -Path $backupPath `
        -StopAt $Paths.Transactions
    $destinationParent = if ($previousState -eq "disabled") {
        if (-not [System.IO.Directory]::Exists($Paths.Disabled)) {
            [void][System.IO.Directory]::CreateDirectory($Paths.Disabled)
        }
        $Paths.Disabled
    }
    else {
        $Paths.CustomNodes
    }
    $destination = Join-Path $destinationParent ([string]$record.directory)
    if ([System.IO.Directory]::Exists($destination) -or
        [System.IO.File]::Exists($destination)) {
        Throw-WorkerError "E_ALREADY_EXISTS" "恢复目标目录已存在。"
    }
    $manifest.phase = "restoring"
    $manifest.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    $manifest.error = ""
    Write-Utf8Atomic `
        -Path $manifestPath `
        -Text ($manifest | ConvertTo-Json -Depth 8)
    Assert-MutationAllowed $Paths
    [System.IO.Directory]::Move($backupPath, $destination)
    try {
        $record.state = if ($previousState -eq "disabled") {
            "disabled"
        }
        else {
            "enabled"
        }
        $record.previousState = ""
        $record.backupTransactionId = ""
        Save-WorkerState $Paths $state
    }
    catch {
        if ([System.IO.Directory]::Exists($destination) -and
            -not [System.IO.Directory]::Exists($backupPath)) {
            [System.IO.Directory]::Move($destination, $backupPath)
        }
        throw
    }
    $restoreTransaction = [pscustomobject]@{
        Id = $transactionId
        Root = $transactionRoot
        ManifestPath = $manifestPath
        Manifest = $manifest
    }
    Complete-TransactionBestEffort $restoreTransaction "restored"
    Write-WorkerLog ("扩展已从备份恢复：" + [string]$record.directory)
    return New-WorkerResult `
        -ResultAction "Restore" `
        -Ok $true `
        -Code "OK" `
        -Message "扩展已从本地备份重新安装，将在下次启动 ComfyUI 时生效。" `
        -Data ([ordered]@{
            id = [string]$record.id
            directory = [string]$record.directory
            path = $destination
            state = [string]$record.state
        }) `
        -TransactionId $transactionId
}

function New-TestZip {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Entries
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::ReadWrite
    )
    $archive = New-Object System.IO.Compression.ZipArchive(
        $stream,
        [System.IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    try {
        foreach ($entryName in $Entries.Keys) {
            $entry = $archive.CreateEntry([string]$entryName)
            $entryStream = $entry.Open()
            $writer = New-Object System.IO.StreamWriter(
                $entryStream,
                $script:utf8
            )
            try {
                $writer.Write([string]$Entries[$entryName])
            }
            finally {
                $writer.Dispose()
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

function Assert-SelfTest {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Get-SelfTestTransaction {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )

    $transactionRoot = Join-Path $Paths.Transactions $TransactionId
    $manifestPath = Join-Path $transactionRoot "transaction.json"
    return [pscustomobject]@{
        Id = $TransactionId
        Root = $transactionRoot
        ManifestPath = $manifestPath
        Manifest = Read-JsonFile -Path $manifestPath -MaximumBytes 1MB
    }
}

function New-SelfTestManagedExtension {
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][string]$Directory,
        [ValidateSet("enabled", "disabled")]
        [string]$StateName = "enabled"
    )

    $sourceUrl = (
        "https://github.com/example/" +
        $Directory.ToLowerInvariant()
    )
    $installTransaction = New-Transaction `
        -Paths $Paths `
        -Operation "install" `
        -Directory $Directory
    $installTransaction.Manifest.sourceUrl = $sourceUrl
    Update-Transaction $installTransaction "completed"
    $parent = if ($StateName -eq "disabled") {
        if (-not [System.IO.Directory]::Exists($Paths.Disabled)) {
            [void][System.IO.Directory]::CreateDirectory($Paths.Disabled)
        }
        $Paths.Disabled
    }
    else {
        $Paths.CustomNodes
    }
    $extensionPath = Join-Path $parent $Directory
    [void][System.IO.Directory]::CreateDirectory($extensionPath)
    [System.IO.File]::WriteAllText(
        (Join-Path $extensionPath "__init__.py"),
        "NODE_CLASS_MAPPINGS = {}",
        $script:utf8
    )
    $recordId = "managed:" + (
        Get-Sha256Text $sourceUrl
    ).Substring(0, 24)
    $record = [pscustomobject][ordered]@{
        id = $recordId
        directory = $Directory
        displayName = $Directory
        sourceUrl = $sourceUrl
        catalogId = "catalog:" + (
            Get-Sha256Text ("catalog-" + $Directory)
        ).Substring(0, 24)
        state = $StateName
        versionText = "GitHub HEAD"
        installedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        installTransactionId = $installTransaction.Id
        backupTransactionId = ""
        previousState = ""
        dependencies = @()
    }
    $state = Read-WorkerState $Paths
    $state.managed = @($state.managed) + @($record)
    Save-WorkerState $Paths $state
    return [pscustomobject]@{
        Id = $recordId
        Directory = $Directory
        Path = $extensionPath
        Record = $record
        InstallTransaction = $installTransaction
    }
}

function Invoke-WorkerSelfTest {
    $script:selfTestMode = $true
    $tempParent = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    ).TrimEnd("\")
    $testRoot = Join-Path $tempParent (
        "ComfyUI-Extension-Worker-Test-" + [Guid]::NewGuid().ToString("N")
    )
    try {
        [void][System.IO.Directory]::CreateDirectory($testRoot)
        [void][System.IO.Directory]::CreateDirectory(
            (Join-Path $testRoot "custom_nodes")
        )
        [void][System.IO.Directory]::CreateDirectory(
            (Join-Path $testRoot "tools")
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $testRoot "main.py"),
            "# self-test",
            $script:utf8
        )
        $paths = Initialize-WorkerRoot $testRoot
        foreach ($name in @("BuiltIn-A", "External-A")) {
            [void][System.IO.Directory]::CreateDirectory(
                (Join-Path $paths.CustomNodes $name)
            )
        }
        $bundledManifest = [ordered]@{
            schemaVersion = 1
            policy = "protected-release-baseline"
            count = 1
            nodes = @([ordered]@{
                directory = "BuiltIn-A"
                relativePath = "custom_nodes\BuiltIn-A"
                initialState = "enabled"
            })
        }
        Write-Utf8Atomic `
            -Path $paths.BundledManifest `
            -Text ($bundledManifest | ConvertTo-Json -Depth 5)

        $initial = @(Get-InstalledItems $paths)
        Assert-SelfTest ($initial.Count -eq 2) "ListInstalled 基线数量测试失败。"
        $builtIn = @($initial | Where-Object Directory -eq "BuiltIn-A")[0]
        Assert-SelfTest (
            $builtIn.Origin -eq "bundled" -and
            -not $builtIn.CanRemove -and
            $builtIn.CanOpenFolder
        ) "发布版扩展保护测试失败。"
        $simulatedManagedBuiltIn = New-InstalledItem `
            -Directory "BuiltIn-A" `
            -StateName "enabled" `
            -Path (Join-Path $paths.CustomNodes "BuiltIn-A") `
            -ManagedRecord ([pscustomobject]@{
                id = "managed:000000000000000000000000"
                displayName = "BuiltIn A"
                sourceUrl = "https://github.com/example/built-in-a"
                versionText = "GitHub HEAD"
            }) `
            -Bundled $true `
            -ManagedVerified $true
        Assert-SelfTest (
            $simulatedManagedBuiltIn.Origin -eq "bundled" -and
            -not $simulatedManagedBuiltIn.CanRemove
        ) "发布版扩展不能被管理记录解除保护。"
        $external = @($initial | Where-Object Directory -eq "External-A")[0]
        Assert-SelfTest (
            $external.Origin -eq "external" -and
            -not $external.CanRemove -and
            $external.CanOpenFolder
        ) "外部扩展保护测试失败。"

        Write-Utf8Atomic `
            -Path $paths.BundledManifest `
            -Text '{"schemaVersion":99,"policy":"invalid","count":0,"nodes":[]}'
        $fallbackProtection = Get-BundledNodeSet $paths
        Assert-SelfTest (
            $fallbackProtection.Contains("BuiltIn-A") -and
            $fallbackProtection.Contains("External-A")
        ) "保护清单损坏时的保守保护测试失败。"
        Write-Utf8Atomic `
            -Path $paths.BundledManifest `
            -Text ($bundledManifest | ConvertTo-Json -Depth 5)

        $disableResult = Set-ExtensionEnabledState `
            -Paths $paths `
            -Enabled $false `
            -ItemId $builtIn.Id `
            -ItemName ""
        Assert-SelfTest (
            $disableResult.ok -and
            [System.IO.Directory]::Exists(
                (Join-Path $paths.Disabled "BuiltIn-A")
            )
        ) "扩展停用测试失败。"
        $enableResult = Set-ExtensionEnabledState `
            -Paths $paths `
            -Enabled $true `
            -ItemId $builtIn.Id `
            -ItemName ""
        Assert-SelfTest (
            $enableResult.ok -and
            [System.IO.Directory]::Exists(
                (Join-Path $paths.CustomNodes "BuiltIn-A")
            )
        ) "扩展启用测试失败。"

        $catalogDocument = [pscustomobject]@{
            custom_nodes = @(
                [pscustomobject]@{
                    title = "Safe Node"
                    author = "Example"
                    reference = "https://github.com/example/safe-node"
                    files = @("https://github.com/example/safe-node")
                    install_type = "git-clone"
                    description = "<b>Safe</b> [node](https://example.invalid)"
                },
                [pscustomobject]@{
                    title = "Unsafe HTTP"
                    files = @("http://github.com/example/unsafe")
                    install_type = "git-clone"
                },
                [pscustomobject]@{
                    title = "Copy Node"
                    files = @(
                        "https://raw.githubusercontent.com/example/x/main/x.py"
                    )
                    install_type = "copy"
                },
                [pscustomobject]@{
                    title = "***"
                    files = @(
                        "https://github.com/example/punctuation-node"
                    )
                    install_type = "git-clone"
                }
            )
        }
        $catalogItems = @(Convert-CatalogDocument $catalogDocument)
        $safeItems = @(
            $catalogItems |
                Where-Object { $_.Directory -eq "safe-node" }
        )
        $punctuationItems = @(
            $catalogItems |
                Where-Object { $_.Directory -eq "punctuation-node" }
        )
        Assert-SelfTest (
            $catalogItems.Count -eq 2 -and
            $safeItems.Count -eq 1 -and
            $safeItems[0].Description -eq "Safe node" -and
            $punctuationItems.Count -eq 1 -and
            $punctuationItems[0].DisplayName -eq "punctuation-node"
        ) "目录过滤与纯文本测试失败。"
        $cache = [ordered]@{
            schemaVersion = 1
            sourceUrl = $script:defaultCatalogUrl
            fetchedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
            count = $catalogItems.Count
            items = $catalogItems
        }
        Write-Utf8Atomic `
            -Path $paths.Catalog `
            -Text ($cache | ConvertTo-Json -Depth 8)
        $search = Invoke-SearchCatalog $paths "safe"
        Assert-SelfTest (
            $search.ok -and $search.data.count -eq 1 -and
            $search.data.items[0].CanInstall -and
            -not $search.data.items[0].CanReinstall -and
            [string]::IsNullOrWhiteSpace(
                [string]$search.data.items[0].ReinstallId
            )
        ) "目录搜索测试失败。"

        $ambiguousSourceIndex = @{}
        $ambiguousDirectoryIndex = @{}
        foreach ($number in @(1, 2)) {
            $ambiguousDescriptor = [pscustomobject]@{
                Key = "ambiguous|" + $number
                Id = "managed:" + ([string]$number).PadLeft(24, "0")
                Present = $false
                CanReinstall = $true
                Attention = $false
            }
            Add-CatalogLocalRelation `
                -Index $ambiguousSourceIndex `
                -Value "https://github.com/example/ambiguous" `
                -Descriptor $ambiguousDescriptor
            Add-CatalogLocalRelation `
                -Index $ambiguousDirectoryIndex `
                -Value "Ambiguous" `
                -Descriptor $ambiguousDescriptor
        }
        $ambiguousCatalogRelation = Resolve-CatalogLocalRelation `
            -SourceIndex $ambiguousSourceIndex `
            -DirectoryIndex $ambiguousDirectoryIndex `
            -SourceUrl "https://github.com/example/ambiguous" `
            -Directory "Ambiguous"
        Assert-SelfTest (
            $ambiguousCatalogRelation.Kind -eq "attention" -and
            $ambiguousCatalogRelation.StateText -eq "需要处理" -and
            -not $ambiguousCatalogRelation.CanInstall -and
            -not $ambiguousCatalogRelation.CanReinstall
        ) "目录歧义 fail-closed 测试失败。"

        $safeZip = Join-Path $testRoot "safe.zip"
        New-TestZip $safeZip @{
            "safe-node-main/__init__.py" = "NODE_CLASS_MAPPINGS = {}"
            "safe-node-main/requirements.txt" = "# none"
        }
        $safeExtract = Join-Path $testRoot "safe-extract"
        Expand-ValidatedExtensionZip $safeZip $safeExtract
        $safeSource = Get-ValidatedExtensionSourceRoot $safeExtract
        Assert-SelfTest (
            [System.IO.File]::Exists((Join-Path $safeSource "__init__.py"))
        ) "安全归档解压测试失败。"

        $unsafeZip = Join-Path $testRoot "unsafe.zip"
        New-TestZip $unsafeZip @{
            "../escape.txt" = "escape"
            "node/__init__.py" = "NODE_CLASS_MAPPINGS = {}"
        }
        $traversalBlocked = $false
        try {
            Expand-ValidatedExtensionZip `
                $unsafeZip `
                (Join-Path $testRoot "unsafe-extract")
        }
        catch {
            $traversalBlocked = (
                [string]$_.Exception.Data["WorkerCode"] -eq "E_ARCHIVE_UNSAFE"
            )
        }
        Assert-SelfTest $traversalBlocked "Zip 路径穿越拦截测试失败。"

        $scriptZip = Join-Path $testRoot "script.zip"
        New-TestZip $scriptZip @{
            "script-node/__init__.py" = "NODE_CLASS_MAPPINGS = {}"
            "script-node/install.py" = "print('unsafe')"
        }
        $scriptExtract = Join-Path $testRoot "script-extract"
        Expand-ValidatedExtensionZip $scriptZip $scriptExtract
        $scriptBlocked = $false
        try {
            [void](Get-ValidatedExtensionSourceRoot $scriptExtract)
        }
        catch {
            $scriptBlocked = (
                [string]$_.Exception.Data["WorkerCode"] -eq "E_SCRIPT_REQUIRED"
            )
        }
        Assert-SelfTest $scriptBlocked "install.py 拦截测试失败。"

        $allowedReport = [pscustomobject]@{
            install = @([pscustomobject]@{
                metadata = [pscustomobject]@{
                    name = "new-safe-wheel"
                    version = "1.0.0"
                }
                download_info = [pscustomobject]@{
                    url = "https://files.example/new_safe_wheel-1.0.0.whl"
                    is_direct = $false
                }
            })
        }
        $emptyInstalled = @{}
        $coreSet = New-Object 'System.Collections.Generic.HashSet[string]' (
            [System.StringComparer]::OrdinalIgnoreCase
        )
        [void]$coreSet.Add("torch")
        $allowedPlan = @(Test-DependencyReportPolicy `
            $allowedReport `
            $emptyInstalled `
            $coreSet)
        Assert-SelfTest ($allowedPlan.Count -eq 1) "新增 wheel 放行测试失败。"

        $existingPlan = @(Test-DependencyReportPolicy `
            $allowedReport `
            @{ "new-safe-wheel" = [pscustomobject]@{ Version = "0.9" } } `
            $coreSet)
        Assert-SelfTest (
            $existingPlan.Count -eq 1 -and
            [bool]$existingPlan[0].WasInstalled -and
            [string]$existingPlan[0].PreviousVersion -eq "0.9"
        ) "普通依赖可回滚升级计划测试失败。"

        $coreReport = [pscustomobject]@{
            install = @([pscustomobject]@{
                metadata = [pscustomobject]@{
                    name = "torch"
                    version = "99.0.0"
                }
                download_info = [pscustomobject]@{
                    url = "https://files.example/torch-99.0.0.whl"
                    is_direct = $false
                }
            })
        }
        $coreBlocked = $false
        try {
            [void](Test-DependencyReportPolicy `
                $coreReport `
                @{ "torch" = [pscustomobject]@{ Version = "2.12.0" } } `
                $coreSet)
        }
        catch {
            $coreBlocked = (
                [string]$_.Exception.Data["WorkerCode"] -eq
                "E_DEPENDENCY_CHANGE_BLOCKED"
            )
        }
        Assert-SelfTest $coreBlocked "核心依赖变更拦截测试失败。"

        $unsafeRequirements = Join-Path $testRoot "unsafe-requirements.txt"
        [System.IO.File]::WriteAllText(
            $unsafeRequirements,
            "package @ https://example.invalid/package.whl",
            $script:utf8
        )
        $requirementBlocked = $false
        try {
            [void](Get-SafeRequirementEntries $unsafeRequirements)
        }
        catch {
            $requirementBlocked = (
                [string]$_.Exception.Data["WorkerCode"] -eq
                "E_DEPENDENCY_CHANGE_BLOCKED"
            )
        }
        Assert-SelfTest $requirementBlocked "直接 URL 依赖拦截测试失败。"

        $managedDirectory = "Managed-A"
        $managedPath = Join-Path $paths.CustomNodes $managedDirectory
        [void][System.IO.Directory]::CreateDirectory($managedPath)
        [System.IO.File]::WriteAllText(
            (Join-Path $managedPath "__init__.py"),
            "NODE_CLASS_MAPPINGS = {}",
            $script:utf8
        )
        $managedId = "managed:" + (
            Get-Sha256Text "https://github.com/example/managed-a"
        ).Substring(0, 24)
        $installTransaction = New-Transaction `
            -Paths $paths `
            -Operation "install" `
            -Directory $managedDirectory
        $installTransaction.Manifest.sourceUrl = (
            "https://github.com/example/managed-a"
        )
        Update-Transaction `
            -Transaction $installTransaction `
            -Phase "completed"
        $managedRecord = [pscustomobject][ordered]@{
            id = $managedId
            directory = $managedDirectory
            displayName = "Managed A"
            sourceUrl = "https://github.com/example/managed-a"
            catalogId = "catalog:000000000000000000000000"
            state = "enabled"
            versionText = "GitHub HEAD"
            installedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
            installTransactionId = $installTransaction.Id
            backupTransactionId = ""
            previousState = ""
            dependencies = @()
        }
        $managedState = [pscustomobject]@{
            schemaVersion = 1
            generation = 0
            managed = @($managedRecord)
        }
        Save-WorkerState $paths $managedState
        $managedCatalogItem = [pscustomobject][ordered]@{
            Id = [string]$managedRecord.catalogId
            DisplayName = "Managed A Catalog"
            Description = "Managed catalog entry"
            SourceUrl = [string]$managedRecord.sourceUrl
            Directory = $managedDirectory
        }
        $managedCache = [ordered]@{
            schemaVersion = 1
            sourceUrl = $script:defaultCatalogUrl
            fetchedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
            count = 2
            items = @($catalogItems) + @($managedCatalogItem)
        }
        Write-Utf8Atomic `
            -Path $paths.Catalog `
            -Text ($managedCache | ConvertTo-Json -Depth 8)
        $catalogInstalled = Invoke-SearchCatalog $paths "managed"
        Assert-SelfTest (
            $catalogInstalled.ok -and
            $catalogInstalled.data.count -eq 1 -and
            $catalogInstalled.data.items[0].StateText -eq "已存在" -and
            -not $catalogInstalled.data.items[0].CanInstall -and
            -not $catalogInstalled.data.items[0].CanReinstall -and
            [string]::IsNullOrWhiteSpace(
                [string]$catalogInstalled.data.items[0].ReinstallId
            )
        ) "已安装扩展目录状态测试失败。"

        $remove = Invoke-RemoveExtension $paths $managedId ""
        Assert-SelfTest (
            $remove.ok -and $remove.rollbackAvailable -and
            -not [System.IO.Directory]::Exists($managedPath)
        ) "安全移除测试失败。"
        $catalogReinstall = Invoke-SearchCatalog $paths "managed"
        Assert-SelfTest (
            $catalogReinstall.ok -and
            $catalogReinstall.data.count -eq 1 -and
            $catalogReinstall.data.items[0].StateText -eq "可重新安装" -and
            -not $catalogReinstall.data.items[0].CanInstall -and
            $catalogReinstall.data.items[0].CanReinstall -and
            [string]$catalogReinstall.data.items[0].ReinstallId -eq
                $managedId
        ) "已移除扩展重新安装状态测试失败。"
        $restore = Invoke-RestoreExtension `
            -Paths $paths `
            -ItemId ([string]$catalogReinstall.data.items[0].ReinstallId) `
            -ItemName ""
        Assert-SelfTest (
            $restore.ok -and
            $restore.message -match "重新安装" -and
            [System.IO.Directory]::Exists($managedPath)
        ) "备份重新安装测试失败。"
        $catalogReinstalled = Invoke-SearchCatalog $paths "managed"
        Assert-SelfTest (
            $catalogReinstalled.data.count -eq 1 -and
            $catalogReinstalled.data.items[0].StateText -eq "已存在" -and
            -not $catalogReinstalled.data.items[0].CanInstall -and
            -not $catalogReinstalled.data.items[0].CanReinstall
        ) "重新安装后目录状态测试失败。"

        [void](Invoke-RemoveExtension $paths $managedId "")
        Write-Utf8Atomic `
            -Path $paths.Catalog `
            -Text ($cache | ConvertTo-Json -Depth 8)
        $localBackupSearch = Invoke-SearchCatalog $paths "Managed-A"
        Assert-SelfTest (
            $localBackupSearch.ok -and
            $localBackupSearch.data.count -eq 1 -and
            $localBackupSearch.data.items[0].SourceText -eq "本地备份" -and
            $localBackupSearch.data.items[0].StateText -eq "可重新安装" -and
            -not $localBackupSearch.data.items[0].CanInstall -and
            $localBackupSearch.data.items[0].CanReinstall -and
            [string]$localBackupSearch.data.items[0].ReinstallId -eq
                $managedId
        ) "远端缺项时本地备份合成测试失败。"

        [System.IO.File]::Delete($paths.Catalog)
        $noCacheBackupSearch = Invoke-SearchCatalog $paths "Managed-A"
        Assert-SelfTest (
            $noCacheBackupSearch.ok -and
            $noCacheBackupSearch.data.count -eq 1 -and
            $noCacheBackupSearch.data.items[0].SourceText -eq "本地备份" -and
            $noCacheBackupSearch.data.items[0].CanReinstall -and
            [string]$noCacheBackupSearch.data.items[0].ReinstallId -eq
                $managedId
        ) "无目录缓存时本地备份合成测试失败。"
        Write-Utf8Atomic `
            -Path $paths.Catalog `
            -Text ($managedCache | ConvertTo-Json -Depth 8)

        $removedState = Read-WorkerState $paths
        $removedRecord = @(
            $removedState.managed |
                Where-Object id -eq $managedId
        )[0]
        $removeTransaction = Get-SelfTestTransaction `
            -Paths $paths `
            -TransactionId ([string]$removedRecord.backupTransactionId)
        $retainedBackup = Join-Path $paths.Transactions (
            [string]$removedRecord.backupTransactionId +
            "\backup\" +
            $managedDirectory
        )
        $removeTransaction.Manifest.previousState = "invalid"
        Update-Transaction $removeTransaction "completed"
        $catalogTampered = Invoke-SearchCatalog $paths "managed"
        Assert-SelfTest (
            $catalogTampered.ok -and
            $catalogTampered.data.count -eq 1 -and
            $catalogTampered.data.items[0].StateText -eq "需要处理" -and
            -not $catalogTampered.data.items[0].CanInstall -and
            -not $catalogTampered.data.items[0].CanReinstall -and
            [string]::IsNullOrWhiteSpace(
                [string]$catalogTampered.data.items[0].ReinstallId
            )
        ) "损坏备份目录状态 fail-closed 测试失败。"
        $restoreManifestBlocked = $false
        try {
            [void](Invoke-RestoreExtension $paths $managedId "")
        }
        catch {
            $restoreManifestBlocked = (
                [string]$_.Exception.Data["WorkerCode"] -eq
                "E_TAMPERED_BACKUP"
            )
        }
        $removeTransaction.Manifest.previousState = "enabled"
        Update-Transaction $removeTransaction "completed"

        $backupParent = [System.IO.Path]::GetDirectoryName($retainedBackup)
        $junctionTarget = Join-Path $testRoot "restore-junction-target"
        [System.IO.Directory]::Move($backupParent, $junctionTarget)
        [void](New-Item `
            -ItemType Junction `
            -Path $backupParent `
            -Target $junctionTarget `
            -Force)
        $restoreJunctionBlocked = $false
        try {
            [void](Invoke-RestoreExtension $paths $managedId "")
        }
        catch {
            $restoreJunctionBlocked = (
                [string]$_.Exception.Data["WorkerCode"] -eq
                "E_TAMPERED_BACKUP"
            )
        }
        finally {
            if ([System.IO.Directory]::Exists($backupParent) -and
                (Test-ReparsePoint $backupParent)) {
                [System.IO.Directory]::Delete($backupParent, $false)
            }
            if ([System.IO.Directory]::Exists($junctionTarget) -and
                -not [System.IO.Directory]::Exists($backupParent)) {
                [System.IO.Directory]::Move($junctionTarget, $backupParent)
            }
        }

        Update-Transaction `
            -Transaction $installTransaction `
            -Phase "tampered"
        $restoreProvenanceBlocked = $false
        try {
            [void](Invoke-RestoreExtension $paths $managedId "")
        }
        catch {
            $restoreProvenanceBlocked = (
                [string]$_.Exception.Data["WorkerCode"] -eq
                "E_TAMPERED_BACKUP"
            )
        }
        Assert-SelfTest (
            $restoreManifestBlocked -and
            $restoreJunctionBlocked -and
            $restoreProvenanceBlocked -and
            [System.IO.Directory]::Exists($retainedBackup)
        ) "恢复清单、路径与来源校验测试失败。"

        $recoveryRoot = Join-Path $testRoot "transaction-recovery"
        [void][System.IO.Directory]::CreateDirectory(
            (Join-Path $recoveryRoot "custom_nodes")
        )
        [void][System.IO.Directory]::CreateDirectory(
            (Join-Path $recoveryRoot "tools")
        )
        [System.IO.File]::WriteAllText(
            (Join-Path $recoveryRoot "main.py"),
            "# recovery self-test",
            $script:utf8
        )
        $recoveryPaths = Initialize-WorkerRoot $recoveryRoot
        Write-Utf8Atomic `
            -Path $recoveryPaths.BundledManifest `
            -Text (
                [ordered]@{
                    schemaVersion = 1
                    policy = "protected-release-baseline"
                    count = 0
                    nodes = @()
                } | ConvertTo-Json -Depth 4
            )

        $installPre = New-Transaction `
            -Paths $recoveryPaths `
            -Operation "install" `
            -Directory "Recover-Install-Pre"
        $installPre.Manifest.sourceUrl = (
            "https://github.com/example/recover-install-pre"
        )
        $installPre.Manifest.newPackages = @("recovery-wheel==1.0.0")
        Update-Transaction $installPre "installing-dependencies"
        $installPreStage = Join-Path $recoveryPaths.Staging $installPre.Id
        [void][System.IO.Directory]::CreateDirectory($installPreStage)
        [System.IO.File]::WriteAllText(
            (Join-Path $installPreStage "sentinel.txt"),
            "stage",
            $script:utf8
        )
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $installPreAfter = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $installPre.Id
        Assert-SelfTest (
            [string]$installPreAfter.Manifest.phase -eq "rolled-back" -and
            -not [System.IO.Directory]::Exists($installPreStage) -and
            -not [System.IO.Directory]::Exists(
                (Join-Path $recoveryPaths.CustomNodes "Recover-Install-Pre")
            ) -and
            [string]$installPreAfter.Manifest.error -match
                "恢复安装前的 Python 依赖"
        ) "安装激活前中断恢复测试失败。"

        $installPost = New-Transaction `
            -Paths $recoveryPaths `
            -Operation "install" `
            -Directory "Recover-Install-Post"
        $installPost.Manifest.sourceUrl = (
            "https://github.com/example/recover-install-post"
        )
        Update-Transaction $installPost "health-check"
        $installPostPath = Join-Path (
            $recoveryPaths.CustomNodes
        ) "Recover-Install-Post"
        [void][System.IO.Directory]::CreateDirectory($installPostPath)
        [System.IO.File]::WriteAllText(
            (Join-Path $installPostPath "__init__.py"),
            "NODE_CLASS_MAPPINGS = {}",
            $script:utf8
        )
        $installPostStage = Join-Path $recoveryPaths.Staging $installPost.Id
        [void][System.IO.Directory]::CreateDirectory($installPostStage)
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $installPostAfter = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $installPost.Id
        $installFailedPath = Join-Path (
            $installPost.Root
        ) "failed-extension"
        Assert-SelfTest (
            [string]$installPostAfter.Manifest.phase -eq "rolled-back" -and
            -not [System.IO.Directory]::Exists($installPostPath) -and
            [System.IO.Directory]::Exists($installFailedPath) -and
            -not [System.IO.Directory]::Exists($installPostStage)
        ) "安装激活后但状态提交前的隔离恢复测试失败。"
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        Assert-SelfTest (
            [System.IO.Directory]::Exists($installFailedPath)
        ) "安装中断恢复幂等测试失败。"

        $installCommit = New-Transaction `
            -Paths $recoveryPaths `
            -Operation "install" `
            -Directory "Recover-Install-Commit"
        $installCommitSource = (
            "https://github.com/example/recover-install-commit"
        )
        $installCommit.Manifest.sourceUrl = $installCommitSource
        Update-Transaction $installCommit "health-check"
        $installCommitPath = Join-Path (
            $recoveryPaths.CustomNodes
        ) "Recover-Install-Commit"
        [void][System.IO.Directory]::CreateDirectory($installCommitPath)
        [System.IO.File]::WriteAllText(
            (Join-Path $installCommitPath "__init__.py"),
            "NODE_CLASS_MAPPINGS = {}",
            $script:utf8
        )
        $installCommitRecord = [pscustomobject][ordered]@{
            id = "managed:" + (
                Get-Sha256Text $installCommitSource
            ).Substring(0, 24)
            directory = "Recover-Install-Commit"
            displayName = "Recover Install Commit"
            sourceUrl = $installCommitSource
            catalogId = "catalog:111111111111111111111111"
            state = "enabled"
            versionText = "GitHub HEAD"
            installedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
            installTransactionId = $installCommit.Id
            backupTransactionId = ""
            previousState = ""
            dependencies = @()
        }
        $installCommitState = Read-WorkerState $recoveryPaths
        $installCommitState.managed = @(
            $installCommitState.managed
        ) + @($installCommitRecord)
        Save-WorkerState $recoveryPaths $installCommitState
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $installCommitAfter = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $installCommit.Id
        Assert-SelfTest (
            [string]$installCommitAfter.Manifest.phase -eq "completed" -and
            [System.IO.Directory]::Exists($installCommitPath) -and
            (Test-ManagedRecordProvenance `
                -Paths $recoveryPaths `
                -Record $installCommitRecord)
        ) "安装状态已提交但事务未封口的恢复测试失败。"

        $removeBefore = New-SelfTestManagedExtension `
            -Paths $recoveryPaths `
            -Directory "Recover-Remove-Before"
        $removeBeforeTransaction = New-Transaction `
            -Paths $recoveryPaths `
            -Operation "remove" `
            -Directory $removeBefore.Directory
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $removeBeforeAfter = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $removeBeforeTransaction.Id
        Assert-SelfTest (
            [string]$removeBeforeAfter.Manifest.phase -eq "rolled-back" -and
            [System.IO.Directory]::Exists($removeBefore.Path)
        ) "移除搬动前中断恢复测试失败。"

        $removeAfter = New-SelfTestManagedExtension `
            -Paths $recoveryPaths `
            -Directory "Recover-Remove-After"
        $removeAfterTransaction = New-Transaction `
            -Paths $recoveryPaths `
            -Operation "remove" `
            -Directory $removeAfter.Directory
        $removeAfterTransaction.Manifest.previousState = "enabled"
        Update-Transaction $removeAfterTransaction "moving-to-backup"
        $removeAfterBackup = Join-Path (
            Join-Path $removeAfterTransaction.Root "backup"
        ) $removeAfter.Directory
        [void][System.IO.Directory]::CreateDirectory(
            [System.IO.Path]::GetDirectoryName($removeAfterBackup)
        )
        [System.IO.Directory]::Move($removeAfter.Path, $removeAfterBackup)
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $removeAfterResult = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $removeAfterTransaction.Id
        Assert-SelfTest (
            [string]$removeAfterResult.Manifest.phase -eq "rolled-back" -and
            [System.IO.Directory]::Exists($removeAfter.Path) -and
            -not [System.IO.Directory]::Exists($removeAfterBackup)
        ) "移除搬动后但状态提交前的回滚测试失败。"

        $removeCommitted = New-SelfTestManagedExtension `
            -Paths $recoveryPaths `
            -Directory "Recover-Remove-Committed"
        $removeCommittedTransaction = New-Transaction `
            -Paths $recoveryPaths `
            -Operation "remove" `
            -Directory $removeCommitted.Directory
        $removeCommittedTransaction.Manifest.previousState = "enabled"
        Update-Transaction $removeCommittedTransaction "moving-to-backup"
        $removeCommittedBackup = Join-Path (
            Join-Path $removeCommittedTransaction.Root "backup"
        ) $removeCommitted.Directory
        [void][System.IO.Directory]::CreateDirectory(
            [System.IO.Path]::GetDirectoryName($removeCommittedBackup)
        )
        [System.IO.Directory]::Move(
            $removeCommitted.Path,
            $removeCommittedBackup
        )
        $removeCommittedState = Read-WorkerState $recoveryPaths
        $removeCommittedRecord = @(
            $removeCommittedState.managed |
                Where-Object id -eq $removeCommitted.Id
        )[0]
        $removeCommittedRecord.state = "removed"
        $removeCommittedRecord.previousState = "enabled"
        $removeCommittedRecord.backupTransactionId = (
            $removeCommittedTransaction.Id
        )
        Save-WorkerState $recoveryPaths $removeCommittedState
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $removeCommittedAfter = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $removeCommittedTransaction.Id
        Assert-SelfTest (
            [string]$removeCommittedAfter.Manifest.phase -eq "completed" -and
            [System.IO.Directory]::Exists($removeCommittedBackup)
        ) "移除状态已提交但事务未封口的恢复测试失败。"

        $restoreBefore = New-SelfTestManagedExtension `
            -Paths $recoveryPaths `
            -Directory "Recover-Restore-Before"
        $restoreBeforeResult = Invoke-RemoveExtension `
            -Paths $recoveryPaths `
            -ItemId $restoreBefore.Id `
            -ItemName ""
        $restoreBeforeTransaction = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId ([string]$restoreBeforeResult.transactionId)
        Update-Transaction $restoreBeforeTransaction "restoring"
        $restoreBeforeBackup = Join-Path (
            Join-Path $restoreBeforeTransaction.Root "backup"
        ) $restoreBefore.Directory
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $restoreBeforeAfter = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $restoreBeforeTransaction.Id
        Assert-SelfTest (
            [string]$restoreBeforeAfter.Manifest.phase -eq "completed" -and
            [System.IO.Directory]::Exists($restoreBeforeBackup) -and
            -not [System.IO.Directory]::Exists($restoreBefore.Path)
        ) "恢复标记已写入但尚未搬动备份的协调测试失败。"

        $restoreAfter = New-SelfTestManagedExtension `
            -Paths $recoveryPaths `
            -Directory "Recover-Restore-After"
        $restoreAfterResult = Invoke-RemoveExtension `
            -Paths $recoveryPaths `
            -ItemId $restoreAfter.Id `
            -ItemName ""
        $restoreAfterTransaction = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId ([string]$restoreAfterResult.transactionId)
        Update-Transaction $restoreAfterTransaction "restoring"
        $restoreAfterBackup = Join-Path (
            Join-Path $restoreAfterTransaction.Root "backup"
        ) $restoreAfter.Directory
        [System.IO.Directory]::Move(
            $restoreAfterBackup,
            $restoreAfter.Path
        )
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $restoreAfterFinal = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $restoreAfterTransaction.Id
        Assert-SelfTest (
            [string]$restoreAfterFinal.Manifest.phase -eq "completed" -and
            [System.IO.Directory]::Exists($restoreAfterBackup) -and
            -not [System.IO.Directory]::Exists($restoreAfter.Path)
        ) "恢复搬动后但状态提交前的回滚测试失败。"

        $restoreCommitted = New-SelfTestManagedExtension `
            -Paths $recoveryPaths `
            -Directory "Recover-Restore-Committed"
        $restoreCommittedResult = Invoke-RemoveExtension `
            -Paths $recoveryPaths `
            -ItemId $restoreCommitted.Id `
            -ItemName ""
        $restoreCommittedTransaction = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId ([string]$restoreCommittedResult.transactionId)
        Update-Transaction $restoreCommittedTransaction "restoring"
        $restoreCommittedBackup = Join-Path (
            Join-Path $restoreCommittedTransaction.Root "backup"
        ) $restoreCommitted.Directory
        [System.IO.Directory]::Move(
            $restoreCommittedBackup,
            $restoreCommitted.Path
        )
        $restoreCommittedState = Read-WorkerState $recoveryPaths
        $restoreCommittedRecord = @(
            $restoreCommittedState.managed |
                Where-Object id -eq $restoreCommitted.Id
        )[0]
        $restoreCommittedRecord.state = "enabled"
        $restoreCommittedRecord.previousState = ""
        $restoreCommittedRecord.backupTransactionId = ""
        Save-WorkerState $recoveryPaths $restoreCommittedState
        Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        $restoreCommittedAfter = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $restoreCommittedTransaction.Id
        Assert-SelfTest (
            [string]$restoreCommittedAfter.Manifest.phase -eq "restored" -and
            [System.IO.Directory]::Exists($restoreCommitted.Path) -and
            -not [System.IO.Directory]::Exists($restoreCommittedBackup)
        ) "恢复状态已提交但事务未封口的协调测试失败。"

        $ambiguous = New-SelfTestManagedExtension `
            -Paths $recoveryPaths `
            -Directory "Recover-Ambiguous"
        $ambiguousTransaction = New-Transaction `
            -Paths $recoveryPaths `
            -Operation "remove" `
            -Directory $ambiguous.Directory
        $ambiguousTransaction.Manifest.previousState = "enabled"
        Update-Transaction $ambiguousTransaction "moving-to-backup"
        $ambiguousBackup = Join-Path (
            Join-Path $ambiguousTransaction.Root "backup"
        ) $ambiguous.Directory
        [void][System.IO.Directory]::CreateDirectory($ambiguousBackup)
        [System.IO.File]::WriteAllText(
            (Join-Path $ambiguousBackup "__init__.py"),
            "NODE_CLASS_MAPPINGS = {}",
            $script:utf8
        )
        $ambiguityBlocked = $false
        try {
            Invoke-InterruptedExtensionTransactionRecovery $recoveryPaths
        }
        catch {
            $ambiguityBlocked = (
                [string]$_.Exception.Data["WorkerCode"] -eq
                    "E_RECOVERY_REQUIRED"
            )
        }
        $ambiguousAfter = Get-SelfTestTransaction `
            -Paths $recoveryPaths `
            -TransactionId $ambiguousTransaction.Id
        Assert-SelfTest (
            $ambiguityBlocked -and
            [string]$ambiguousAfter.Manifest.phase -eq "moving-to-backup" -and
            [System.IO.Directory]::Exists($ambiguous.Path) -and
            [System.IO.Directory]::Exists($ambiguousBackup)
        ) "事务歧义 fail-closed 测试失败。"

        $quoted = ConvertTo-WindowsCommandLineArgument 'C:\path with space\'
        Assert-SelfTest (
            $quoted.StartsWith('"') -and $quoted.EndsWith('"') -and
            $quoted.EndsWith('\\"')
        ) "Windows 参数转义测试失败。"

        $healthArguments = @(Get-ExtensionHealthCheckArguments `
            -Paths $paths `
            -Directory "Managed-A" `
            -HealthRoot (Join-Path $testRoot "isolated-health"))
        $whitelistIndex = [Array]::IndexOf(
            [object[]]$healthArguments,
            "--whitelist-custom-nodes"
        )
        Assert-SelfTest (
            $healthArguments -contains "--disable-all-custom-nodes" -and
            $whitelistIndex -ge 0 -and
            $healthArguments[$whitelistIndex + 1] -eq "Managed-A" -and
            $healthArguments -notcontains "--base-directory" -and
            $healthArguments -contains "--input-directory" -and
            $healthArguments -contains "--output-directory" -and
            $healthArguments -contains "--temp-directory" -and
            $healthArguments -contains "--user-directory"
        ) "单扩展健康检查隔离参数测试失败。"

        return New-WorkerResult `
            -ResultAction "SelfTest" `
            -Ok $true `
            -Code "OK" `
            -Message "扩展 Worker 纯本地自测全部通过。" `
            -Data ([ordered]@{
                result = "OK"
                listProtection = "Verified"
                manifestFailSafe = "Verified"
                enableDisable = "Verified"
                catalogFiltering = "Verified"
                catalogSearch = "Verified"
                catalogReinstall = "Verified"
                catalogLocalBackupSynthesis = "Verified"
                catalogAmbiguityGuard = "Verified"
                archiveTraversalGuard = "Verified"
                scriptGuard = "Verified"
                dependencyPolicy = "Verified"
                removeRestore = "Verified"
                restoreProvenanceGuard = "Verified"
                interruptedInstallRecovery = "Verified"
                interruptedRemoveRecovery = "Verified"
                interruptedRestoreRecovery = "Verified"
                recoveryAmbiguityGuard = "Verified"
                recoveryIdempotency = "Verified"
                openFolderGuard = "Verified"
                argumentQuoting = "Verified"
                healthCheckIsolation = "Verified"
                networkUsed = $false
                pythonEnvironmentModified = $false
            })
    }
    finally {
        if ([System.IO.Directory]::Exists($testRoot)) {
            Remove-TreeWithoutFollowingReparse `
                -Path $testRoot `
                -ApprovedRoot $tempParent
        }
        $script:selfTestMode = $false
    }
}

function Merge-RequestArguments {
    param(
        [string]$WorkerRoot,
        [string]$WorkerRequestPath
    )

    if ([string]::IsNullOrWhiteSpace($WorkerRequestPath)) {
        return
    }
    if ([string]::IsNullOrWhiteSpace($WorkerRoot)) {
        Throw-WorkerError "E_INVALID_REQUEST" (
            "使用 RequestPath 时仍必须通过 -Root 指定整合包根目录。"
        )
    }
    $paths = Get-WorkerPaths $WorkerRoot
    $fullRequestPath = [System.IO.Path]::GetFullPath($WorkerRequestPath)
    if (-not (Test-DirectChildPath `
        -Path $fullRequestPath `
        -Parent (Join-Path $paths.Launcher "state"))) {
        Throw-WorkerError "E_PATH_UNSAFE" (
            "请求文件必须位于 user\launcher\state 的直接子目录。"
        )
    }
    $request = Read-JsonFile -Path $fullRequestPath -MaximumBytes 256KB
    if ([int](Get-ObjectValue $request "schemaVersion" 0) -ne 1) {
        Throw-WorkerError "E_INVALID_REQUEST" "请求 schemaVersion 必须为 1。"
    }
    if ([string]::IsNullOrWhiteSpace($script:requestedAction)) {
        $script:requestedAction = [string](Get-ObjectValue $request "action" "")
    }
    if ([string]::IsNullOrWhiteSpace($script:requestedId)) {
        $script:requestedId = [string](Get-ObjectValue $request "id" "")
    }
    if ([string]::IsNullOrWhiteSpace($script:requestedName)) {
        $script:requestedName = [string](Get-ObjectValue $request "name" "")
    }
    if ([string]::IsNullOrWhiteSpace($script:requestedQuery)) {
        $script:requestedQuery = [string](Get-ObjectValue $request "query" "")
    }
    if ([string]::IsNullOrWhiteSpace($script:requestedSettingsPath)) {
        $script:requestedSettingsPath = [string](
            Get-ObjectValue $request "settingsPath" ""
        )
    }
    $script:requestedCatalogUrl = [string](
        Get-ObjectValue $request "catalogUrl" ""
    )
}

$script:requestedAction = if ($SelfTest) {
    "SelfTest"
}
else {
    $Action
}
$script:requestedId = $Id
$script:requestedName = $Name
$script:requestedQuery = $Query
$script:requestedSettingsPath = $SettingsPath
$script:requestedCatalogUrl = ""

$result = $null
$exitCode = 0
try {
    $servicesPath = Join-Path $PSScriptRoot "ComfyUI-Launcher.Services.psm1"
    if (-not [System.IO.File]::Exists($servicesPath)) {
        throw "缺少 ComfyUI-Launcher.Services.psm1。"
    }
    [void](Import-Module $servicesPath -Force)

    Merge-RequestArguments -WorkerRoot $Root -WorkerRequestPath $RequestPath
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $resultPaths = Get-WorkerPaths $Root
        $fullResultPath = [System.IO.Path]::GetFullPath($ResultPath)
        if (-not (Test-DirectChildPath `
            -Path $fullResultPath `
            -Parent (Join-Path $resultPaths.Launcher "state"))) {
            Throw-WorkerError "E_PATH_UNSAFE" (
                "结果文件必须位于 user\launcher\state 的直接子目录。"
            )
        }
        $resultParent = [System.IO.Path]::GetDirectoryName($fullResultPath)
        if (-not [System.IO.Directory]::Exists($resultParent)) {
            [void][System.IO.Directory]::CreateDirectory($resultParent)
        }
        $script:workerResultPath = $fullResultPath
    }
    if ($script:requestedAction -notin @(
        "ListInstalled",
        "SearchCatalog",
        "RefreshCatalog",
        "Enable",
        "Disable",
        "Install",
        "Remove",
        "Restore",
        "SelfTest"
    )) {
        Throw-WorkerError "E_INVALID_ACTION" "不支持的扩展管理操作。"
    }

    if ($script:requestedAction -eq "SelfTest") {
        $result = Invoke-WorkerSelfTest
    }
    else {
        $paths = Initialize-WorkerRoot $Root
        $script:settingsPath = $script:requestedSettingsPath
        if ($script:requestedAction -in $script:mutationActions) {
            $result = Invoke-WithMutationLock $paths {
                Invoke-InterruptedExtensionTransactionRecovery $paths
                switch ($script:requestedAction) {
                    "RefreshCatalog" {
                        Invoke-RefreshCatalog `
                            -Paths $paths `
                            -CatalogUrl $script:requestedCatalogUrl
                    }
                    "Enable" {
                        Set-ExtensionEnabledState `
                            -Paths $paths `
                            -Enabled $true `
                            -ItemId $script:requestedId `
                            -ItemName $script:requestedName
                    }
                    "Disable" {
                        Set-ExtensionEnabledState `
                            -Paths $paths `
                            -Enabled $false `
                            -ItemId $script:requestedId `
                            -ItemName $script:requestedName
                    }
                    "Install" {
                        if ([string]::IsNullOrWhiteSpace($script:requestedId)) {
                            Throw-WorkerError "E_INVALID_REQUEST" "安装操作必须提供目录条目 Id。"
                        }
                        Invoke-InstallExtension `
                            -Paths $paths `
                            -CatalogId $script:requestedId
                    }
                    "Remove" {
                        Invoke-RemoveExtension `
                            -Paths $paths `
                            -ItemId $script:requestedId `
                            -ItemName $script:requestedName
                    }
                    "Restore" {
                        Invoke-RestoreExtension `
                            -Paths $paths `
                            -ItemId $script:requestedId `
                            -ItemName $script:requestedName
                    }
                }
            }
        }
        else {
            [void](Invoke-WithMutationLock $paths {
                Invoke-InterruptedExtensionTransactionRecovery $paths
            })
            switch ($script:requestedAction) {
                "ListInstalled" {
                    $result = Invoke-ListInstalled $paths
                }
                "SearchCatalog" {
                    $result = Invoke-SearchCatalog `
                        -Paths $paths `
                        -SearchText $script:requestedQuery
                }
            }
        }
    }
}
catch {
    $exitCode = 1
    $resultAction = if ([string]::IsNullOrWhiteSpace($script:requestedAction)) {
        "Unknown"
    }
    else {
        $script:requestedAction
    }
    $code = [string]$_.Exception.Data["WorkerCode"]
    if ([string]::IsNullOrWhiteSpace($code)) {
        $code = "E_INTERNAL"
    }
    $message = ConvertTo-SafeText $_.Exception.Message
    if ($script:requestedAction -eq "SelfTest" -and
        -not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
        $message += " | DEBUG " + [string]$_.ScriptStackTrace
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        $message = "扩展管理操作失败。"
    }
    Write-WorkerLog (
        "{0} 失败：{1} / {2}" -f
        $script:requestedAction,
        $code,
        $message
    )
    $result = New-WorkerResult `
        -ResultAction $resultAction `
        -Ok $false `
        -Code $code `
        -Message $message
}

Write-WorkerResult $result
exit $exitCode
