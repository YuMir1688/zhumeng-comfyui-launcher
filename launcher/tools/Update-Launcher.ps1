param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot),
    [int]$LauncherPid = 0,
    [string]$LocalArchive = '',
    [string]$LocalManifest = '',
    [switch]$NonInteractive,
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Net.Http
$utf8 = New-Object Text.UTF8Encoding($false)
$Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
$repository = 'YuMir1688/zhumeng-comfyui-launcher'
$manifestUrl = "https://github.com/$repository/releases/latest/download/launcher-update.json"
$form = $null
$lock = $null
$stage = $null
$changed = New-Object 'System.Collections.Generic.List[object]'

function Show-Progress([string]$Text) {
    if ($null -ne $form) { $label.Text = $Text; [Windows.Forms.Application]::DoEvents() }
    if (-not $CheckOnly) { Write-Output $Text }
}
function Confirm-Update([string]$Text) {
    if ($NonInteractive) { return $true }
    return [Windows.Forms.MessageBox]::Show($Text, '筑梦启动器更新', 'OKCancel', 'Information') -eq 'OK'
}
function Assert-PatchPath([string]$Relative) {
    if ($Relative -notmatch '^(tools/[A-Za-z0-9_.-]+\.(ps1|psm1|xaml|json|cs|py|exe|vbs)|tools/assets/[A-Za-z0-9_./-]+\.(jpg|jpeg|png|webp|ico)|assets/icons/[A-Za-z0-9_.-]+\.(ico|png)|启动_ComfyUI\.exe)$' -or
        $Relative -match '(^|/)\.\.(/|$)|:|\\') { throw "补丁路径不允许：$Relative" }
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '补丁越界' }
    $parent = $full
    while ($parent -and $parent.Length -ge $Root.Length) {
        if ((Test-Path -LiteralPath $parent) -and ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "不能更新链接路径：$parent" }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    return $full
}
function Download-File([string]$Url, [string]$Destination) {
    $urls = @($Url)
    if ($network.github.downloadMode -eq 'auto') {
        $urls += 'https://gh-proxy.com/' + $Url
        $urls += 'https://ghfast.top/' + $Url
    }
    elseif ($network.github.downloadMode -eq 'custom' -and $network.github.acceleratorPrefix) {
        $prefix = [string]$network.github.acceleratorPrefix
        if ($prefix -notmatch '^https://') { throw '下载加速地址必须使用 HTTPS' }
        $urls = @($prefix.TrimEnd('/') + '/' + $Url)
    }
    $errors = @()
    foreach ($candidate in $urls) {
        Show-Progress ('正在下载：' + ([Uri]$candidate).Host)
        $handler = New-Object Net.Http.HttpClientHandler
        if ($network.proxy.mode -eq 'none') { $handler.UseProxy = $false }
        elseif ($network.proxy.mode -eq 'custom') {
            $address = [string]$network.proxy.address
            if ($address -notmatch '^https?://') { $address = 'http://' + $address }
            $builder = New-Object UriBuilder($address)
            $builder.Port = [int]$network.proxy.port
            $handler.Proxy = New-Object Net.WebProxy($builder.Uri)
        }
        $client = New-Object Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(90)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('ZhumengLauncher/1.3.2')
        try {
            $task = $client.GetByteArrayAsync($candidate)
            while (-not $task.IsCompleted) {
                if ($null -ne $form) { [Windows.Forms.Application]::DoEvents() }
                Start-Sleep -Milliseconds 100
            }
            $bytes = $task.GetAwaiter().GetResult()
            if ($bytes.Length -gt 67108864) { throw '补丁超过 64MB 限制' }
            [IO.File]::WriteAllBytes($Destination, $bytes)
            return
        }
        catch { $errors += (([Uri]$candidate).Host + ': ' + $_.Exception.Message) }
        finally { $client.Dispose(); $handler.Dispose() }
    }
    throw ('下载失败，原文件未改动。' + ($errors -join '; '))
}
try {
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.ext/python.exe'))) { throw '请选择完整整合包目录。' }
    if (-not $NonInteractive) {
        Add-Type -AssemblyName System.Windows.Forms
        $form = New-Object Windows.Forms.Form
        $form.Text = '筑梦启动器更新'
        $form.Width = 540; $form.Height = 140; $form.StartPosition = 'CenterScreen'
        $form.ControlBox = $false
        $label = New-Object Windows.Forms.Label
        $label.Dock = 'Fill'; $label.Padding = New-Object Windows.Forms.Padding(16)
        $form.Controls.Add($label); $form.Show()
    }
    $network = [pscustomobject]@{
        github = [pscustomobject]@{downloadMode='auto'; acceleratorPrefix=''}
        proxy = [pscustomobject]@{mode='system'; address=''; port=0}
    }
    $settings = Join-Path $Root 'user/launcher/settings.json'
    if (Test-Path -LiteralPath $settings) { $network = ([IO.File]::ReadAllText($settings) | ConvertFrom-Json).network }
    $current = [IO.File]::ReadAllText((Join-Path $Root 'tools/launcher-version.json')) | ConvertFrom-Json
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('ZhumengUpdate-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)
    $manifestPath = Join-Path $stage 'launcher-update.json'
    if ($LocalManifest) { Copy-Item -LiteralPath $LocalManifest -Destination $manifestPath }
    else { Download-File $manifestUrl $manifestPath }
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.version -notmatch '^\d+\.\d+\.\d+$' -or $manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '更新清单格式不正确' }
    if ([version]$current.version -lt [version]$manifest.minimumVersion) { throw '当前版本太旧，请先安装维护补丁。' }
    if ($CheckOnly) { $manifest | ConvertTo-Json -Depth 4; exit 0 }
    if ([version]$manifest.version -le [version]$current.version) { Show-Progress ('当前已经是最新启动器：' + $current.version); if (-not $NonInteractive) { [void](Confirm-Update ('当前已经是最新启动器：' + $current.version)) }; exit 0 }
    if (-not (Confirm-Update ("发现启动器 $($manifest.version)。`n将下载启动器补丁，下载完成后需要关闭主启动器。`n继续更新？"))) { exit 0 }
    $archive = Join-Path $stage 'patch.zip'
    if ($LocalArchive) { Copy-Item -LiteralPath $LocalArchive -Destination $archive }
    else {
        if ($manifest.url -notlike "https://github.com/$repository/releases/download/*") { throw '补丁来源与发布仓库不一致' }
        Download-File $manifest.url $archive
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $manifest.sha256) { throw '补丁校验失败，原文件未改动。' }
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    try {
        $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [long]$total = 0
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match '(^|/)\.\.(/|$)|:|\\' -or $entry.FullName.StartsWith('/')) { throw '补丁包含越界路径' }
            if (-not $entry.Name) { continue }
            if ($entry.FullName -ne 'patch.json') { [void](Assert-PatchPath $entry.FullName) }
            if (-not $paths.Add($entry.FullName)) { throw '补丁包含重复文件' }
            $total += $entry.Length
        }
        if ($total -gt 134217728) { throw '解压体积超过限制' }
    } finally { $zip.Dispose() }
    $payload = Join-Path $stage 'payload'
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $payload)
    $patch = [IO.File]::ReadAllText((Join-Path $payload 'patch.json')) | ConvertFrom-Json
    if ($patch.version -ne $manifest.version -or @($patch.files).Count -ne ($paths.Count - 1)) { throw '补丁清单不一致' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $patch.files) {
        [void](Assert-PatchPath $file.path)
        if (-not $seen.Add($file.path)) { throw '补丁清单重复' }
        if ((Get-FileHash -LiteralPath (Join-Path $payload $file.path) -Algorithm SHA256).Hash -ine $file.sha256) { throw "文件校验失败：$($file.path)" }
        if ($file.path -match '\.(ps1|psm1)$') {
            $tokens=$null; $parseErrors=$null
            [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $payload $file.path), [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count) { throw "补丁脚本语法错误：$($file.path)" }
        }
    }
    if (-not $seen.Contains('tools/launcher-version.json')) { throw '补丁缺少版本文件' }
    $newVersion = [IO.File]::ReadAllText((Join-Path $payload 'tools/launcher-version.json')) | ConvertFrom-Json
    if ($newVersion.version -ne $manifest.version) { throw '补丁版本不一致' }
    if ($seen.Contains('启动_ComfyUI.exe') -and [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $payload '启动_ComfyUI.exe')).FileVersion -ne ($manifest.version + '.0')) { throw 'EXE 文件版本与补丁版本不一致' }
    if ($LauncherPid -gt 0 -and (Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue)) {
        if (-not (Confirm-Update '补丁已下载并通过校验。请关闭 ComfyUI 主启动器，然后点击确定安装。')) { exit 0 }
        if (Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue) { throw '主启动器仍在运行，请先关闭后重试。' }
    }
    $active = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^python(w)?\.exe$' -and $_.ExecutablePath -and $_.ExecutablePath.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase) })
    if ($active.Count) { throw '整合包的 Python 仍在运行，请停止任务后重试。' }
    $cache = Join-Path $Root '.cache'
    if ((Test-Path -LiteralPath $cache) -and ((Get-Item -LiteralPath $cache -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw '更新缓存不能是目录链接' }
    [void][IO.Directory]::CreateDirectory($cache)
    $lock = [IO.File]::Open((Join-Path $cache 'launcher-update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $backup = Join-Path $cache ('launcher-backup-' + [Guid]::NewGuid().ToString('N'))
    foreach ($file in @($patch.files | Sort-Object { $_.path -eq 'tools/launcher-version.json' })) {
        $target = Assert-PatchPath $file.path
        $saved = Join-Path $backup $file.path
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        if ($exists) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)); [IO.File]::Copy($target, $saved) }
        $changed.Add([pscustomobject]@{Target=$target; Backup=$saved; Existed=$exists})
        [void][IO.Directory]::CreateDirectory($backup)
        [IO.File]::WriteAllText((Join-Path $backup 'transaction.json'), ($changed.ToArray() | ConvertTo-Json), $utf8)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $payload $file.path), $target, $true)
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $file.sha256) { throw '安装后的文件校验失败' }
    }
    [IO.File]::WriteAllText((Join-Path $backup 'transaction.json'), ($changed.ToArray() | ConvertTo-Json), $utf8)
    Show-Progress ('启动器已更新到 ' + $manifest.version)
    if (-not $NonInteractive) { [void](Confirm-Update "更新完成，请重新打开启动器。`n备份保存在：$backup") }
} catch {
    $failure = $_.Exception.Message
    for ($i=$changed.Count-1; $i -ge 0; $i--) {
        $item=$changed[$i]
        try {
            if ($item.Existed) {
                if (-not [IO.File]::Exists($item.Target) -or
                    (Get-FileHash -LiteralPath $item.Target).Hash -ne (Get-FileHash -LiteralPath $item.Backup).Hash) {
                    [IO.File]::Copy($item.Backup, $item.Target, $true)
                }
            }
            elseif ([IO.File]::Exists($item.Target)) { [IO.File]::Delete($item.Target) }
        } catch { $failure += '; 文件恢复失败：' + $item.Target }
    }
    if (-not $NonInteractive) { [void][Windows.Forms.MessageBox]::Show($failure, '启动器更新失败', 'OK', 'Error') }
    Write-Error $failure -ErrorAction Continue
    exit 1
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
    if ($null -ne $form) { $form.Dispose() }
    # Keep staging and backups for troubleshooting; never remove recovery files.
}
