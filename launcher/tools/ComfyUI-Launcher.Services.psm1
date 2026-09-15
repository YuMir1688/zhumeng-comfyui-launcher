Set-StrictMode -Version 2.0

function Get-LauncherPropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function New-LauncherSettings {
    return [pscustomobject]@{
        schemaVersion = 1
        network = [pscustomobject]@{
            huggingFace = [pscustomobject]@{
                mode = "mirror"
                customUrl = ""
            }
            github = [pscustomobject]@{
                downloadMode = "auto"
                acceleratorPrefix = ""
            }
            pypi = [pscustomobject]@{
                mode = "tsinghua"
                customUrl = ""
            }
            proxy = [pscustomobject]@{
                mode = "system"
                address = ""
                port = 0
            }
        }
        updates = [pscustomobject]@{
            autoCheck = $true
            channel = "stable"
            lastCheckUtc = ""
            ignoredCoreVersion = ""
            cachedCoreVersion = ""
            cachedCorePublishedAt = ""
            cachedCoreReleaseUrl = ""
        }
    }
}

function Merge-LauncherSettings {
    param([object]$LoadedSettings)

    $settings = New-LauncherSettings
    if ($null -eq $LoadedSettings) {
        return $settings
    }

    $network = Get-LauncherPropertyValue $LoadedSettings "network"
    $hf = Get-LauncherPropertyValue $network "huggingFace"
    $github = Get-LauncherPropertyValue $network "github"
    $pypi = Get-LauncherPropertyValue $network "pypi"
    $proxy = Get-LauncherPropertyValue $network "proxy"
    $updates = Get-LauncherPropertyValue $LoadedSettings "updates"

    $hfMode = [string](Get-LauncherPropertyValue $hf "mode" "mirror")
    if ($hfMode -notin @("auto", "official", "mirror", "custom")) {
        $hfMode = "mirror"
    }
    $settings.network.huggingFace.mode = $hfMode
    $settings.network.huggingFace.customUrl = [string](Get-LauncherPropertyValue $hf "customUrl" "")

    $githubMode = [string](Get-LauncherPropertyValue $github "downloadMode" "auto")
    if ($githubMode -notin @("auto", "official", "accelerator", "custom")) {
        $githubMode = "auto"
    }
    $settings.network.github.downloadMode = $githubMode
    $settings.network.github.acceleratorPrefix = [string](Get-LauncherPropertyValue $github "acceleratorPrefix" "")

    $pypiMode = [string](Get-LauncherPropertyValue $pypi "mode" "tsinghua")
    if ($pypiMode -notin @("auto", "official", "aliyun", "tsinghua", "ustc", "custom")) {
        $pypiMode = "tsinghua"
    }
    $settings.network.pypi.mode = $pypiMode
    $settings.network.pypi.customUrl = [string](Get-LauncherPropertyValue $pypi "customUrl" "")

    $proxyMode = [string](Get-LauncherPropertyValue $proxy "mode" "system")
    if ($proxyMode -notin @("system", "none", "custom")) {
        $proxyMode = "system"
    }
    $settings.network.proxy.mode = $proxyMode
    $settings.network.proxy.address = [string](Get-LauncherPropertyValue $proxy "address" "")
    $proxyPort = 0
    [void][int]::TryParse([string](Get-LauncherPropertyValue $proxy "port" 0), [ref]$proxyPort)
    $settings.network.proxy.port = $proxyPort

    $settings.updates.autoCheck = [bool](Get-LauncherPropertyValue $updates "autoCheck" $true)
    $channel = [string](Get-LauncherPropertyValue $updates "channel" "stable")
    if ($channel -notin @("stable", "preview")) {
        $channel = "stable"
    }
    $settings.updates.channel = $channel
    foreach ($name in @(
        "lastCheckUtc",
        "ignoredCoreVersion",
        "cachedCoreVersion",
        "cachedCorePublishedAt",
        "cachedCoreReleaseUrl"
    )) {
        $settings.updates.$name = [string](Get-LauncherPropertyValue $updates $name "")
    }

    return $settings
}

function Read-LauncherSettings {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) {
        return New-LauncherSettings
    }

    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $json = [System.IO.File]::ReadAllText($Path, $utf8)
        if ([string]::IsNullOrWhiteSpace($json)) {
            return New-LauncherSettings
        }
        return Merge-LauncherSettings ($json | ConvertFrom-Json)
    }
    catch {
        return New-LauncherSettings
    }
}

