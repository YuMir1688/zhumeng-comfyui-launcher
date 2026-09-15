param(
    [Parameter(Mandatory = $true)]
    [string]$Root
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$env:PYTHONDONTWRITEBYTECODE = "1"
$env:PYTHONNOUSERSITE = "1"
$env:NO_ALBUMENTATIONS_UPDATE = "1"
$env:NUMBA_CACHE_DIR = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "ComfyUI-Release-Verify-Numba"

$rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd("\")
$requiredPaths = @(
    "启动_ComfyUI.exe",
    "启动_ComfyUI_备用.bat",
    ".ext\python.exe",
    "main.py",
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
    ".ext\Scripts\.portable\portable_entrypoint_dispatcher.py",
    ".ext\Scripts\.portable\pip.py",
    "custom_nodes\ComfyUI-dapaoAPI\ComfyUI_LLM_Banana\banana_upscale.py",
    "tools\sox\sox.exe",
    "tools\sox\libsox-3.dll",
    "tools\sox\zlib1.dll",
    "tools\sox\LICENSE.GPL.txt",
    "models",
    "release-info.json",
    "release-checksums.sha256",
    "使用说明.txt"
)
$missing = @(
    foreach ($relativePath in $requiredPaths) {
        $path = Join-Path $rootPath $relativePath
        if (-not (Test-Path -LiteralPath $path)) {
            $relativePath
        }
    }
)
if ($missing.Count -gt 0) {
    throw "Required release files are missing: $($missing -join ', ')"
}

$launcherVersionPath = Join-Path $rootPath "tools\launcher-version.json"
$launcherVersionConfig = [System.IO.File]::ReadAllText(
    $launcherVersionPath,
    [System.Text.Encoding]::UTF8
) | ConvertFrom-Json
$launcherSemanticVersion = [string]$launcherVersionConfig.version
if ($launcherSemanticVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "The launcher version manifest contains an invalid version."
}
$expectedExecutableVersion = "$launcherSemanticVersion.0"
$launcherExecutableVersion = (
    Get-Item -LiteralPath (Join-Path $rootPath "启动_ComfyUI.exe")
).VersionInfo.FileVersion
if ([string]$launcherExecutableVersion -ne $expectedExecutableVersion) {
    throw (
        "The launcher executable version does not match launcher-version.json. " +
        "Expected $expectedExecutableVersion, found $launcherExecutableVersion."
    )
}

$reparsePoints = @(
    Get-ChildItem `
        -LiteralPath $rootPath `
        -Force `
        -Recurse `
        -Attributes ReparsePoint `
        -ErrorAction SilentlyContinue
)
if ($reparsePoints.Count -gt 0) {
    throw "The release contains a junction, symlink, or another reparse point."
}

$checksumPath = Join-Path $rootPath "release-checksums.sha256"
$expectedChecksumRelativePaths = @(
    "启动_ComfyUI.exe",
    "启动_ComfyUI_备用.bat",
    "main.py",
    "tools\Launch-ComfyUI.vbs",
    "tools\ComfyUI-Launcher.ps1",
    "tools\ComfyUI-Launcher.xaml",
    "tools\ComfyUI-Launcher.Services.psm1",
    "tools\ComfyUI-Core-Updater.ps1",
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
    [System.IO.File]::ReadAllLines(
        $checksumPath,
        [System.Text.Encoding]::UTF8
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
$checksumPaths = New-Object System.Collections.Generic.List[string]
$checksumPathKeys = @{}
foreach ($line in $checksumLines) {
    if ($line -notmatch "^(?<hash>[a-fA-F0-9]{64}) \*(?<path>.+)$") {
        throw "Invalid checksum entry: $line"
    }
    $expectedHash = $Matches["hash"].ToLowerInvariant()
    $relativePath = $Matches["path"]
    $relativePathKey = $relativePath.ToLowerInvariant()
    if ($checksumPathKeys.ContainsKey($relativePathKey)) {
        throw "Duplicate checksum entry: $relativePath"
    }
    $checksumPathKeys[$relativePathKey] = $true
    $checksumPaths.Add($relativePath)
    $targetPath = [System.IO.Path]::GetFullPath(
        (Join-Path $rootPath $relativePath)
    )
    if (-not $targetPath.StartsWith(
            $rootPath + "\",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
        throw "Unsafe checksum path: $relativePath"
    }
    $actualHash = (
        Get-FileHash -LiteralPath $targetPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "Checksum mismatch: $relativePath"
    }
}
$expectedChecksumKeys = @{}
foreach ($relativePath in $expectedChecksumRelativePaths) {
    $expectedChecksumKeys[$relativePath.ToLowerInvariant()] = $true
}
$missingChecksumEntries = @(
    foreach ($relativePath in $expectedChecksumRelativePaths) {
        if (-not $checksumPathKeys.ContainsKey($relativePath.ToLowerInvariant())) {
            $relativePath
        }
    }
)
$unexpectedChecksumEntries = @(
    foreach ($relativePath in $checksumPaths) {
        if (-not $expectedChecksumKeys.ContainsKey($relativePath.ToLowerInvariant())) {
            $relativePath
        }
    }
)
if ($missingChecksumEntries.Count -gt 0 -or
    $unexpectedChecksumEntries.Count -gt 0 -or
    $checksumPaths.Count -ne $expectedChecksumRelativePaths.Count) {
    throw (
        "Checksum manifest entries do not match the expected release set. " +
        "Missing: $($missingChecksumEntries -join ', '); " +
        "Unexpected: $($unexpectedChecksumEntries -join ', ')"
    )
}

if ([System.IO.File]::Exists((Join-Path $rootPath "启动_ComfyUI.lnk"))) {
    throw "The release still contains the legacy path-bound shortcut."
}

$personalArtifacts = @(
    Get-ChildItem `
        -LiteralPath @(
            (Join-Path $rootPath "input"),
            (Join-Path $rootPath "output")
        ) `
        -Force `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue
)
if ($personalArtifacts.Count -gt 0) {
    throw "The release input or output directory contains files."
}

$tempArtifacts = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $rootPath "temp") `
        -Force `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue
)
if ($tempArtifacts.Count -gt 0) {
    throw "The release temp directory contains files."
}

