param(
    [string]$Root,
    [switch]$ForceRebuildLauncher
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$toolsDirectory = [System.IO.Path]::GetFullPath(
    (Split-Path -Parent $MyInvocation.MyCommand.Path)
)
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = [System.IO.Path]::GetFullPath((Join-Path $toolsDirectory ".."))
}
else {
    $Root = [System.IO.Path]::GetFullPath($Root)
}

$sourcePath = Join-Path $toolsDirectory "PortableEntrypointLauncher.cs"
$repairScript = Join-Path $toolsDirectory "Repair-Portable-Entrypoints.py"
$launcherPath = Join-Path $toolsDirectory "PortableEntrypointLauncher.exe"
$pythonPath = Join-Path $Root ".ext\python.exe"

foreach ($requiredPath in @($sourcePath, $repairScript, $pythonPath)) {
    if (-not [System.IO.File]::Exists($requiredPath)) {
        throw "Portable entrypoint repair file is missing: $requiredPath"
    }
}

$launcherNeedsBuild = (
    $ForceRebuildLauncher.IsPresent -or
    -not [System.IO.File]::Exists($launcherPath)
)
if (-not $launcherNeedsBuild) {
    $sourceTimestamp = (
        Get-Item -LiteralPath $sourcePath
    ).LastWriteTimeUtc
    $launcherTimestamp = (
        Get-Item -LiteralPath $launcherPath
    ).LastWriteTimeUtc
    $launcherNeedsBuild = $sourceTimestamp -gt $launcherTimestamp
}
if (-not $launcherNeedsBuild) {
    try {
        $null = [System.Reflection.AssemblyName]::GetAssemblyName($launcherPath)
    }
    catch {
        $launcherNeedsBuild = $true
    }
}

if ($launcherNeedsBuild) {
    $compilerCandidates = @(
        (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
        (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
    )
    $compiler = $compilerCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($compiler)) {
        throw "Windows .NET Framework C# compiler was not found."
    }

    $temporaryDirectory = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("comfyui-portable-entrypoint-" + [guid]::NewGuid().ToString("N"))
    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    $temporaryLauncherPath = Join-Path `
        $temporaryDirectory `
        "PortableEntrypointLauncher.exe"
    try {
        $arguments = @(
            "/nologo",
            "/target:exe",
            "/optimize+",
            "/platform:anycpu",
            "/reference:System.dll",
            ("/out:`"{0}`"" -f $temporaryLauncherPath),
            ("`"{0}`"" -f $sourcePath)
        )
        $compileProcess = Start-Process `
            -FilePath $compiler `
            -ArgumentList $arguments `
            -WorkingDirectory $toolsDirectory `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        if ($compileProcess.ExitCode -ne 0 -or
            -not [System.IO.File]::Exists($temporaryLauncherPath)) {
            throw (
                "Portable entrypoint launcher compilation failed: " +
                $compileProcess.ExitCode
            )
        }
        [System.IO.File]::Copy(
            $temporaryLauncherPath,
            $launcherPath,
            $true
        )
    }
    finally {
        if ([System.IO.Directory]::Exists($temporaryDirectory)) {
            [System.IO.Directory]::Delete($temporaryDirectory, $true)
        }
    }
}

$repairOutput = & $pythonPath -s -B $repairScript `
    --root $Root `
    --launcher $launcherPath
if ($LASTEXITCODE -ne 0) {
    throw "Portable Python entrypoint repair failed."
}

$repairResult = (
    [string]($repairOutput -join "")
) | ConvertFrom-Json
$repairResult | Add-Member `
    -NotePropertyName launcherCompiled `
    -NotePropertyValue ([bool]$launcherNeedsBuild)
$repairResult | ConvertTo-Json -Compress