function Save-LauncherSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Settings
    )

    $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Path))
    if (-not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }

    $normalized = Merge-LauncherSettings $Settings
    $json = $normalized | ConvertTo-Json -Depth 8
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $temporaryPath = $Path + ".tmp-" + [Guid]::NewGuid().ToString("N")
    [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8)

    try {
        if ([System.IO.File]::Exists($Path)) {
            $backupPath = $Path + ".bak"
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

function Test-LauncherHttpUrl {
    param(
        [string]$Value,
        [switch]$AllowEmpty
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [bool]$AllowEmpty
    }

    $uri = $null
    if (-not [System.Uri]::TryCreate($Value.Trim(), [System.UriKind]::Absolute, [ref]$uri)) {
        return $false
    }
    if ($uri.Scheme -notin @("http", "https")) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host) -or -not [string]::IsNullOrEmpty($uri.UserInfo)) {
        return $false
    }
    return $true
}

function Get-LauncherHuggingFaceEndpoint {
    param([Parameter(Mandatory = $true)][object]$Settings)

    switch ([string]$Settings.network.huggingFace.mode) {
        "mirror" { return "https://hf-mirror.com" }
        "custom" { return ([string]$Settings.network.huggingFace.customUrl).TrimEnd("/") }
        default { return "https://huggingface.co" }
    }
}

function Get-LauncherPypiIndexUrl {
    param([Parameter(Mandatory = $true)][object]$Settings)

    switch ([string]$Settings.network.pypi.mode) {
        "aliyun" { return "https://mirrors.aliyun.com/pypi/simple/" }
        "tsinghua" { return "https://pypi.tuna.tsinghua.edu.cn/simple/" }
        "ustc" { return "https://mirrors.ustc.edu.cn/pypi/simple/" }
        "custom" { return ([string]$Settings.network.pypi.customUrl).TrimEnd("/") + "/" }
        default { return "https://pypi.org/simple/" }
    }
}

function Get-LauncherGithubReleaseApiUrl {
    param([Parameter(Mandatory = $true)][object]$Settings)

    if ([string]$Settings.updates.channel -eq "preview") {
        return "https://api.github.com/repos/Comfy-Org/ComfyUI/releases?per_page=10"
    }
    return "https://api.github.com/repos/Comfy-Org/ComfyUI/releases/latest"
}

function ConvertTo-LauncherGithubDownloadUrl {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalUrl,
        [Parameter(Mandatory = $true)][object]$Settings
    )

    $mode = [string]$Settings.network.github.downloadMode
    if ($mode -notin @("accelerator", "custom")) {
        return $OriginalUrl
    }

    $prefix = ([string]$Settings.network.github.acceleratorPrefix).Trim()
    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return $OriginalUrl
    }
    return $prefix.TrimEnd("/") + "/" + $OriginalUrl
}

function Get-LauncherProxyUri {
    param([Parameter(Mandatory = $true)][object]$Settings)

    if ([string]$Settings.network.proxy.mode -ne "custom") {
        return $null
    }

    $address = ([string]$Settings.network.proxy.address).Trim()
    $port = [int]$Settings.network.proxy.port
    if ([string]::IsNullOrWhiteSpace($address) -or $port -lt 1 -or $port -gt 65535) {
        return $null
    }

    if ($address -notmatch "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
        $address = "http://" + $address
    }
    $baseUri = New-Object System.Uri($address)
    $builder = New-Object System.UriBuilder($baseUri)
    $builder.Port = $port
    $builder.UserName = ""
    $builder.Password = ""
    return $builder.Uri
}

function New-LauncherHttpClient {
    param(
        [Parameter(Mandatory = $true)][object]$Settings,
        [int]$TimeoutSeconds = 12
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    switch ([string]$Settings.network.proxy.mode) {
        "none" {
            $handler.UseProxy = $false
        }
        "custom" {
            $proxyUri = Get-LauncherProxyUri $Settings
            if ($null -eq $proxyUri) {
                throw "自定义代理地址或端口无效。"
            }
            $handler.UseProxy = $true
            $handler.Proxy = New-Object -TypeName System.Net.WebProxy -ArgumentList @($proxyUri, $true)
        }
        default {
            $handler.UseProxy = $true
            $handler.Proxy = [System.Net.WebRequest]::DefaultWebProxy
        }
    }

    $client = New-Object -TypeName System.Net.Http.HttpClient -ArgumentList @($handler, $true)
    $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(3, $TimeoutSeconds))
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("ComfyUI-Desktop-Launcher/1.0")
    $client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json")
    return $client
}