$privateState = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $rootPath "user") `
        -Force `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $relativePath = $_.FullName.Substring($rootPath.Length + 1)
            $relativePath -notin @(
                "user\default\comfy.settings.json",
                "user\__manager\channels.list",
                "user\__manager\config.ini"
            ) -and
            $relativePath -notlike "user\__manager\cache\*.json"
        }
)
if ($privateState.Count -gt 0) {
    throw "The release user directory contains unexpected private or transient state."
}

$transientArtifacts = @(
    Get-ChildItem `
        -LiteralPath $rootPath `
        -Force `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -in @(
                ".pyc", ".pyo", ".nbc", ".nbi",
                ".log", ".tmp", ".lock", ".bak"
            ) -or
            $_.Name -eq "Thumbs.db"
        }
)
if ($transientArtifacts.Count -gt 0) {
    throw "The release contains caches, logs, locks, backups, or OS metadata."
}

$scriptsDirectory = Join-Path $rootPath ".ext\Scripts"
$pathBoundEntrypoints = @(
    foreach ($path in Get-ChildItem `
        -LiteralPath $scriptsDirectory `
        -Force `
        -File `
        -Recurse `
        -ErrorAction Stop) {
        if ($path.Length -gt 4MB) {
            continue
        }
        $content = [System.Text.Encoding]::ASCII.GetString(
            [System.IO.File]::ReadAllBytes($path.FullName)
        )
        if ($content -match '#![A-Za-z]:[^\r\n]*\\pythonw?(?:\.exe)?') {
            $path.FullName.Substring($rootPath.Length + 1)
        }
    }
)
if ($pathBoundEntrypoints.Count -gt 0) {
    throw (
        "The release contains path-bound Python entrypoints: " +
        ($pathBoundEntrypoints[0..(
            [math]::Min(9, $pathBoundEntrypoints.Count - 1)
        )] -join ", ")
    )
}

