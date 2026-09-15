param(
    [string]$Root
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

$sourcePath = Join-Path $toolsDirectory "PortableLauncher.cs"
$iconPath = Join-Path $Root "assets\icons\comfyui-taskbar-large.ico"
$outputPath = Join-Path $Root "启动_ComfyUI.exe"

$compilerCandidates = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$compiler = $compilerCandidates |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($compiler)) {
    throw "未找到 Windows .NET Framework C# 编译器。"
}
foreach ($requiredPath in @($sourcePath, $iconPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "缺少便携启动器构建文件：$requiredPath"
    }
}

$arguments = @(
    "/nologo",
    "/target:winexe",
    "/optimize+",
    "/platform:anycpu",
    ("/win32icon:`"{0}`"" -f $iconPath),
    "/reference:System.dll",
    "/reference:System.Windows.Forms.dll",
    ("/out:`"{0}`"" -f $outputPath),
    ("`"{0}`"" -f $sourcePath)
)

$process = Start-Process `
    -FilePath $compiler `
    -ArgumentList $arguments `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -Wait `
    -PassThru
if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outputPath)) {
    throw "便携启动器编译失败，退出代码：$($process.ExitCode)"
}

[pscustomobject]@{
    Result = "OK"
    Output = $outputPath
    Bytes = (Get-Item -LiteralPath $outputPath).Length
} | ConvertTo-Json -Compress
