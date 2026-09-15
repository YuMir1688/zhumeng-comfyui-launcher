param(
    [Parameter(Mandatory = $true)]
    [string]$Destination
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$toolsDirectory = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $MyInvocation.MyCommand.Path)
)
$root = [System.IO.Path]::GetFullPath(
    (Join-Path $toolsDirectory "..")
).TrimEnd("\")
$destinationRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd("\")

if ($destinationRoot.Equals(
        $root,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    $destinationRoot.StartsWith(
        $root + "\",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw "The release destination cannot be inside the source package."
}
if ([System.IO.Directory]::Exists($destinationRoot) -or
    [System.IO.File]::Exists($destinationRoot)) {
    throw "The release destination already exists. Use a new empty path: $destinationRoot"
}

$launcherBuildScript = Join-Path $toolsDirectory "Build-PortableLauncher.ps1"
$launcherExecutablePath = Join-Path $root "启动_ComfyUI.exe"
$launcherBuildInputs = @(
    (Join-Path $toolsDirectory "PortableLauncher.cs"),
    (Join-Path $root "assets\icons\comfyui-taskbar-large.ico")
)
$launcherNeedsBuild = -not [System.IO.File]::Exists($launcherExecutablePath)
if (-not $launcherNeedsBuild) {
    $launcherTimestamp = (
        Get-Item -LiteralPath $launcherExecutablePath
    ).LastWriteTimeUtc
    $launcherNeedsBuild = @(
        $launcherBuildInputs |
            Where-Object {
                -not [System.IO.File]::Exists($_) -or
                (Get-Item -LiteralPath $_).LastWriteTimeUtc -gt $launcherTimestamp
            }
    ).Count -gt 0
}
$launcherOutput = if ($launcherNeedsBuild) {
    & $launcherBuildScript -Root $root
}
else {
    [pscustomobject]@{
        Result = "OK"
        Output = $launcherExecutablePath
        Reused = $true
        Bytes = (Get-Item -LiteralPath $launcherExecutablePath).Length
    } | ConvertTo-Json -Compress
}
if (-not [System.IO.File]::Exists($launcherExecutablePath)) {
    throw "The portable launcher was not generated."
}

[void][System.IO.Directory]::CreateDirectory($destinationRoot)

$excludedDirectories = @(
    (Join-Path $root "user"),
    (Join-Path $root "input"),
    (Join-Path $root "output"),
    (Join-Path $root "temp"),
    (Join-Path $root "models"),
    (Join-Path $root ".cache"),
    (Join-Path $root "__pycache__"),
    ".git",
    ".pytest_cache",
    ".mypy_cache",
    "__pycache__"
)
$robocopyArguments = @(
    $root,
    $destinationRoot,
    "/E",
    "/COPY:DAT",
    "/DCOPY:DAT",
    "/R:2",
    "/W:1",
    "/XJ",
    "/NP",
    "/NFL",
    "/NDL",
    "/NJH",
    "/NJS",
    "/XF",
    "启动_ComfyUI.lnk",
    "release-info.json",
    "release-checksums.sha256",
    "*.pyc",
    "*.pyo",
    "*.nbc",
    "*.nbi",
    "*.log",
    "*.tmp",
    "*.lock",
    "*.bak",
    "Thumbs.db",
    "/XD"
) + $excludedDirectories

$robocopy = Join-Path $env:SystemRoot "System32\robocopy.exe"
& $robocopy @robocopyArguments
$copyExitCode = $LASTEXITCODE
if ($copyExitCode -ge 8) {
    throw "Robocopy failed with exit code $copyExitCode."
}

foreach ($relativeDirectory in @(
    "input",
    "output",
    "temp",
    "user",
    "user\launcher",
    "user\default",
    "user\__manager"
)) {
    $path = Join-Path $destinationRoot $relativeDirectory
    if (-not [System.IO.Directory]::Exists($path)) {
        [void][System.IO.Directory]::CreateDirectory($path)
    }
}

$sourceModelsRoot = Join-Path $root "models"
$destinationModelsRoot = Join-Path $destinationRoot "models"
[void][System.IO.Directory]::CreateDirectory($destinationModelsRoot)
if ([System.IO.Directory]::Exists($sourceModelsRoot)) {
    foreach ($sourceModelDirectory in @(
        Get-ChildItem `
            -LiteralPath $sourceModelsRoot `
            -Directory `
            -Recurse `
            -Force `
            -ErrorAction Stop
    )) {
        $relativeModelDirectory = $sourceModelDirectory.FullName.Substring(
            $sourceModelsRoot.Length
        ).TrimStart("\")
        [void][System.IO.Directory]::CreateDirectory(
            (Join-Path $destinationModelsRoot $relativeModelDirectory)
        )
    }
}

$defaultSettings = Join-Path $root "user\default\comfy.settings.json"
if ([System.IO.File]::Exists($defaultSettings)) {
    [System.IO.File]::Copy(
        $defaultSettings,
        (Join-Path $destinationRoot "user\default\comfy.settings.json"),
        $false
    )
}

$managerSource = Join-Path $root "user\__manager"
$managerDestination = Join-Path $destinationRoot "user\__manager"
foreach ($safeManagerFile in @("channels.list", "config.ini")) {
    $sourcePath = Join-Path $managerSource $safeManagerFile
    if ([System.IO.File]::Exists($sourcePath)) {
        [System.IO.File]::Copy(
            $sourcePath,
            (Join-Path $managerDestination $safeManagerFile),
            $false
        )
    }
}

$managerCacheSource = Join-Path $managerSource "cache"
if ([System.IO.Directory]::Exists($managerCacheSource)) {
    $managerCacheDestination = Join-Path $managerDestination "cache"
    [void][System.IO.Directory]::CreateDirectory($managerCacheDestination)
    & $robocopy @(
        $managerCacheSource,
        $managerCacheDestination,
        "/E",
        "/COPY:DAT",
        "/DCOPY:DAT",
        "/R:2",
        "/W:1",
        "/XJ",
        "/NP",
        "/NFL",
        "/NDL",
        "/NJH",
        "/NJS"
    )
    $cacheExitCode = $LASTEXITCODE
    if ($cacheExitCode -ge 8) {
        throw "Copying the ComfyUI Manager cache failed with exit code $cacheExitCode."
    }
}

$entrypointRepairScript = Join-Path `
    $destinationRoot `
    "tools\Repair-Portable-Entrypoints.ps1"
$entrypointRepairOutput = & $entrypointRepairScript -Root $destinationRoot
if ($LASTEXITCODE -ne 0) {
    throw "Repairing portable Python entrypoints failed."
}

$portableTextRelativePaths = @(
    ".ext\condabin\micromamba.bat",
    ".ext\condabin\mamba_hook.bat",
    "custom_nodes\ComfyUI-MieNodes\scripts\manual_merge_offloaded_images.py"
)
$driveBoundPathPattern = '(?im)(?<![A-Za-z0-9_])[A-Za-z]:[\\/]'
$pathBoundPortableFiles = @(
    foreach ($relativePath in $portableTextRelativePaths) {
        $path = Join-Path $destinationRoot $relativePath
        if (-not [System.IO.File]::Exists($path)) {
            throw "Portable release file is missing: $relativePath"
        }
        $content = [System.IO.File]::ReadAllText(
            $path,
            [System.Text.Encoding]::UTF8
        )
        if ([regex]::IsMatch($content, $driveBoundPathPattern)) {
            $relativePath
        }
    }
)
if ($pathBoundPortableFiles.Count -gt 0) {
    throw (
        "The release contains machine-bound absolute paths in: " +
        ($pathBoundPortableFiles -join ", ")
    )
}

$bundledNodesPath = Join-Path `
    $destinationRoot `
    "tools\bundled-custom-nodes.json"
$customNodesRoot = Join-Path $destinationRoot "custom_nodes"
$bundledNodeCandidates = @(
    Get-ChildItem `
        -LiteralPath $customNodesRoot `
        -Force `
        -Directory `
        -ErrorAction Stop |
        Where-Object {
            $_.Name -notin @(".disabled", "__pycache__") -and
            -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        } |
        ForEach-Object {
            [pscustomobject]@{
                directory = $_.Name
                relativePath = "custom_nodes\$($_.Name)"
                initialState = "enabled"
            }
        }
)
$disabledNodesRoot = Join-Path $customNodesRoot ".disabled"
if ([System.IO.Directory]::Exists($disabledNodesRoot)) {
    $bundledNodeCandidates += @(
        Get-ChildItem `
            -LiteralPath $disabledNodesRoot `
            -Force `
            -Directory `
            -ErrorAction Stop |
            Where-Object {
                $_.Name -ne "__pycache__" -and
                -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            } |
            ForEach-Object {
                [pscustomobject]@{
                    directory = $_.Name
                    relativePath = "custom_nodes\.disabled\$($_.Name)"
                    initialState = "disabled"
                }
            }
    )
}
$duplicateBundledNodes = @(
    $bundledNodeCandidates |
        Group-Object -Property directory |
        Where-Object { $_.Count -gt 1 }
)
if ($duplicateBundledNodes.Count -gt 0) {
    $duplicateNames = @(
        $duplicateBundledNodes |
            ForEach-Object { [string]$_.Name }
    )
    throw (
        "A bundled custom-node directory exists in more than one state: " +
        ($duplicateNames -join ", ")
    )
}
$bundledNodes = @(
    $bundledNodeCandidates |
        Sort-Object -Property directory |
        ForEach-Object {
            [ordered]@{
                directory = [string]$_.directory
                relativePath = [string]$_.relativePath
                initialState = [string]$_.initialState
            }
        }
)
$bundledNodesManifest = [ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    policy = "protected-release-baseline"
    count = $bundledNodes.Count
    nodes = $bundledNodes
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText(
    $bundledNodesPath,
    ($bundledNodesManifest | ConvertTo-Json -Depth 5),
    $utf8
)

$coreVersionText = [System.IO.File]::ReadAllText(
    (Join-Path $destinationRoot "comfyui_version.py"),
    [System.Text.Encoding]::UTF8
)
$coreVersionMatch = [regex]::Match(
    $coreVersionText,
    '__version__\s*=\s*[''"](?<version>[^''"]+)[''"]'
)
$coreVersion = if ($coreVersionMatch.Success) {
    $coreVersionMatch.Groups["version"].Value
}
else {
    "unknown"
}

$launcherVersionPath = Join-Path $destinationRoot "tools\launcher-version.json"
$launcherVersion = (
    [System.IO.File]::ReadAllText(
        $launcherVersionPath,
        [System.Text.Encoding]::UTF8
    ) | ConvertFrom-Json
).version

$allFiles = @(
    Get-ChildItem `
        -LiteralPath $destinationRoot `
        -Force `
        -File `
        -Recurse `
        -ErrorAction Stop
)
$releaseInfo = [ordered]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    launcherVersion = [string]$launcherVersion
    comfyuiVersion = [string]$coreVersion
    entryPoint = "启动_ComfyUI.exe"
    supportedGpu = @(
        "NVIDIA RTX 30 series",
        "NVIDIA RTX 40 series",
        "NVIDIA RTX 50 series"
    )
    networkDefaults = [ordered]@{
        huggingFace = "hf-mirror"
        github = "auto-official"
        pypi = "tsinghua"
        proxy = "system"
    }
    preserves = @(
        "models",
        "custom_nodes",
        "input",
        "output",
        "user"
    )
    bundledModels = $false
    byteCountScope = "all files except release-info.json and release-checksums.sha256"
    fileCount = $allFiles.Count + 2
    bytes = [long](($allFiles | Measure-Object -Property Length -Sum).Sum)
}
[System.IO.File]::WriteAllText(
    (Join-Path $destinationRoot "release-info.json"),
    ($releaseInfo | ConvertTo-Json -Depth 6),
    $utf8
)

$checksumRelativePaths = @(
    "启动_ComfyUI.exe",
    "启动_ComfyUI_备用.bat",
    "main.py",
    "tools\Launch-ComfyUI.vbs",
    "tools\ComfyUI-Launcher.ps1",
    "tools\ComfyUI-Launcher.xaml",
    "tools\ComfyUI-Launcher.Services.psm1",
    "tools\ComfyUI-Core-Updater.ps1",
    "tools\Update-Launcher.ps1",
    "tools\ComfyUI-Extension-Worker.ps1",
    "tools\bundled-custom-nodes.json",
    "tools\launcher-version.json",
    "tools\PortableEntrypointLauncher.cs",
    "tools\PortableEntrypointLauncher.exe",
    "tools\Repair-Portable-Entrypoints.py",
    "tools\Repair-Portable-Entrypoints.ps1",
    "tools\known-pip-conflicts.txt",
    ".ext\condabin\micromamba.bat",
    ".ext\condabin\mamba_hook.bat",
    "custom_nodes\ComfyUI-MieNodes\scripts\manual_merge_offloaded_images.py",
    "custom_nodes\ComfyUI-dapaoAPI\ComfyUI_LLM_Banana\banana_upscale.py",
    "tools\sox\sox.exe",
    "tools\sox\libsox-3.dll",
    "tools\sox\zlib1.dll",
    "tools\sox\LICENSE.GPL.txt",
    "release-info.json"
)
$checksumLines = @(
    foreach ($relativePath in $checksumRelativePaths) {
        $hash = Get-FileHash `
            -LiteralPath (Join-Path $destinationRoot $relativePath) `
            -Algorithm SHA256
        "{0} *{1}" -f $hash.Hash.ToLowerInvariant(), $relativePath
    }
)
[System.IO.File]::WriteAllLines(
    (Join-Path $destinationRoot "release-checksums.sha256"),
    $checksumLines,
    $utf8
)

$publicRootFiles = @(
    "启动_ComfyUI.exe",
    "启动_ComfyUI_备用.bat",
    "使用说明.txt"
)
Get-ChildItem -LiteralPath $destinationRoot -File -Force |
    Where-Object { $publicRootFiles -notcontains $_.Name } |
    ForEach-Object {
        $_.Attributes = $_.Attributes -bor [System.IO.FileAttributes]::Hidden
    }

[pscustomobject]@{
    Result = "OK"
    Source = $root
    Destination = $destinationRoot
    LauncherBuild = [string]($launcherOutput -join "")
    CoreVersion = $coreVersion
    LauncherVersion = $launcherVersion
    EntrypointRepair = [string]($entrypointRepairOutput -join "")
    PortableTextFiles = $portableTextRelativePaths.Count
    Files = $releaseInfo.fileCount
    GiB = [math]::Round(($releaseInfo.bytes / 1GB), 3)
} | ConvertTo-Json -Compress