$portableLauncherPath = Join-Path `
    $rootPath `
    "tools\PortableEntrypointLauncher.exe"
$portableLauncherHash = (
    Get-FileHash -LiteralPath $portableLauncherPath -Algorithm SHA256
).Hash
$portableDirectory = Join-Path $scriptsDirectory ".portable"
$portableEntrypointSources = @(
    Get-ChildItem `
        -LiteralPath $portableDirectory `
        -Force `
        -File `
        -Filter "*.py" `
        -ErrorAction Stop |
        Where-Object {
            $_.Name -ne "portable_entrypoint_dispatcher.py"
        }
)
if ($portableEntrypointSources.Count -eq 0) {
    throw "The release does not contain repaired portable Python entrypoints."
}
$unsynchronizedEntrypoints = @(
    foreach ($source in $portableEntrypointSources) {
        $executable = Join-Path `
            $scriptsDirectory `
            ($source.BaseName + ".exe")
        if (-not [System.IO.File]::Exists($executable)) {
            $source.BaseName + ".exe (missing)"
            continue
        }
        $executableHash = (
            Get-FileHash -LiteralPath $executable -Algorithm SHA256
        ).Hash
        if ($executableHash -ne $portableLauncherHash) {
            $source.BaseName + ".exe"
        }
    }
)
if ($unsynchronizedEntrypoints.Count -gt 0) {
    throw (
        "Portable Python entrypoint launchers are not synchronized: " +
        (($unsynchronizedEntrypoints | Select-Object -First 10) -join ", ")
    )
}

$portableTextRelativePaths = @(
    ".ext\condabin\micromamba.bat",
    ".ext\condabin\mamba_hook.bat",
    "custom_nodes\ComfyUI-MieNodes\scripts\manual_merge_offloaded_images.py"
)
$driveBoundPathPattern = '(?im)(?<![A-Za-z0-9_])[A-Za-z]:[\\/]'
$pathBoundPortableFiles = @(
    foreach ($relativePath in $portableTextRelativePaths) {
        $content = [System.IO.File]::ReadAllText(
            (Join-Path $rootPath $relativePath),
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

$secretPatterns = @(
    '(?<![A-Za-z0-9])sk-(?:proj-|live-)?[A-Za-z0-9_-]{20,}',
    '(?<![A-Za-z0-9])hf_[A-Za-z0-9]{20,}',
    '(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{20,}',
    '(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,}',
    '(?<![A-Za-z0-9])AIza[0-9A-Za-z_-]{30,}',
    '(?<![A-Z0-9])AKIA[0-9A-Z]{16}(?![A-Z0-9])'
)
$configExtensions = @(
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".ini",
    ".cfg",
    ".env"
)
$sourceExtensions = @(".py", ".js", ".ts")
$secretFindings = New-Object System.Collections.Generic.List[string]
foreach ($scanRoot in @(
    (Join-Path $rootPath "custom_nodes"),
    (Join-Path $rootPath "user"),
    (Join-Path $rootPath "config")
)) {
    foreach ($path in Get-ChildItem `
        -LiteralPath $scanRoot `
        -Force `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue) {
        $extension = $path.Extension.ToLowerInvariant()
        if (($configExtensions -notcontains $extension) -and
            ($sourceExtensions -notcontains $extension)) {
            continue
        }
        if ($path.Length -gt 5MB) {
            continue
        }
        try {
            $text = [System.IO.File]::ReadAllText(
                $path.FullName,
                [System.Text.Encoding]::UTF8
            )
        }
        catch {
            continue
        }

        $relativePath = $path.FullName.Substring($rootPath.Length + 1)
        foreach ($pattern in $secretPatterns) {
            if ([regex]::IsMatch($text, $pattern)) {
                $secretFindings.Add("$relativePath (token pattern)")
                break
            }
        }

        if ($configExtensions -contains $extension) {
            $assignmentPattern = (
                '(?im)["'']?(?<key>api[_-]?key|token|secret|' +
                'password|passwd|client[_-]?secret|access[_-]?key)' +
                '["'']?\s*[:=]\s*["'']?(?<value>[^"''\s,;#}]+)'
            )
            foreach ($match in [regex]::Matches($text, $assignmentPattern)) {
                $value = $match.Groups["value"].Value.Trim()
                $placeholder = (
                    $value -match '^(none|null|false|empty|changeme)$' -or
                    $value -match '^(your|replace|example|sample|test)[_-]' -or
                    $value -match '^(\$\{|<|\{\{)'
                )
                if (-not $placeholder -and $value.Length -ge 20) {
                    $key = $match.Groups["key"].Value
                    $secretFindings.Add("$relativePath ($key)")
                }
            }
        }
    }
}
if ($secretFindings.Count -gt 0) {
    throw (
        "The release may contain a credential in: " +
        (($secretFindings | Select-Object -Unique -First 10) -join ", ")
    )
}