function Start-LauncherNetworkProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][object]$Settings,
        [int]$TimeoutSeconds = 12
    )

    if (-not (Test-LauncherHttpUrl $Uri)) {
        throw "检测地址格式无效。"
    }

    $client = New-LauncherHttpClient $Settings $TimeoutSeconds
    $request = New-Object -TypeName System.Net.Http.HttpRequestMessage -ArgumentList @(
        [System.Net.Http.HttpMethod]::Get,
        (New-Object System.Uri($Uri))
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $task = $client.SendAsync(
        $request,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
    )

    return [pscustomobject]@{
        Name = $Name
        Uri = $Uri
        Client = $client
        Request = $request
        Stopwatch = $stopwatch
        Task = $task
    }
}

function Start-LauncherJsonRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][object]$Settings,
        [int]$TimeoutSeconds = 15
    )

    if (-not (Test-LauncherHttpUrl $Uri)) {
        throw "版本地址格式无效。"
    }

    $client = New-LauncherHttpClient $Settings $TimeoutSeconds
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $task = $client.GetStringAsync($Uri)
    return [pscustomobject]@{
        Uri = $Uri
        Client = $client
        Stopwatch = $stopwatch
        Task = $task
    }
}

function ConvertTo-LauncherNetworkError {
    param([object]$ErrorObject)

    if ($null -eq $ErrorObject) {
        return "当前网络无法访问"
    }

    $exception = $ErrorObject
    if ($ErrorObject -is [System.AggregateException]) {
        $exception = $ErrorObject.GetBaseException()
    }
    elseif ($null -ne $ErrorObject.Exception) {
        $exception = $ErrorObject.Exception
        if ($exception -is [System.AggregateException]) {
            $exception = $exception.GetBaseException()
        }
    }

    $message = [string]$exception.Message
    $lower = $message.ToLowerInvariant()
    if ($exception -is [System.Threading.Tasks.TaskCanceledException] -or $lower -match "timed out|timeout|超时") {
        return "请求超时"
    }
    if ($lower -match "name resolution|no such host|resolve|dns|找不到.*主机") {
        return "域名无法解析"
    }
    if ($lower -match "proxy|407|代理") {
        return "代理连接失败"
    }
    if ($lower -match "certificate|ssl|tls|secure channel|证书") {
        return "TLS 证书错误"
    }
    if ($lower -match "refused|actively refused|connection.*failed|无法连接") {
        return "服务器拒绝连接"
    }
    return "当前网络无法访问"
}

function ConvertTo-LauncherSafeDiagnosticText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    $safe = $Text
    $safe = [regex]::Replace(
        $safe,
        "(?i)(https?://)([^/@:\s]+):([^/\s]*)@",
        '$1***:***@'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?i)\bBearer\s+[A-Za-z0-9._~+/\-=]+",
        'Bearer ***'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?i)([?&](?:access[_-]?token|token|password|passwd|api[_-]?key|signature|sig)=)[^&#\s]+",
        '$1***'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?i)\b(token|password|passwd|cookie|authorization|api[_-]?key)\s*[:=]\s*[^\s;]+",
        '$1=***'
    )
    return $safe
}