$bundledNodesManifestPath = Join-Path `
    $rootPath `
    "tools\bundled-custom-nodes.json"
$bundledNodesManifest = [System.IO.File]::ReadAllText(
    $bundledNodesManifestPath,
    [System.Text.Encoding]::UTF8
) | ConvertFrom-Json
if ([int]$bundledNodesManifest.schemaVersion -ne 1 -or
    [string]$bundledNodesManifest.policy -ne "protected-release-baseline") {
    throw "The bundled custom-node protection manifest is invalid."
}
$manifestNodes = @($bundledNodesManifest.nodes)
$duplicateManifestDirectories = @(
    $manifestNodes |
        Group-Object -Property directory |
        Where-Object { $_.Count -gt 1 }
)
if ($duplicateManifestDirectories.Count -gt 0) {
    throw "The bundled custom-node protection manifest contains duplicate directory names."
}
$manifestEntries = @(
    foreach ($manifestNode in $manifestNodes) {
        $directory = [string]$manifestNode.directory
        $relativePath = [string]$manifestNode.relativePath
        $initialState = [string]$manifestNode.initialState
        if ([string]::IsNullOrWhiteSpace($directory) -or
            $directory -match '[\\/]' -or
            $directory -in @(".", "..")) {
            throw "The bundled custom-node protection manifest contains an invalid directory."
        }
        $expectedRelativePath = if ($initialState -eq "enabled") {
            "custom_nodes\$directory"
        }
        elseif ($initialState -eq "disabled") {
            "custom_nodes\.disabled\$directory"
        }
        else {
            throw "The bundled custom-node protection manifest contains an invalid state."
        }
        if ($relativePath -cne $expectedRelativePath) {
            throw "The bundled custom-node protection manifest contains an invalid relative path."
        }
        "$initialState|$relativePath|$directory"
    }
)
$actualBundledNodes = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $rootPath "custom_nodes") `
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
$disabledCustomNodesPath = Join-Path $rootPath "custom_nodes\.disabled"
if ([System.IO.Directory]::Exists($disabledCustomNodesPath)) {
    $actualBundledNodes = @(
        $actualBundledNodes
        Get-ChildItem `
            -LiteralPath $disabledCustomNodesPath `
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
$duplicateActualDirectories = @(
    $actualBundledNodes |
        Group-Object -Property directory |
        Where-Object { $_.Count -gt 1 }
)
if ($duplicateActualDirectories.Count -gt 0) {
    throw "A bundled custom-node directory exists in more than one state."
}
$actualEntries = @(
    $actualBundledNodes |
        Sort-Object -Property directory |
        ForEach-Object {
            "$($_.initialState)|$($_.relativePath)|$($_.directory)"
        }
)
if ([int]$bundledNodesManifest.count -ne $manifestNodes.Count -or
    @(
        Compare-Object `
            -ReferenceObject $actualEntries `
            -DifferenceObject $manifestEntries `
            -CaseSensitive
    ).Count -gt 0) {
    throw "The bundled custom-node protection manifest does not match the release."
}

$windowsPowerShell = Join-Path `
    $env:SystemRoot `
    "System32\WindowsPowerShell\v1.0\powershell.exe"
$launcherBootProbeRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ("ComfyUI-Launcher-Boot-Probe-" + [Guid]::NewGuid().ToString("N"))
$launcherBootProcess = $null
$launcherBootChild = $null
try {
    [void][System.IO.Directory]::CreateDirectory($launcherBootProbeRoot)
    [void][System.IO.Directory]::CreateDirectory(
        (Join-Path $launcherBootProbeRoot "tools")
    )
    [void][System.IO.Directory]::CreateDirectory(
        (Join-Path $launcherBootProbeRoot ".ext")
    )
    [void][System.IO.Directory]::CreateDirectory(
        (Join-Path $launcherBootProbeRoot "assets\icons")
    )
    [void][System.IO.Directory]::CreateDirectory(
        (Join-Path $launcherBootProbeRoot "tools\assets\hero")
    )
    [System.IO.File]::Copy(
        (Join-Path $rootPath "启动_ComfyUI.exe"),
        (Join-Path $launcherBootProbeRoot "启动_ComfyUI.exe")
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $launcherBootProbeRoot "main.py"),
        "# launcher boot probe",
        [System.Text.Encoding]::UTF8
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $launcherBootProbeRoot ".ext\python.exe"),
        "probe",
        [System.Text.Encoding]::UTF8
    )
    [System.IO.File]::WriteAllText(
        (Join-Path $launcherBootProbeRoot "tools\ComfyUI-Launcher.ps1"),
        "Start-Sleep -Seconds 30",
        [System.Text.Encoding]::UTF8
    )
    foreach ($relativePath in @(
        "tools\ComfyUI-Launcher.xaml",
        "tools\ComfyUI-Launcher.Services.psm1",
        "tools\ComfyUI-Core-Updater.ps1",
        "tools\ComfyUI-Extension-Worker.ps1",
        "tools\launcher-version.json",
        "assets\icons\comfyui-taskbar-large.ico",
        "tools\assets\hero\comfyui-hero-cover.jpg"
    )) {
        [System.IO.File]::Copy(
            (Join-Path $rootPath $relativePath),
            (Join-Path $launcherBootProbeRoot $relativePath)
        )
    }
    $launcherBootProcess = Start-Process `
        -FilePath (Join-Path $launcherBootProbeRoot "启动_ComfyUI.exe") `
        -WorkingDirectory $launcherBootProbeRoot `
        -PassThru
    if (-not $launcherBootProcess.WaitForExit(8000)) {
        throw "The portable launcher bootstrap did not return after spawning PowerShell."
    }
    if ($launcherBootProcess.ExitCode -ne 0) {
        throw "The portable launcher bootstrap returned a failure exit code."
    }
    $launcherBootChild = Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq "powershell.exe" -and
            [int]$_.ParentProcessId -eq [int]$launcherBootProcess.Id
        } |
        Sort-Object CreationDate -Descending |
        Select-Object -First 1
    if ($null -eq $launcherBootChild) {
        throw "The portable launcher bootstrap did not keep PowerShell alive."
    }
}
finally {
    if ($null -ne $launcherBootChild) {
        Stop-Process `
            -Id ([int]$launcherBootChild.ProcessId) `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if ($null -ne $launcherBootProcess -and
        -not $launcherBootProcess.HasExited) {
        Stop-Process `
            -Id $launcherBootProcess.Id `
            -Force `
            -ErrorAction SilentlyContinue
    }
    if ([System.IO.Directory]::Exists($launcherBootProbeRoot)) {
        Remove-Item `
            -LiteralPath $launcherBootProbeRoot `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
$launcherSelfTest = & $windowsPowerShell `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File (Join-Path $rootPath "tools\ComfyUI-Launcher.ps1") `
    -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw "The release launcher self-test failed."
}
$launcherResult = (
    [string]($launcherSelfTest -join "")
) | ConvertFrom-Json
if ([string]$launcherResult.Result -ne "OK" -or
    [string]$launcherResult.EnvironmentRestored -ne "True" -or
    [string]$launcherResult.NvidiaPreflight -ne "Verified") {
    throw "The release launcher returned an unexpected self-test result."
}