function ConvertTo-LauncherSafeRunLogText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    $safe = $Text
    $safe = [regex]::Replace(
        $safe,
        "(?im)^(\s*(?:Cookie|Set-Cookie|Authorization|Proxy-Authorization)\s*:\s*).*$",
        '$1***'
    )
    $safe = ConvertTo-LauncherSafeDiagnosticText $safe
    $safe = [regex]::Replace(
        $safe,
        "(?i)([?&](?:client[_-]?secret|refresh[_-]?token|secret)=)[^&#\s]+",
        '$1***'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?i)\b(access[_-]?token|refresh[_-]?token|client[_-]?secret|proxy[_-]?password|secret)\s*[:=]\s*[^\s;]+",
        '$1=***'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?im)(--(?:access[_-]?token|refresh[_-]?token|token|password|passwd|proxy[_-]?password|cookie|authorization|api[_-]?key|client[_-]?secret)\s+)(?:`"[^`"\r\n]*`"|'[^'\r\n]*'|\S+)",
        '$1***'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?im)\b((?:HF_TOKEN|HUGGING_FACE_HUB_TOKEN|OPENAI_API_KEY|GITHUB_TOKEN|GH_TOKEN|PROXY_PASSWORD)\s*=\s*)(?:`"[^`"\r\n]*`"|'[^'\r\n]*'|[^\s;]+)",
        '$1***'
    )
    $safe = [regex]::Replace(
        $safe,
        '(?i)(["''](?:access[_-]?token|refresh[_-]?token|token|password|passwd|proxy[_-]?password|cookie|authorization|api[_-]?key|client[_-]?secret|secret)["'']\s*:\s*["''])[^"''\r\n]+(["''])',
        '$1***$2'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?i)\b(?:sk-[A-Za-z0-9]{20,}|sk-(?:proj|svcacct)-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})\b",
        '***'
    )
    $safe = [regex]::Replace(
        $safe,
        "(?i)\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}\b",
        '***'
    )
    $safe = [regex]::Replace(
        $safe,
        "\x1B\[[0-?]*[ -/]*[@-~]",
        ''
    )

    $userProfile = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile
    )
    if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
        $safe = [regex]::Replace(
            $safe,
            [regex]::Escape($userProfile.TrimEnd("\")),
            '%USERPROFILE%',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    return $safe
}

function Export-LauncherRunLog {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Path,
        [datetime]$ExportedAt = [DateTime]::Now
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw [System.InvalidOperationException]::new("当前没有可导出的运行日志。")
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ([System.IO.Directory]::Exists($fullPath)) {
        throw [System.ArgumentException]::new("请选择日志文件名，不能将文件夹用作导出文件。")
    }
    $parent = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw [System.ArgumentException]::new("导出路径无效。")
    }
    if (-not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }

    $safeText = ConvertTo-LauncherSafeRunLogText $Text
    $newLine = [Environment]::NewLine
    $header = @(
        "ComfyUI 当前会话运行日志",
        ("导出时间：{0}" -f $ExportedAt.ToString("yyyy-MM-dd HH:mm:ss")),
        "说明：仅包含当前启动器内存中的会话日志；敏感字段已自动隐藏。",
        "",
        "------------------------------------------------------------",
        ""
    ) -join $newLine
    $content = $header + $safeText.TrimEnd("`r", "`n") + $newLine

    $temporaryPath = Join-Path $parent (
        [System.IO.Path]::GetFileName($fullPath) +
        "." +
        [Guid]::NewGuid().ToString("N") +
        ".tmp"
    )
    $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $content, $utf8WithBom)
        if ([System.IO.File]::Exists($fullPath)) {
            [System.IO.File]::Copy($temporaryPath, $fullPath, $true)
            [System.IO.File]::Delete($temporaryPath)
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    finally {
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
    }

    return $fullPath
}

function ConvertTo-LauncherVersion {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $clean = $Value.Trim()
    if ($clean.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)) {
        $clean = $clean.Substring(1)
    }
    $core = $clean.Split("-")[0].Split("+")[0]
    $version = $null
    if ([System.Version]::TryParse($core, [ref]$version)) {
        return $version
    }
    return $null
}

function Test-LauncherVersionNewer {
    param(
        [string]$CurrentVersion,
        [string]$CandidateVersion
    )

    $current = ConvertTo-LauncherVersion $CurrentVersion
    $candidate = ConvertTo-LauncherVersion $CandidateVersion
    if ($null -eq $current -or $null -eq $candidate) {
        return $false
    }
    return ($candidate -gt $current)
}

Export-ModuleMember -Function @(
    "New-LauncherSettings",
    "Merge-LauncherSettings",
    "Read-LauncherSettings",
    "Save-LauncherSettings",
    "Test-LauncherHttpUrl",
    "Get-LauncherHuggingFaceEndpoint",
    "Get-LauncherPypiIndexUrl",
    "Get-LauncherGithubReleaseApiUrl",
    "ConvertTo-LauncherGithubDownloadUrl",
    "Get-LauncherProxyUri",
    "New-LauncherHttpClient",
    "Start-LauncherNetworkProbe",
    "Start-LauncherJsonRequest",
    "ConvertTo-LauncherNetworkError",
    "ConvertTo-LauncherSafeDiagnosticText",
    "ConvertTo-LauncherSafeRunLogText",
    "Export-LauncherRunLog",
    "ConvertTo-LauncherVersion",
    "Test-LauncherVersionNewer"
)