$extensionWorkerSelfTest = & $windowsPowerShell `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File (Join-Path $rootPath "tools\ComfyUI-Extension-Worker.ps1") `
    -Action SelfTest `
    -Root $rootPath
if ($LASTEXITCODE -ne 0) {
    throw "The extension worker self-test failed."
}
$extensionWorkerResult = (
    [string]($extensionWorkerSelfTest -join "")
) | ConvertFrom-Json
if (-not [bool]$extensionWorkerResult.ok -or
    [string]$extensionWorkerResult.action -ne "SelfTest") {
    throw "The extension worker returned an unexpected self-test result."
}

$pythonPath = Join-Path $rootPath ".ext\python.exe"
$pythonCode = "import json, site, sys, torch; print(json.dumps({'torch': torch.__version__, 'cuda': torch.version.cuda, 'available': torch.cuda.is_available(), 'prefix': sys.prefix, 'userSiteEnabled': site.ENABLE_USER_SITE}))"
$pythonProbe = & $pythonPath -s -B -c $pythonCode
if ($LASTEXITCODE -ne 0) {
    throw "The bundled Python or PyTorch probe failed."
}
$pythonResult = (
    [string]($pythonProbe -join "")
) | ConvertFrom-Json
if ([string]$pythonResult.torch -ne "2.11.0+cu128" -or
    [string]$pythonResult.cuda -ne "12.8") {
    throw (
        "The bundled PyTorch runtime is not the reviewed CUDA 12.8 build. " +
        "Found torch $($pythonResult.torch), CUDA $($pythonResult.cuda)."
    )
}
if (-not [bool]$pythonResult.available) {
    throw "CUDA was not available during release verification."
}
$expectedPythonPrefix = [System.IO.Path]::GetFullPath(
    (Join-Path $rootPath ".ext")
).TrimEnd("\")
$actualPythonPrefix = [System.IO.Path]::GetFullPath(
    [string]$pythonResult.prefix
).TrimEnd("\")
if (-not $actualPythonPrefix.Equals(
        $expectedPythonPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or
    [bool]$pythonResult.userSiteEnabled) {
    throw "The bundled Python probe was contaminated by a user-site environment."
}

$visionImportNames = @(
    "cv2",
    "albucore",
    "albumentations",
    "easyocr",
    "rembg"
)
$visionProbeCode = @'
import importlib
import json
import pathlib
import sys

environment = pathlib.Path(sys.prefix).resolve()
result = {}
for name in ('cv2', 'albucore', 'albumentations', 'easyocr', 'rembg'):
    module = importlib.import_module(name)
    module_path = pathlib.Path(module.__file__).resolve()
    if module_path != environment and environment not in module_path.parents:
        raise RuntimeError(f'{name} was imported outside the portable environment')
    result[name] = str(module_path)
print(json.dumps(result, ensure_ascii=True, separators=(',', ':')))
'@
$visionProbeOutput = @(
    & $pythonPath -s -B -c $visionProbeCode 2>&1
)
if ($LASTEXITCODE -ne 0 -or $visionProbeOutput.Count -eq 0) {
    throw "The bundled computer-vision package import probe failed."
}
$visionResult = (
    [string]$visionProbeOutput[-1]
) | ConvertFrom-Json
foreach ($name in $visionImportNames) {
    if ([string]::IsNullOrWhiteSpace([string]$visionResult.$name)) {
        throw "The bundled computer-vision package import probe was incomplete."
    }
}

$entrypointProbes = @(
    [pscustomobject]@{
        Path = Join-Path $scriptsDirectory "pip.exe"
        Arguments = @("--version")
    },
    [pscustomobject]@{
        Path = Join-Path $scriptsDirectory "accelerate.exe"
        Arguments = @("--help")
    },
    [pscustomobject]@{
        Path = Join-Path $scriptsDirectory "hf.exe"
        Arguments = @("--help")
    },
    [pscustomobject]@{
        Path = Join-Path $scriptsDirectory "torchrun.exe"
        Arguments = @("--help")
    }
)
foreach ($probe in $entrypointProbes) {
    if (-not [System.IO.File]::Exists($probe.Path)) {
        throw "Portable Python entrypoint is missing: $($probe.Path)"
    }
    $probeArguments = @($probe.Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Some valid Windows entrypoints (notably torchrun) emit an
        # informational warning on stderr even when they exit successfully.
        $ErrorActionPreference = "Continue"
        $probeOutput = @(& $probe.Path @probeArguments 2>&1)
        $probeExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($probeExitCode -ne 0) {
        throw "Portable Python entrypoint failed: $($probe.Path)"
    }
    if ([System.IO.Path]::GetFileName($probe.Path) -ieq "pip.exe") {
        $pipVersionOutput = [string]($probeOutput -join "`n")
        if ($pipVersionOutput -notmatch (
                '(?i)[\\/]\.ext[\\/]Lib[\\/]site-packages[\\/]pip(?:[\\/]|[ \r\n])'
            )) {
            throw "The portable pip entrypoint resolved outside the release."
        }
    }
}

$knownConflictPath = Join-Path $rootPath "tools\known-pip-conflicts.txt"
$knownConflicts = @(
    [System.IO.File]::ReadAllLines(
        $knownConflictPath,
        [System.Text.Encoding]::UTF8
    ) |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            -not $_.StartsWith("#")
        } |
        Sort-Object -Unique
)
$pipCheckOutput = @(
    & $pythonPath -s -B -m pip check 2>&1 |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_ -ne "No broken requirements found."
        } |
        Sort-Object -Unique
)
$pipCheckDifferences = @(
    Compare-Object `
        -ReferenceObject $knownConflicts `
        -DifferenceObject $pipCheckOutput `
        -CaseSensitive
)
if ($pipCheckDifferences.Count -gt 0) {
    throw "Python dependency conflicts differ from the reviewed allowlist."
}

$modelFileExtensions = @(
    ".safetensors", ".ckpt", ".pt", ".pth", ".bin", ".onnx", ".gguf"
)
$bundledModelFiles = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $rootPath "models") `
        -File `
        -Recurse `
        -Force `
        -ErrorAction Stop |
        Where-Object { $modelFileExtensions -contains $_.Extension.ToLowerInvariant() }
)
if ($bundledModelFiles.Count -gt 0) {
    throw "The model-free release unexpectedly contains bundled model files."
}

$releaseInfoPath = Join-Path $rootPath "release-info.json"
$releaseInfo = [System.IO.File]::ReadAllText(
    $releaseInfoPath,
    [System.Text.Encoding]::UTF8
) | ConvertFrom-Json
$actualFiles = @(
    Get-ChildItem `
        -LiteralPath $rootPath `
        -Force `
        -File `
        -Recurse `
        -ErrorAction Stop
)
if ([long]$releaseInfo.fileCount -ne [long]$actualFiles.Count) {
    throw "release-info.json fileCount does not match the release tree."
}
$actualPayloadBytes = [long]((
    $actualFiles |
        Where-Object {
            $_.Name -notin @(
                "release-info.json",
                "release-checksums.sha256"
            )
        } |
        Measure-Object -Property Length -Sum
).Sum)
if ([long]$releaseInfo.bytes -ne $actualPayloadBytes) {
    throw "release-info.json byte count does not match the release payload."
}

[pscustomobject]@{
    Result = "OK"
    Root = $rootPath
    Launcher = $launcherResult.Result
    LauncherBoot = "OK"
    Controls = $launcherResult.Controls
    ExtensionWorker = "OK"
    Torch = $pythonResult.torch
    Cuda = $pythonResult.cuda
    Checksums = $checksumLines.Count
    InputFiles = 0
    OutputFiles = 0
    PrivateState = 0
    TransientState = 0
    Secrets = 0
    ReparsePoints = 0
    PortableEntrypoints = $entrypointProbes.Count
    PortableEntrypointStubs = $portableEntrypointSources.Count
    PortableTextFiles = $portableTextRelativePaths.Count
    VisionImports = $visionImportNames.Count
    KnownPipConflicts = $knownConflicts.Count
    BundledModels = $bundledModelFiles.Count
} | ConvertTo-Json -Compress
