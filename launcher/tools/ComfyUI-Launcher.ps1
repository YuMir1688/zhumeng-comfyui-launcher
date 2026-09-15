param(
    [switch]$SelfTest,
    [string]$RenderPreview,
    [ValidateSet(
        "home",
        "advanced",
        "network",
        "update",
        "extensions",
        "install-extension",
        "folders",
        "console"
    )]
    [string]$PreviewPage = "home",
    [switch]$GenerateInventory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:suppressSettingsPersistence = (
    $SelfTest -or
    -not [string]::IsNullOrWhiteSpace($RenderPreview)
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

if ($null -eq ("ComfyUILauncher.NativeDwm" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace ComfyUILauncher
{
    public static class NativeDwm
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern int SetCurrentProcessExplicitAppUserModelID(
            string appId
        );

        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(
            IntPtr hwnd,
            int attribute,
            ref int value,
            int valueSize
        );

    }
}
"@
}

$script:appUserModelResult = [ComfyUILauncher.NativeDwm]::SetCurrentProcessExplicitAppUserModelID(
    "ComfyUI.DesktopLauncher"
)

function Set-LauncherDarkTitleBar {
    param([System.Windows.Window]$TargetWindow)

    try {
        $interop = New-Object System.Windows.Interop.WindowInteropHelper($TargetWindow)
        $handle = $interop.Handle
        if ($handle -eq [IntPtr]::Zero) {
            $handle = $interop.EnsureHandle()
        }

        $enabled = 1
        $result = [ComfyUILauncher.NativeDwm]::DwmSetWindowAttribute(
            $handle,
            20,
            [ref]$enabled,
            4
        )
        if ($result -ne 0) {
            [void][ComfyUILauncher.NativeDwm]::DwmSetWindowAttribute(
                $handle,
                19,
                [ref]$enabled,
                4
            )
        }

        # Windows 11: BORDER_COLOR, CAPTION_COLOR, TEXT_COLOR as COLORREF values.
        $borderColor = 0x00342A1D
        $captionColor = 0x0018120C
        $textColor = 0x00F8F6F3
        [void][ComfyUILauncher.NativeDwm]::DwmSetWindowAttribute(
            $handle,
            34,
            [ref]$borderColor,
            4
        )
        [void][ComfyUILauncher.NativeDwm]::DwmSetWindowAttribute(
            $handle,
            35,
            [ref]$captionColor,
            4
        )
        [void][ComfyUILauncher.NativeDwm]::DwmSetWindowAttribute(
            $handle,
            36,
            [ref]$textColor,
            4
        )
    }
    catch {
        # Older Windows versions may not expose all DWM attributes.
    }
}

$scriptDir = [System.IO.Path]::GetFullPath((Split-Path -Parent $MyInvocation.MyCommand.Path))
$root = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
$xamlPath = Join-Path $scriptDir "ComfyUI-Launcher.xaml"
$pythonPath = Join-Path $root ".ext\python.exe"
$mainPath = Join-Path $root "main.py"
$iconPath = Join-Path $root "assets\icons\comfyui-taskbar-large.ico"
$logoPath = Join-Path $root "assets\icons\comfyui-rounded.png"
$brandWatermarkPath = Join-Path $root "tools\assets\branding\zhixuetang-mark-white.png"
$heroPosterPath = Join-Path $root "tools\assets\hero\comfyui-hero-cover.jpg"
$servicesPath = Join-Path $scriptDir "ComfyUI-Launcher.Services.psm1"
$coreUpdaterPath = Join-Path $scriptDir "ComfyUI-Core-Updater.ps1"
$extensionWorkerPath = Join-Path $scriptDir "ComfyUI-Extension-Worker.ps1"
$launcherVersionPath = Join-Path $scriptDir "launcher-version.json"
$settingsPath = Join-Path $root "user\launcher\settings.json"
$coreVersionPath = Join-Path $root "comfyui_version.py"

foreach ($requiredPath in @(
    $xamlPath,
    $pythonPath,
    $mainPath,
    $iconPath,
    $logoPath,
    $brandWatermarkPath,
    $heroPosterPath,
    $servicesPath,
    $coreUpdaterPath,
    $extensionWorkerPath,
    $launcherVersionPath,
    $coreVersionPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Required launcher file is missing: $requiredPath"
    }
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
Import-Module $servicesPath -Force

function Save-LauncherSettingsIfAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Settings
    )

    if ($script:suppressSettingsPersistence) {
        return
    }

    Save-LauncherSettings -Path $Path -Settings $Settings
}

$launcherVersionInfo = [System.IO.File]::ReadAllText($launcherVersionPath, $utf8) | ConvertFrom-Json
$launcherSettings = Read-LauncherSettings $settingsPath
if (-not [System.IO.File]::Exists($settingsPath)) {
    Save-LauncherSettingsIfAllowed -Path $settingsPath -Settings $launcherSettings
}

$xamlText = [System.IO.File]::ReadAllText($xamlPath, $utf8)
$xml = New-Object System.Xml.XmlDocument
$xml.PreserveWhitespace = $true
$xml.LoadXml($xamlText)
$xmlReader = New-Object System.Xml.XmlNodeReader($xml)
$window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
$xmlReader.Close()
$window.Add_SourceInitialized({ Set-LauncherDarkTitleBar $script:window })

$controlNames = @(
    "TopStatusPill", "TopStatusDot", "TopStatusText", "BottomStatusText",
    "HomeBrandWatermark",
    "GpuText", "ModeText", "AddressText", "ConsoleBox",
    "NavHome", "NavAdvanced", "NavNetwork", "NavFolders", "NavConsole", "UpdateNavBadge",
    "PageHome", "PageAdvanced", "PageNetwork", "PageFolders", "PageConsole",
    "BtnStart", "BtnStop", "BtnRestart", "BtnHomeCustomNodes", "BtnHomeModels", "BtnHomeOutput",
    "HeroCard", "HeroVisualHost", "HeroPoster",
    "HomeNoticeBorder", "HomeNoticeDot", "HomeNoticeText", "BtnHomeNotice",
    "WorkflowShowcaseCard", "WorkflowShowcaseImageSurface", "WorkflowShowcaseTitle",
    "WorkflowShowcaseSubtitle", "WorkflowShowcasePrimaryTag", "WorkflowShowcaseSecondaryTag",
    "WorkflowShowcaseDot1", "WorkflowShowcaseDot2", "WorkflowShowcaseDot3",
    "WorkflowShowcaseDot4", "WorkflowShowcaseCounter", "BtnWorkflowPrev", "BtnWorkflowNext",
    "BtnAdvancedStart", "BtnCleanTemp", "BtnConsoleOpenWeb", "BtnExportRunLog",
    "PresetCombo", "PortBox", "AutoBrowserCheck", "AutoTempCleanCheck",
    "EffectiveNetworkHeaderText", "BtnNetworkTab", "BtnUpdateTab",
    "BtnExtensionsTab", "BtnInstallExtensionTab",
    "NetworkPanel", "UpdatePanel", "ExtensionsPanel", "InstallExtensionPanel",
    "HfModeCombo", "HfCustomUrlBox", "GithubModeCombo", "GithubPrefixBox",
    "PypiModeCombo", "PypiCustomUrlBox", "ProxyModeCombo", "ProxyCustomPanel",
    "ProxyAddressBox", "ProxyPortBox", "EffectiveNetworkText", "BtnSaveNetwork",
    "BtnTestAllNetworks", "NetworkTestProgress", "HfTestStatusText", "BtnTestHf",
    "GithubTestStatusText", "BtnTestGithub", "PypiTestStatusText", "BtnTestPypi",
    "UpdateTestStatusText", "BtnTestUpdateServer", "NetworkDiagnosticHintText",
    "BtnCopyNetworkDiagnostics", "AutoUpdateCheck", "UpdateChannelCombo", "LastUpdateCheckText",
    "LauncherCurrentVersionText", "InventoryProgress", "InventoryStatusText",
    "BtnInventoryScan", "BtnCancelInventory", "BtnCheckCoreUpdate",
    "UpdateCheckProgress", "CoreCurrentVersionText", "CoreLatestVersionText",
    "CorePublishedText", "CoreUpdateStatusText", "CoreReleaseNotesText",
    "BtnOpenCoreRelease", "BtnIgnoreCoreVersion", "BtnInstallCoreUpdate",
    "InstalledExtensionsSearchBox", "InstalledExtensionsFilterCombo",
    "BtnRefreshInstalledExtensions", "InstalledExtensionsGrid",
    "InstalledExtensionsProgress", "InstalledExtensionsStatusText",
    "BtnEnableInstalledExtension", "BtnDisableInstalledExtension",
    "BtnOpenInstalledExtensionFolder", "BtnRemoveInstalledExtension",
    "ExtensionCatalogSearchBox", "BtnRefreshExtensionCatalog",
    "ExtensionCatalogGrid", "ExtensionCatalogProgress", "ExtensionCatalogStatusText",
    "BtnOpenExtensionSource", "BtnInstallSelectedExtension",
    "BtnFolderRoot", "BtnFolderModels", "BtnFolderNodes", "BtnFolderInput",
    "BtnFolderOutput", "BtnFolderUser"
)

foreach ($controlName in $controlNames) {
    $control = $window.FindName($controlName)
    if ($null -eq $control) {
        throw "XAML control is missing: $controlName"
    }
    Set-Variable -Name $controlName -Value $control -Scope Script
}

$window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($iconPath)))
$brandWatermark = New-Object System.Windows.Media.Imaging.BitmapImage
$brandWatermark.BeginInit()
$brandWatermark.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$brandWatermark.DecodePixelWidth = 256
$brandWatermark.UriSource = New-Object System.Uri($brandWatermarkPath)
$brandWatermark.EndInit()
$brandWatermark.Freeze()
$HomeBrandWatermark.Source = $brandWatermark

$heroPosterBitmap = New-Object System.Windows.Media.Imaging.BitmapImage
$heroPosterBitmap.BeginInit()
$heroPosterBitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$heroPosterBitmap.DecodePixelWidth = 2400
$heroPosterBitmap.UriSource = New-Object System.Uri($heroPosterPath)
$heroPosterBitmap.EndInit()
$heroPosterBitmap.Freeze()
$HeroPoster.Source = $heroPosterBitmap

$brushConverter = New-Object System.Windows.Media.BrushConverter

function Get-Brush {
    param([string]$Color)
    return $script:brushConverter.ConvertFromString($Color)
}

function Get-UiText {
    param(
        [string]$Key,
        [object[]]$FormatArgs = @()
    )

    $value = [string]$script:window.FindResource($Key)
    if ($FormatArgs.Count -gt 0) {
        return [string]::Format($value, $FormatArgs)
    }
    return $value
}

function Set-LauncherStatus {
    param(
        [string]$Text,
        [string]$Color = "#7F8B97"
    )

    $script:TopStatusText.Text = $Text
    $script:BottomStatusText.Text = $Text
    $script:TopStatusDot.Fill = Get-Brush $Color

    $normalizedColor = $Color.ToUpperInvariant()
    switch ($normalizedColor) {
        "#59E391" {
            $script:TopStatusPill.Background = Get-Brush "#10261A"
            $script:TopStatusPill.BorderBrush = Get-Brush "#28563C"
            $script:TopStatusText.Foreground = Get-Brush "#CDF2D8"
            break
        }
        "#FF6475" {
            $script:TopStatusPill.Background = Get-Brush "#281419"
            $script:TopStatusPill.BorderBrush = Get-Brush "#5B2933"
            $script:TopStatusText.Foreground = Get-Brush "#FFD0D6"
            break
        }
        "#FFCC66" {
            $script:TopStatusPill.Background = Get-Brush "#2A2111"
            $script:TopStatusPill.BorderBrush = Get-Brush "#5A4521"
            $script:TopStatusText.Foreground = Get-Brush "#FFE3A5"
            break
        }
        "#FFB454" {
            $script:TopStatusPill.Background = Get-Brush "#2A1D10"
            $script:TopStatusPill.BorderBrush = Get-Brush "#5A3D20"
            $script:TopStatusText.Foreground = Get-Brush "#FFD6A2"
            break
        }
        "#ECFF3D" {
            $script:TopStatusPill.Background = Get-Brush "#202711"
            $script:TopStatusPill.BorderBrush = Get-Brush "#455325"
            $script:TopStatusText.Foreground = Get-Brush "#EEFF8B"
            break
        }
        default {
            $script:TopStatusPill.Background = Get-Brush "#121A22"
            $script:TopStatusPill.BorderBrush = Get-Brush "#2A3945"
            $script:TopStatusText.Foreground = Get-Brush "#C5D0D8"
        }
    }
}

function Append-Console {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return
    }

    $followTail = (
        $script:ConsoleBox.ExtentHeight -le 0 -or
        ($script:ConsoleBox.VerticalOffset + $script:ConsoleBox.ViewportHeight) -ge
            ($script:ConsoleBox.ExtentHeight - 24)
    )

    if ($script:ConsoleBox.Text.Length -gt 500000) {
        $script:ConsoleBox.Text = $script:ConsoleBox.Text.Substring(100000)
    }

    $script:ConsoleBox.AppendText($Text)
    if (-not $Text.EndsWith([Environment]::NewLine) -and -not $Text.EndsWith("`n")) {
        $script:ConsoleBox.AppendText([Environment]::NewLine)
    }
    if ($followTail) {
        $script:ConsoleBox.ScrollToEnd()
    }
}

function Append-LauncherLog {
    param(
        [string]$Key,
        [object[]]$FormatArgs = @()
    )

    $stamp = [DateTime]::Now.ToString("HH:mm:ss")
    Append-Console ("[{0}] {1}" -f $stamp, (Get-UiText $Key $FormatArgs))
}

function Show-RunLogExportNotification {
    param(
        [string]$Message,
        [System.Windows.MessageBoxImage]$Image
    )

    if ($null -ne $script:runLogExportNotificationHandler) {
        & $script:runLogExportNotificationHandler $Message $Image
        return
    }

    [void][System.Windows.MessageBox]::Show(
        $script:window,
        $Message,
        (Get-UiText "DialogTitle"),
        [System.Windows.MessageBoxButton]::OK,
        $Image
    )
}

function Get-RunLogExportTargetPath {
    if ($null -ne $script:runLogExportPathProvider) {
        return [string](& $script:runLogExportPathProvider)
    }

    $saveDialog = New-Object Microsoft.Win32.SaveFileDialog
    $saveDialog.Title = "导出运行日志"
    $saveDialog.Filter = "文本文件 (*.txt)|*.txt|所有文件 (*.*)|*.*"
    $saveDialog.FilterIndex = 1
    $saveDialog.DefaultExt = ".txt"
    $saveDialog.AddExtension = $true
    $saveDialog.OverwritePrompt = $true
    $saveDialog.CheckPathExists = $true
    $saveDialog.FileName = "ComfyUI-运行日志-" + [DateTime]::Now.ToString("yyyyMMdd-HHmmss") + ".txt"

    $desktopPath = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::DesktopDirectory
    )
    if ([System.IO.Directory]::Exists($desktopPath)) {
        $saveDialog.InitialDirectory = $desktopPath
    }

    $dialogResult = $saveDialog.ShowDialog($script:window)
    if ($dialogResult -ne $true) {
        return ""
    }
    return [string]$saveDialog.FileName
}

function Export-CurrentRunLog {
    Read-PendingLogs
    $currentLog = [string]$script:ConsoleBox.Text
    if ([string]::IsNullOrWhiteSpace($currentLog)) {
        Show-RunLogExportNotification `
            -Message "当前没有可导出的运行日志。" `
            -Image ([System.Windows.MessageBoxImage]::Information)
        return
    }

    $targetPath = Get-RunLogExportTargetPath
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        return
    }

    try {
        $savedPath = Export-LauncherRunLog `
            -Text $currentLog `
            -Path $targetPath
        Show-RunLogExportNotification `
            -Message ("运行日志已导出。`n`n" + $savedPath) `
            -Image ([System.Windows.MessageBoxImage]::Information)
    }
    catch {
        $safeReason = ConvertTo-LauncherSafeDiagnosticText $_.Exception.Message
        Show-RunLogExportNotification `
            -Message ("导出运行日志失败。`n`n" + $safeReason) `
            -Image ([System.Windows.MessageBoxImage]::Error)
    }
}

function Save-LastStartupFailureLog {
    param([string]$Reason = "")

    try {
        $logDirectory = Join-Path $script:root "user\launcher\logs"
        if (-not [System.IO.Directory]::Exists($logDirectory)) {
            [void][System.IO.Directory]::CreateDirectory($logDirectory)
        }
        $logPath = Join-Path $logDirectory "last-startup-error.log"
        $parts = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace($Reason)) {
            $parts.Add("启动失败原因：" + $Reason)
        }
        if ($null -ne $script:ConsoleBox -and
            -not [string]::IsNullOrWhiteSpace([string]$script:ConsoleBox.Text)) {
            $parts.Add([string]$script:ConsoleBox.Text)
        }
        if ($parts.Count -eq 0) {
            $parts.Add("ComfyUI 在网页服务就绪前退出，但没有返回文本日志。")
        }
        [void](Export-LauncherRunLog `
            -Text ($parts -join ([Environment]::NewLine + [Environment]::NewLine)) `
            -Path $logPath)
        return $logPath
    }
    catch {
        return ""
    }
}

function Update-HeroVisualClip {
    if ($null -eq $script:HeroVisualHost -or
        $script:HeroVisualHost.ActualWidth -le 0 -or
        $script:HeroVisualHost.ActualHeight -le 0) {
        return
    }
    $script:HeroVisualHost.Clip = New-Object System.Windows.Media.RectangleGeometry(
        (New-Object System.Windows.Rect(
            0,
            0,
            $script:HeroVisualHost.ActualWidth,
            $script:HeroVisualHost.ActualHeight
        )),
        21,
        21
    )
}

function Show-LauncherPage {
    param(
        [System.Windows.FrameworkElement]$Page,
        [System.Windows.Controls.Button]$NavigationButton
    )

    foreach ($candidatePage in @(
        $script:PageHome,
        $script:PageAdvanced,
        $script:PageNetwork,
        $script:PageFolders,
        $script:PageConsole
    )) {
        $candidatePage.Visibility = [System.Windows.Visibility]::Collapsed
    }
    $Page.Visibility = [System.Windows.Visibility]::Visible

    foreach ($candidateButton in @(
        $script:NavHome,
        $script:NavAdvanced,
        $script:NavNetwork,
        $script:NavFolders,
        $script:NavConsole
    )) {
        $candidateButton.Background = Get-Brush "#00000000"
        $candidateButton.BorderBrush = Get-Brush "#00000000"
        $candidateButton.Foreground = Get-Brush "#8493A0"
    }

    $NavigationButton.Background = Get-Brush "#17232D"
    $NavigationButton.BorderBrush = Get-Brush "#2B3D4B"
    $NavigationButton.Foreground = Get-Brush "#E8FF42"

}

function Get-ComboTag {
    param([System.Windows.Controls.ComboBox]$ComboBox)

    if ($null -eq $ComboBox.SelectedItem) {
        return ""
    }
    return [string]$ComboBox.SelectedItem.Tag
}

function Set-ComboTag {
    param(
        [System.Windows.Controls.ComboBox]$ComboBox,
        [string]$Tag
    )

    foreach ($item in $ComboBox.Items) {
        if ([string]$item.Tag -eq $Tag) {
            $ComboBox.SelectedItem = $item
            return
        }
    }
}

function Get-CoreVersion {
    $text = [System.IO.File]::ReadAllText($script:coreVersionPath, $script:utf8)
    $match = [regex]::Match($text, '__version__\s*=\s*"([^"]+)"')
    if (-not $match.Success) {
        return "未知"
    }
    return $match.Groups[1].Value
}

function Show-NetworkSection {
    param(
        [ValidateSet(
            "network",
            "update",
            "extensions",
            "install-extension"
        )]
        [string]$Section
    )

    $script:NetworkPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $script:UpdatePanel.Visibility = [System.Windows.Visibility]::Collapsed
    $script:ExtensionsPanel.Visibility = [System.Windows.Visibility]::Collapsed
    $script:InstallExtensionPanel.Visibility = [System.Windows.Visibility]::Collapsed
    foreach ($button in @(
        $script:BtnNetworkTab,
        $script:BtnUpdateTab,
        $script:BtnExtensionsTab,
        $script:BtnInstallExtensionTab
    )) {
        $button.Background = Get-Brush "#101820"
        $button.BorderBrush = Get-Brush "#21313D"
        $button.Foreground = Get-Brush "#8795A2"
    }

    switch ($Section) {
        "update" {
            $script:UpdatePanel.Visibility = [System.Windows.Visibility]::Visible
            $activeButton = $script:BtnUpdateTab
        }
        "extensions" {
            $script:ExtensionsPanel.Visibility = [System.Windows.Visibility]::Visible
            $activeButton = $script:BtnExtensionsTab
            if (-not $script:installedExtensionsLoaded) {
                Start-ExtensionWorkerAction -Action "ListInstalled"
            }
        }
        "install-extension" {
            $script:InstallExtensionPanel.Visibility = [System.Windows.Visibility]::Visible
            $activeButton = $script:BtnInstallExtensionTab
            if (-not $script:extensionCatalogLoaded) {
                Start-ExtensionWorkerAction `
                    -Action "SearchCatalog" `
                    -Query $script:ExtensionCatalogSearchBox.Text.Trim()
            }
        }
        default {
            $script:NetworkPanel.Visibility = [System.Windows.Visibility]::Visible
            $activeButton = $script:BtnNetworkTab
        }
    }
    $activeButton.Background = Get-Brush "#1B2833"
    $activeButton.BorderBrush = Get-Brush "#334856"
    $activeButton.Foreground = Get-Brush "#E8FF42"
}

function Update-NetworkEditorVisibility {
    $hfMode = Get-ComboTag $script:HfModeCombo
    $githubMode = Get-ComboTag $script:GithubModeCombo
    $pypiMode = Get-ComboTag $script:PypiModeCombo
    $proxyMode = Get-ComboTag $script:ProxyModeCombo

    $script:HfCustomUrlBox.Visibility = if ($hfMode -eq "custom") {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
    $script:GithubPrefixBox.Visibility = if ($githubMode -in @("accelerator", "custom")) {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
    $script:PypiCustomUrlBox.Visibility = if ($pypiMode -eq "custom") {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
    $script:ProxyCustomPanel.Visibility = if ($proxyMode -eq "custom") {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
}

function Get-NetworkSettingsFromControls {
    $settings = Merge-LauncherSettings $script:launcherSettings
    $settings.network.huggingFace.mode = Get-ComboTag $script:HfModeCombo
    $settings.network.huggingFace.customUrl = $script:HfCustomUrlBox.Text.Trim()
    $settings.network.github.downloadMode = Get-ComboTag $script:GithubModeCombo
    $settings.network.github.acceleratorPrefix = $script:GithubPrefixBox.Text.Trim()
    $settings.network.pypi.mode = Get-ComboTag $script:PypiModeCombo
    $settings.network.pypi.customUrl = $script:PypiCustomUrlBox.Text.Trim()
    $settings.network.proxy.mode = Get-ComboTag $script:ProxyModeCombo
    $settings.network.proxy.address = $script:ProxyAddressBox.Text.Trim()

    $proxyPort = 0
    [void][int]::TryParse($script:ProxyPortBox.Text.Trim(), [ref]$proxyPort)
    $settings.network.proxy.port = $proxyPort

    if ($settings.network.huggingFace.mode -eq "custom" -and
        -not (Test-LauncherHttpUrl $settings.network.huggingFace.customUrl)) {
        throw "Hugging Face 自定义镜像地址无效，请填写完整的 HTTP 或 HTTPS URL。"
    }
    if ($settings.network.github.downloadMode -in @("accelerator", "custom") -and
        -not (Test-LauncherHttpUrl $settings.network.github.acceleratorPrefix)) {
        throw "GitHub 下载加速前缀无效，请填写完整的 HTTP 或 HTTPS URL。"
    }
    if ($settings.network.pypi.mode -eq "custom" -and
        -not (Test-LauncherHttpUrl $settings.network.pypi.customUrl)) {
        throw "PyPI 自定义镜像地址无效，请填写完整的 HTTP 或 HTTPS URL。"
    }
    if ($settings.network.proxy.mode -eq "custom" -and
        $null -eq (Get-LauncherProxyUri $settings)) {
        throw "自定义代理地址或端口无效，端口范围应为 1 到 65535。"
    }
    return $settings
}

function Get-EffectiveNetworkSummary {
    param([object]$Settings = $script:launcherSettings)

    $hfLabel = switch ([string]$Settings.network.huggingFace.mode) {
        "mirror" { "HF Mirror" }
        "custom" { "HF 自定义" }
        "official" { "HF 官方" }
        default { "HF 自动/官方" }
    }
    $githubLabel = switch ([string]$Settings.network.github.downloadMode) {
        "accelerator" { "GitHub 加速" }
        "custom" { "GitHub 自定义" }
        "official" { "GitHub 官方" }
        default { "GitHub 自动（官方优先）" }
    }
    $pypiLabel = switch ([string]$Settings.network.pypi.mode) {
        "aliyun" { "PyPI 阿里云" }
        "tsinghua" { "PyPI 清华" }
        "ustc" { "PyPI 中科大" }
        "custom" { "PyPI 自定义" }
        "official" { "PyPI 官方" }
        default { "PyPI 自动/官方" }
    }
    $proxyLabel = switch ([string]$Settings.network.proxy.mode) {
        "none" { "不使用代理" }
        "custom" { "自定义代理" }
        default { "系统代理" }
    }
    return "$hfLabel · $githubLabel · $pypiLabel · $proxyLabel"
}

function Refresh-NetworkSummary {
    $summary = Get-EffectiveNetworkSummary
    $script:EffectiveNetworkText.Text = $summary
    $script:EffectiveNetworkHeaderText.Text = "实际生效：" + $summary
}

function Initialize-NetworkControls {
    Set-ComboTag $script:HfModeCombo ([string]$script:launcherSettings.network.huggingFace.mode)
    $script:HfCustomUrlBox.Text = [string]$script:launcherSettings.network.huggingFace.customUrl
    Set-ComboTag $script:GithubModeCombo ([string]$script:launcherSettings.network.github.downloadMode)
    $script:GithubPrefixBox.Text = [string]$script:launcherSettings.network.github.acceleratorPrefix
    Set-ComboTag $script:PypiModeCombo ([string]$script:launcherSettings.network.pypi.mode)
    $script:PypiCustomUrlBox.Text = [string]$script:launcherSettings.network.pypi.customUrl
    Set-ComboTag $script:ProxyModeCombo ([string]$script:launcherSettings.network.proxy.mode)
    $script:ProxyAddressBox.Text = [string]$script:launcherSettings.network.proxy.address
    $script:ProxyPortBox.Text = if ([int]$script:launcherSettings.network.proxy.port -gt 0) {
        [string]$script:launcherSettings.network.proxy.port
    }
    else {
        ""
    }
    Update-NetworkEditorVisibility
    Refresh-NetworkSummary
}

function Save-NetworkConfiguration {
    try {
        $settings = Get-NetworkSettingsFromControls
        $script:launcherSettings = $settings
        $script:settingsGeneration++
        $script:networkResults = @{}
        Save-LauncherSettingsIfAllowed -Path $script:settingsPath -Settings $script:launcherSettings
        Refresh-NetworkSummary
        foreach ($statusControl in @(
            $script:HfTestStatusText,
            $script:GithubTestStatusText,
            $script:PypiTestStatusText,
            $script:UpdateTestStatusText
        )) {
            $statusControl.Text = "未检测"
            $statusControl.Foreground = Get-Brush "#7F8B97"
        }
        $script:NetworkDiagnosticHintText.Text = "配置已保存；从下一个网络任务和下一次 ComfyUI 启动开始生效。"
        $script:NetworkDiagnosticHintText.Foreground = Get-Brush "#79D99D"
        Append-Console "[NETWORK] Configuration saved. New tasks will use the updated settings."
    }
    catch {
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            $_.Exception.Message,
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
    }
}

function Get-NetworkTestDefinition {
    param([ValidateSet("hf", "github", "pypi", "update")][string]$Kind)

    switch ($Kind) {
        "hf" {
            return [pscustomobject]@{
                Name = "Hugging Face"
                Uri = (Get-LauncherHuggingFaceEndpoint $script:launcherSettings).TrimEnd("/") + "/api/models/gpt2"
                StatusControl = $script:HfTestStatusText
                Button = $script:BtnTestHf
            }
        }
        "github" {
            return [pscustomobject]@{
                Name = "GitHub"
                Uri = "https://api.github.com/repos/Comfy-Org/ComfyUI"
                StatusControl = $script:GithubTestStatusText
                Button = $script:BtnTestGithub
            }
        }
        "pypi" {
            return [pscustomobject]@{
                Name = "PyPI"
                Uri = Get-LauncherPypiIndexUrl $script:launcherSettings
                StatusControl = $script:PypiTestStatusText
                Button = $script:BtnTestPypi
            }
        }
        default {
            return [pscustomobject]@{
                Name = "版本服务器"
                Uri = Get-LauncherGithubReleaseApiUrl $script:launcherSettings
                StatusControl = $script:UpdateTestStatusText
                Button = $script:BtnTestUpdateServer
            }
        }
    }
}

function Start-NetworkTest {
    param([ValidateSet("hf", "github", "pypi", "update")][string]$Kind)

    foreach ($existingJob in $script:networkProbeJobs) {
        if ($existingJob.Kind -eq $Kind) {
            return
        }
    }

    $definition = Get-NetworkTestDefinition $Kind
    try {
        $probe = Start-LauncherNetworkProbe `
            -Name $definition.Name `
            -Uri $definition.Uri `
            -Settings $script:launcherSettings `
            -TimeoutSeconds 12
        [void]$script:networkProbeJobs.Add([pscustomobject]@{
            Kind = $Kind
            OpId = [Guid]::NewGuid().ToString("N")
            SettingsGeneration = $script:settingsGeneration
            CompletionClaimed = $false
            Definition = $definition
            Probe = $probe
        })
        $createdJob = $script:networkProbeJobs[$script:networkProbeJobs.Count - 1]
        $script:networkCurrentOps[$Kind] = $createdJob.OpId
        $definition.StatusControl.Text = "正在检测"
        $definition.StatusControl.Foreground = Get-Brush "#FFD47C"
        $definition.Button.IsEnabled = $false
        $script:BtnTestAllNetworks.IsEnabled = $false
        $script:NetworkTestProgress.Visibility = [System.Windows.Visibility]::Visible
    }
    catch {
        $definition.StatusControl.Text = ConvertTo-LauncherNetworkError $_
        $definition.StatusControl.Foreground = Get-Brush "#FF8D99"
    }
}

function Start-AllNetworkTests {
    $script:networkResults = @{}
    foreach ($kind in @("hf", "github", "pypi", "update")) {
        Start-NetworkTest $kind
    }
}

function Update-HomeNotice {
    if ($null -ne $script:coreUpdateJob) {
        $progressMessage = [string]$script:CoreUpdateStatusText.Text
        if ([string]::IsNullOrWhiteSpace($progressMessage)) {
            $progressMessage = "ComfyUI 核心更新正在进行"
        }
        $script:HomeNoticeText.Text = $progressMessage
        $script:HomeNoticeDot.Fill = Get-Brush "#6F85FF"
        $script:HomeNoticeBorder.Visibility = [System.Windows.Visibility]::Visible
        $script:homeNoticeTarget = "update"
        return
    }

    $failedResult = $null
    foreach ($result in $script:networkResults.Values) {
        if (-not $result.Success) {
            $failedResult = $result
            break
        }
    }

    if ($null -ne $failedResult) {
        $script:HomeNoticeText.Text = "网络检测失败 · " + $failedResult.Name + "：" + $failedResult.Message
        $script:HomeNoticeDot.Fill = Get-Brush "#FF8D99"
        $script:HomeNoticeBorder.Visibility = [System.Windows.Visibility]::Visible
        $script:homeNoticeTarget = "network"
        return
    }
    if ($script:coreUpdateAvailable) {
        $script:HomeNoticeText.Text = "发现 ComfyUI 新版本 " + $script:latestCoreVersion
        $script:HomeNoticeDot.Fill = Get-Brush "#E8FF42"
        $script:HomeNoticeBorder.Visibility = [System.Windows.Visibility]::Visible
        $script:homeNoticeTarget = "update"
        return
    }

    $script:HomeNoticeBorder.Visibility = [System.Windows.Visibility]::Collapsed
    $script:homeNoticeTarget = ""
}

function Complete-NetworkTests {
    for ($index = $script:networkProbeJobs.Count - 1; $index -ge 0; $index--) {
        $job = $script:networkProbeJobs[$index]
        if (-not $job.Probe.Task.IsCompleted) {
            continue
        }
        if ($job.CompletionClaimed) {
            continue
        }
        $job.CompletionClaimed = $true

        $success = $false
        $message = "当前网络无法访问"
        $latency = [Math]::Max(0, [int]$job.Probe.Stopwatch.ElapsedMilliseconds)
        try {
            $response = $job.Probe.Task.GetAwaiter().GetResult()
            try {
                $statusCode = [int]$response.StatusCode
                if ($statusCode -ge 200 -and $statusCode -lt 400) {
                    $success = $true
                    $message = "连接成功 · ${latency} ms"
                }
                else {
                    $message = "服务器返回异常 · HTTP $statusCode"
                }
            }
            finally {
                $response.Dispose()
            }
        }
        catch {
            $message = ConvertTo-LauncherNetworkError $_.Exception
        }
        finally {
            $job.Probe.Stopwatch.Stop()
            $job.Probe.Request.Dispose()
            $job.Probe.Client.Dispose()
        }

        $isCurrentResult = (
            -not $script:isClosing -and
            $job.SettingsGeneration -eq $script:settingsGeneration -and
            $script:networkCurrentOps.ContainsKey($job.Kind) -and
            [string]$script:networkCurrentOps[$job.Kind] -eq [string]$job.OpId
        )
        if ($isCurrentResult) {
            $job.Definition.StatusControl.Text = $message
            $job.Definition.StatusControl.Foreground = Get-Brush $(if ($success) { "#79D99D" } else { "#FF8D99" })
            $script:networkResults[$job.Kind] = [pscustomobject]@{
                Name = $job.Definition.Name
                Uri = $job.Definition.Uri
                Success = $success
                Message = $message
                Latency = $latency
                CheckedAt = [DateTimeOffset]::Now
                SettingsGeneration = $job.SettingsGeneration
                OpId = $job.OpId
            }
            [void]$script:networkCurrentOps.Remove($job.Kind)
        }
        if (-not $script:isClosing) {
            $job.Definition.Button.IsEnabled = $true
        }
        [void]$script:networkProbeJobs.RemoveAt($index)
    }

    if ($script:networkProbeJobs.Count -eq 0) {
        if (-not $script:isClosing) {
            $script:NetworkTestProgress.Visibility = [System.Windows.Visibility]::Collapsed
            $script:BtnTestAllNetworks.IsEnabled = $true
        }
    }
    if (-not $script:isClosing) {
        Update-HomeNotice
    }
}

function Copy-NetworkDiagnostics {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("ComfyUI 桌面版网络诊断")
    $lines.Add("时间: " + [DateTimeOffset]::Now.ToString("yyyy-MM-dd HH:mm:ss zzz"))
    $lines.Add("配置: " + (Get-EffectiveNetworkSummary))
    $lines.Add("代理模式: " + [string]$script:launcherSettings.network.proxy.mode)
    $lines.Add("")

    foreach ($kind in @("hf", "github", "pypi", "update")) {
        if ($script:networkResults.ContainsKey($kind)) {
            $result = $script:networkResults[$kind]
            $lines.Add(("{0}: {1}" -f $result.Name, $result.Message))
            $lines.Add(("  URL: {0}" -f $result.Uri))
        }
        else {
            $definition = Get-NetworkTestDefinition $kind
            $lines.Add(("{0}: 未检测" -f $definition.Name))
        }
    }

    $diagnosticText = ConvertTo-LauncherSafeDiagnosticText ($lines -join [Environment]::NewLine)
    [System.Windows.Clipboard]::SetText($diagnosticText)
    $script:NetworkDiagnosticHintText.Text = "诊断信息已复制，敏感字段已过滤。"
    $script:NetworkDiagnosticHintText.Foreground = Get-Brush "#79D99D"
}

function Test-OnlineCoreMaintenanceEnabled {
    # The updater performs process-state checks, transactional core backups,
    # dependency rollback preparation and an isolated health check before it
    # commits a maintenance operation.
    return $true
}

function Initialize-UpdateControls {
    $script:LauncherCurrentVersionText.Text = [string]$script:launcherVersionInfo.version
    $script:CoreCurrentVersionText.Text = $script:coreVersion
    $script:AutoUpdateCheck.IsChecked = [bool]$script:launcherSettings.updates.autoCheck
    Set-ComboTag $script:UpdateChannelCombo ([string]$script:launcherSettings.updates.channel)

    if (-not [string]::IsNullOrWhiteSpace([string]$script:launcherSettings.updates.lastCheckUtc)) {
        $lastCheck = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse(
            [string]$script:launcherSettings.updates.lastCheckUtc,
            [ref]$lastCheck
        )) {
            $script:LastUpdateCheckText.Text = "上次检查 " + $lastCheck.ToLocalTime().ToString("MM-dd HH:mm")
        }
    }

    $cachedVersion = [string]$script:launcherSettings.updates.cachedCoreVersion
    if (-not [string]::IsNullOrWhiteSpace($cachedVersion)) {
        $script:CoreLatestVersionText.Text = $cachedVersion
        $script:latestCoreVersion = $cachedVersion
        $script:latestCoreReleaseUrl = [string]$script:launcherSettings.updates.cachedCoreReleaseUrl
        $script:BtnOpenCoreRelease.IsEnabled = -not [string]::IsNullOrWhiteSpace($script:latestCoreReleaseUrl)
        Update-CoreUpdateAvailability
    }

    $cachedPublishedAt = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse(
        [string]$script:launcherSettings.updates.cachedCorePublishedAt,
        [ref]$cachedPublishedAt
    )) {
        $script:CorePublishedText.Text = $cachedPublishedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm")
    }

    $script:InventoryStatusText.Text = (
        "按当前 ComfyUI 版本补齐或恢复内置 Python 依赖，并执行隔离健康检查。"
    )
    $script:BtnInventoryScan.Content = "修复整合包"
    $script:BtnInventoryScan.IsEnabled = $true
}

function Update-CoreUpdateAvailability {
    $candidate = [string]$script:latestCoreVersion
    $available = Test-LauncherVersionNewer $script:coreVersion $candidate
    $ignored = ([string]$script:launcherSettings.updates.ignoredCoreVersion -eq $candidate)
    $script:coreUpdateAvailable = ($available -and -not $ignored)
    $script:UpdateNavBadge.Visibility = if ($script:coreUpdateAvailable) {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
    $script:BtnIgnoreCoreVersion.IsEnabled = $available
    $updateInProgress = (
        $null -ne $script:coreUpdateJob -or
        $null -ne $script:dependencyRepairJob
    )
    $script:BtnCheckCoreUpdate.IsEnabled = -not $updateInProgress
    if ($updateInProgress) {
        $script:BtnInstallCoreUpdate.Content = "正在更新…"
        $script:BtnInstallCoreUpdate.IsEnabled = $false
    }
    elseif ($available) {
        if (Test-OnlineCoreMaintenanceEnabled) {
            $script:BtnInstallCoreUpdate.Content = "立即更新"
            $script:BtnInstallCoreUpdate.IsEnabled = $true
        }
        else {
            $script:BtnInstallCoreUpdate.Content = "立即更新"
            $script:BtnInstallCoreUpdate.IsEnabled = $false
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($candidate)) {
        $script:BtnInstallCoreUpdate.Content = "检查后可更新"
        $script:BtnInstallCoreUpdate.IsEnabled = $false
    }
    else {
        $script:BtnInstallCoreUpdate.Content = "已是最新"
        $script:BtnInstallCoreUpdate.IsEnabled = $false
        $script:BtnIgnoreCoreVersion.IsEnabled = $false
    }

    if ($available) {
        if (-not (Test-OnlineCoreMaintenanceEnabled)) {
            $script:CoreUpdateStatusText.Text = (
                "发现新版本。请获取整合包维护版，当前环境不会被在线改写。"
            )
        }
        elseif ($ignored) {
            $script:CoreUpdateStatusText.Text = "此版本已忽略，但仍可直接更新。"
        }
        else {
            $script:CoreUpdateStatusText.Text = "发现新版本，可直接执行安全更新。"
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $script:CoreUpdateStatusText.Text = "当前已经是最新版本。"
    }
    Update-HomeNotice
}

function Start-CoreUpdateCheck {
    if ($null -ne $script:updateRequest) {
        return
    }

    try {
        $uri = Get-LauncherGithubReleaseApiUrl $script:launcherSettings
        $script:updateRequest = Start-LauncherJsonRequest `
            -Uri $uri `
            -Settings $script:launcherSettings `
            -TimeoutSeconds 15
        $updateOpId = [Guid]::NewGuid().ToString("N")
        $script:updateRequest | Add-Member -NotePropertyName OpId -NotePropertyValue $updateOpId
        $script:updateRequest | Add-Member -NotePropertyName SettingsGeneration -NotePropertyValue $script:settingsGeneration
        $script:updateRequest | Add-Member -NotePropertyName CompletionClaimed -NotePropertyValue $false
        $script:currentUpdateOpId = $updateOpId
        $script:UpdateCheckProgress.Visibility = [System.Windows.Visibility]::Visible
        $script:CoreUpdateStatusText.Text = "正在检查官方版本..."
        $script:BtnCheckCoreUpdate.IsEnabled = $false
    }
    catch {
        $script:CoreUpdateStatusText.Text = ConvertTo-LauncherNetworkError $_.Exception
        $script:CoreUpdateStatusText.Foreground = Get-Brush "#FF8D99"
    }
}

function Complete-CoreUpdateCheck {
    if ($null -eq $script:updateRequest -or -not $script:updateRequest.Task.IsCompleted) {
        return
    }
    if ($script:updateRequest.CompletionClaimed) {
        return
    }
    $script:updateRequest.CompletionClaimed = $true

    $completedRequest = $script:updateRequest
    $isCurrentResult = (
        -not $script:isClosing -and
        [string]$completedRequest.OpId -eq [string]$script:currentUpdateOpId -and
        [int]$completedRequest.SettingsGeneration -eq $script:settingsGeneration
    )
    if (-not $isCurrentResult) {
        try { $completedRequest.Stopwatch.Stop() } catch {}
        try { $completedRequest.Client.Dispose() } catch {}
        $script:updateRequest = $null
        $script:currentUpdateOpId = ""
        if (-not $script:isClosing) {
            $script:UpdateCheckProgress.Visibility = [System.Windows.Visibility]::Collapsed
            $script:BtnCheckCoreUpdate.IsEnabled = $true
            $script:CoreUpdateStatusText.Text = "设置已变化，请重新检查版本。"
        }
        return
    }

    try {
        $json = $completedRequest.Task.GetAwaiter().GetResult()
        $data = $json | ConvertFrom-Json
        $release = $data
        if ([string]$script:launcherSettings.updates.channel -eq "preview") {
            $release = @($data | Where-Object { -not $_.draft })[0]
        }
        if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string]$release.tag_name)) {
            throw "版本服务器没有返回有效的 Release 信息。"
        }

        $tag = [string]$release.tag_name
        $script:latestCoreVersion = $tag.TrimStart("v", "V")
        $script:latestCoreReleaseUrl = [string]$release.html_url
        $script:CoreLatestVersionText.Text = $script:latestCoreVersion
        $script:CorePublishedText.Text = if ($null -ne $release.published_at) {
            ([DateTimeOffset]$release.published_at).ToLocalTime().ToString("yyyy-MM-dd HH:mm")
        }
        else {
            "—"
        }
        $notes = [string]$release.body
        if ([string]::IsNullOrWhiteSpace($notes)) {
            $notes = "此版本没有提供更新说明。"
        }
        if ($notes.Length -gt 6000) {
            $notes = $notes.Substring(0, 6000) + [Environment]::NewLine + "……"
        }
        $script:CoreReleaseNotesText.Text = $notes
        $script:BtnOpenCoreRelease.IsEnabled = -not [string]::IsNullOrWhiteSpace($script:latestCoreReleaseUrl)

        $script:launcherSettings.updates.lastCheckUtc = [DateTimeOffset]::UtcNow.ToString("o")
        $script:launcherSettings.updates.cachedCoreVersion = $script:latestCoreVersion
        $script:launcherSettings.updates.cachedCorePublishedAt = [string]$release.published_at
        $script:launcherSettings.updates.cachedCoreReleaseUrl = $script:latestCoreReleaseUrl
        Save-LauncherSettingsIfAllowed -Path $script:settingsPath -Settings $script:launcherSettings
        $script:LastUpdateCheckText.Text = "刚刚完成检查"
        $script:UpdateTestStatusText.Text = "连接成功 · " + [int]$completedRequest.Stopwatch.ElapsedMilliseconds + " ms"
        $script:UpdateTestStatusText.Foreground = Get-Brush "#79D99D"
        $script:networkResults["update"] = [pscustomobject]@{
            Name = "版本服务器"
            Uri = $completedRequest.Uri
            Success = $true
            Message = $script:UpdateTestStatusText.Text
            Latency = [int]$completedRequest.Stopwatch.ElapsedMilliseconds
            CheckedAt = [DateTimeOffset]::Now
            SettingsGeneration = $completedRequest.SettingsGeneration
            OpId = $completedRequest.OpId
        }
        Update-CoreUpdateAvailability
        Append-Console ("[UPDATE] Core version check: local={0}, remote={1}" -f $script:coreVersion, $script:latestCoreVersion)
    }
    catch {
        $reason = ConvertTo-LauncherNetworkError $_.Exception
        if ($_.Exception.Message -like "版本服务器*") {
            $reason = $_.Exception.Message
        }
        $script:CoreUpdateStatusText.Text = "检查失败：" + $reason
        $script:CoreUpdateStatusText.Foreground = Get-Brush "#FF8D99"
        $script:UpdateTestStatusText.Text = $reason
        $script:UpdateTestStatusText.Foreground = Get-Brush "#FF8D99"
        $script:networkResults["update"] = [pscustomobject]@{
            Name = "版本服务器"
            Uri = $completedRequest.Uri
            Success = $false
            Message = $reason
            Latency = [int]$completedRequest.Stopwatch.ElapsedMilliseconds
            CheckedAt = [DateTimeOffset]::Now
            SettingsGeneration = $completedRequest.SettingsGeneration
            OpId = $completedRequest.OpId
        }
        Update-HomeNotice
    }
    finally {
        $completedRequest.Stopwatch.Stop()
        $completedRequest.Client.Dispose()
        $script:updateRequest = $null
        $script:currentUpdateOpId = ""
        $script:UpdateCheckProgress.Visibility = [System.Windows.Visibility]::Collapsed
        $script:BtnCheckCoreUpdate.IsEnabled = $true
    }
}

function Get-CoreUpdateArchiveUrls {
    if ([string]::IsNullOrWhiteSpace([string]$script:latestCoreVersion)) {
        return @()
    }
    $tag = [string]$script:latestCoreVersion
    if (-not $tag.StartsWith("v", [System.StringComparison]::OrdinalIgnoreCase)) {
        $tag = "v" + $tag
    }
    if ($tag -notmatch "^v\d+\.\d+\.\d+(?:[-.][A-Za-z0-9.]+)?$") {
        return @()
    }
    $officialUrl = (
        "https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/{0}.zip" -f
        [System.Uri]::EscapeDataString($tag)
    )
    $mode = [string]$script:launcherSettings.network.github.downloadMode
    $urls = New-Object System.Collections.Generic.List[string]
    if ($mode -in @("accelerator", "custom")) {
        $configuredUrl = ConvertTo-LauncherGithubDownloadUrl `
            -OriginalUrl $officialUrl `
            -Settings $script:launcherSettings
        if (-not [string]::IsNullOrWhiteSpace($configuredUrl)) {
            $urls.Add($configuredUrl)
        }
        $urls.Add($officialUrl)
    }
    elseif ($mode -eq "official") {
        $urls.Add($officialUrl)
    }
    else {
        # Official GitHub is always attempted first.  The two HTTPS download
        # accelerators are fallbacks for networks where github.com/API works
        # but codeload.github.com cannot be resolved or times out.
        $urls.Add($officialUrl)
        $urls.Add("https://gh-proxy.com/" + $officialUrl)
        $urls.Add("https://ghfast.top/" + $officialUrl)
    }
    return @($urls | Select-Object -Unique)
}

function Get-CoreUpdateArchiveUrl {
    $urls = @(Get-CoreUpdateArchiveUrls)
    if ($urls.Count -eq 0) {
        return ""
    }
    return [string]$urls[0]
}

function Start-CoreUpdateInstall {
    if (-not (Test-OnlineCoreMaintenanceEnabled)) {
        $script:CoreUpdateStatusText.Text = (
            "当前便携发布版不在线改写核心或内置 Python；请获取整合包维护版。"
        )
        $script:CoreUpdateStatusText.Foreground = Get-Brush "#FFCC66"
        return
    }

    if ($null -ne $script:coreUpdateJob -or
        $null -ne $script:dependencyRepairJob -or
        (
            $null -ne $script:extensionJob -and
            $script:extensionJobIsMutation
        )) {
        return
    }
    if (-not (Test-LauncherVersionNewer $script:coreVersion $script:latestCoreVersion)) {
        $script:CoreUpdateStatusText.Text = "当前没有可安装的新版本。"
        return
    }

    $sourceUrls = @(Get-CoreUpdateArchiveUrls)
    if ($sourceUrls.Count -eq 0) {
        $script:CoreUpdateStatusText.Text = "无法生成可信的官方源码地址，请重新检查版本。"
        $script:CoreUpdateStatusText.Foreground = Get-Brush "#FF8D99"
        return
    }

    $wasRunning = Test-ComfyUIRunning
    if ($wasRunning) {
        $stopAnswer = [System.Windows.MessageBox]::Show(
            $script:window,
            "ComfyUI 当前正在运行。更新核心前必须先停止服务，更新成功后会自动恢复运行。是否继续？",
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($stopAnswer -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }
        $stopConfirmed = Stop-ComfyUI
        if (-not $stopConfirmed -or (Test-ComfyUIRunning)) {
            $script:CoreUpdateStatusText.Text = "ComfyUI 未能完全停止，更新已取消。"
            $script:CoreUpdateStatusText.Foreground = Get-Brush "#FF8D99"
            return
        }
    }

    try {
        $driveRoot = [System.IO.Path]::GetPathRoot($script:root)
        $driveInfo = New-Object System.IO.DriveInfo($driveRoot)
        if ($driveInfo.AvailableFreeSpace -lt 512MB) {
            throw (
                "磁盘空间不足：安全更新至少需要 512 MB 可用空间，当前仅有 {0:N0} MB。" -f
                ($driveInfo.AvailableFreeSpace / 1MB)
            )
        }

        $confirmationText = @(
            "即将更新 ComfyUI 核心："
            ""
            ("当前版本：{0}" -f $script:coreVersion)
            ("目标版本：{0}" -f $script:latestCoreVersion)
            ("发布页面：{0}" -f $script:latestCoreReleaseUrl)
            ""
            "更新器会先下载并验证官方固定版本源码，创建上一版本核心备份，再安装依赖并执行隔离健康检查。"
            "models、input、output、custom_nodes、user、tools、assets、.ext 不会被核心文件替换。"
            ""
            "是否开始更新？"
        ) -join [Environment]::NewLine
        $answer = [System.Windows.MessageBox]::Show(
            $script:window,
            $confirmationText,
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            if ($wasRunning) {
                Start-ComfyUI
            }
            return
        }

        $updateId = [Guid]::NewGuid().ToString("N")
        $stateRoot = Join-Path $script:root "user\launcher\state"
        $logRoot = Join-Path $script:root "user\launcher\logs"
        $workRoot = Join-Path $script:root (".cache\launcher\updates\" + $updateId)
        $backupsRoot = Join-Path $script:root ".cache\launcher\backups"
        foreach ($directoryPath in @(
            $stateRoot,
            $logRoot,
            [System.IO.Path]::GetDirectoryName($workRoot),
            $backupsRoot
        )) {
            if (-not [System.IO.Directory]::Exists($directoryPath)) {
                [void][System.IO.Directory]::CreateDirectory($directoryPath)
            }
        }

        $requestPath = Join-Path $stateRoot ("core-update-request-" + $updateId + ".json")
        $statusPath = Join-Path $stateRoot ("core-update-status-" + $updateId + ".json")
        $logPath = Join-Path $logRoot (
            "core-update-" + [DateTime]::Now.ToString("yyyyMMdd-HHmmss") + ".log"
        )
        $request = [ordered]@{
            schemaVersion = 1
            root = $script:root
            currentVersion = $script:coreVersion
            targetVersion = $script:latestCoreVersion
            sourceUrl = [string]$sourceUrls[0]
            sourceUrls = @($sourceUrls)
            releaseUrl = $script:latestCoreReleaseUrl
            pythonPath = $script:pythonPath
            pypiIndexUrl = Get-LauncherPypiIndexUrl $script:launcherSettings
            proxyMode = [string]$script:launcherSettings.network.proxy.mode
            proxyAddress = [string]$script:launcherSettings.network.proxy.address
            proxyPort = [int]$script:launcherSettings.network.proxy.port
            statusPath = $statusPath
            workRoot = $workRoot
            backupsRoot = $backupsRoot
            logPath = $logPath
        }
        Save-LauncherTextAtomic `
            -Path $requestPath `
            -Text ($request | ConvertTo-Json -Depth 6)

        $script:coreUpdateRequestPath = $requestPath
        $script:coreUpdateStatusPath = $statusPath
        $script:coreUpdateLastStatusJson = ""
        $script:coreUpdateLastStage = ""
        $script:coreUpdateRestartAfter = $wasRunning
        $script:coreUpdateJob = Start-Job `
            -FilePath $script:coreUpdaterPath `
            -ArgumentList @($requestPath)

        $script:UpdateCheckProgress.IsIndeterminate = $true
        $script:UpdateCheckProgress.Visibility = [System.Windows.Visibility]::Visible
        $script:CoreUpdateStatusText.Text = "正在准备安全更新…"
        $script:CoreUpdateStatusText.Foreground = Get-Brush "#AAB5BE"
        $script:BtnCheckCoreUpdate.IsEnabled = $false
        $script:BtnIgnoreCoreVersion.IsEnabled = $false
        $script:BtnInstallCoreUpdate.Content = "正在更新…"
        $script:BtnInstallCoreUpdate.IsEnabled = $false
        Set-LauncherStatus "正在更新 ComfyUI 核心" "#6F85FF"
        Append-Console (
            "[UPDATE] Core update started: {0} -> {1}" -f
            $script:coreVersion,
            $script:latestCoreVersion
        )
        Update-HomeNotice
    }
    catch {
        if ($wasRunning -and -not (Test-ComfyUIRunning)) {
            Start-ComfyUI
        }
        $script:CoreUpdateStatusText.Text = "无法开始更新：" + $_.Exception.Message
        $script:CoreUpdateStatusText.Foreground = Get-Brush "#FF8D99"
        Update-CoreUpdateAvailability
    }
}

function Complete-CoreUpdateInstall {
    if ($null -eq $script:coreUpdateJob) {
        return
    }

    $status = $null
    if (-not [string]::IsNullOrWhiteSpace($script:coreUpdateStatusPath) -and
        [System.IO.File]::Exists($script:coreUpdateStatusPath)) {
        try {
            $statusJson = [System.IO.File]::ReadAllText(
                $script:coreUpdateStatusPath,
                $script:utf8
            )
            if (-not [string]::IsNullOrWhiteSpace($statusJson)) {
                $status = $statusJson | ConvertFrom-Json
                if ($statusJson -ne $script:coreUpdateLastStatusJson) {
                    $script:coreUpdateLastStatusJson = $statusJson
                    $script:CoreUpdateStatusText.Text = [string]$status.message
                    $script:CoreUpdateStatusText.Foreground = Get-Brush "#AAB5BE"
                    $percent = [int]$status.percent
                    if ($percent -ge 0 -and $percent -le 100) {
                        $script:UpdateCheckProgress.IsIndeterminate = $false
                        $script:UpdateCheckProgress.Minimum = 0
                        $script:UpdateCheckProgress.Maximum = 100
                        $script:UpdateCheckProgress.Value = $percent
                    }
                    else {
                        $script:UpdateCheckProgress.IsIndeterminate = $true
                    }
                    if ([string]$status.stage -ne $script:coreUpdateLastStage) {
                        $script:coreUpdateLastStage = [string]$status.stage
                        Append-Console (
                            "[UPDATE] {0}: {1}" -f
                            [string]$status.stage,
                            [string]$status.message
                        )
                    }
                    Update-HomeNotice
                }
            }
        }
        catch {
            # Atomic status writes can briefly race with antivirus scanners; retry on the next tick.
        }
    }

    $jobState = [string]$script:coreUpdateJob.State
    if ($jobState -notin @("Completed", "Failed", "Stopped")) {
        return
    }

    $jobOutput = ""
    $jobErrors = @()
    try {
        $jobOutput = Receive-Job `
            -Job $script:coreUpdateJob `
            -ErrorVariable jobErrors `
            -ErrorAction SilentlyContinue |
            Out-String
    }
    catch {
        $jobErrors += $_
    }
    try {
        Remove-Job -Job $script:coreUpdateJob -Force -ErrorAction SilentlyContinue
    }
    catch {
    }
    $script:coreUpdateJob = $null

    $script:UpdateCheckProgress.Visibility = [System.Windows.Visibility]::Collapsed
    $script:BtnCheckCoreUpdate.IsEnabled = $true
    $script:BtnIgnoreCoreVersion.IsEnabled = $true
    $restartAfter = [bool]$script:coreUpdateRestartAfter
    $script:coreUpdateRestartAfter = $false

    $success = ($null -ne $status -and [bool]$status.completed -and [bool]$status.success)
    if ($success) {
        $script:coreVersion = Get-CoreVersion
        $script:CoreCurrentVersionText.Text = $script:coreVersion
        $script:CoreLatestVersionText.Text = $script:latestCoreVersion
        $script:coreUpdateAvailable = $false
        $script:UpdateNavBadge.Visibility = [System.Windows.Visibility]::Collapsed
        $script:launcherSettings.updates.ignoredCoreVersion = ""
        $script:launcherSettings.updates.cachedCoreVersion = $script:coreVersion
        Save-LauncherSettingsIfAllowed -Path $script:settingsPath -Settings $script:launcherSettings
        $script:BtnInstallCoreUpdate.Content = "已是最新"
        $script:BtnInstallCoreUpdate.IsEnabled = $false
        $script:CoreUpdateStatusText.Text = (
            "更新完成：ComfyUI 核心 " + $script:coreVersion +
            "，启动健康检查已通过。"
        )
        $script:CoreUpdateStatusText.Foreground = Get-Brush "#79D99D"
        Set-LauncherStatus (Get-UiText "StatusReady") "#7F8B97"
        Append-Console (
            "[UPDATE] Core update completed. Backup: " + [string]$status.backupPath
        )
        if ($restartAfter) {
            Start-ComfyUI
        }
        else {
            [void][System.Windows.MessageBox]::Show(
                $script:window,
                (
                    "ComfyUI 核心已成功更新到 " + $script:coreVersion +
                    "，隔离启动健康检查已通过。"
                ),
                (Get-UiText "DialogTitle"),
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
        }
    }
    else {
        $reason = "更新进程异常结束。"
        $rollbackText = ""
        if ($null -ne $status) {
            if (-not [string]::IsNullOrWhiteSpace([string]$status.message)) {
                $reason = [string]$status.message
            }
            if ([bool]$status.rollbackPerformed) {
                $rollbackText = " 上一版本核心已自动恢复。"
            }
        }
        elseif ($jobErrors.Count -gt 0) {
            $reason = [string]$jobErrors[0]
        }
        elseif (-not [string]::IsNullOrWhiteSpace($jobOutput)) {
            $reason = $jobOutput.Trim()
        }
        $script:CoreUpdateStatusText.Text = $reason + $rollbackText
        $script:CoreUpdateStatusText.Foreground = Get-Brush "#FF8D99"
        $script:BtnInstallCoreUpdate.Content = "重试更新"
        $stillAvailable = (
            Test-LauncherVersionNewer $script:coreVersion $script:latestCoreVersion
        )
        $script:BtnInstallCoreUpdate.IsEnabled = (
            $stillAvailable -and (Test-OnlineCoreMaintenanceEnabled)
        )
        $script:BtnIgnoreCoreVersion.IsEnabled = $stillAvailable
        Set-LauncherStatus (Get-UiText "StatusReady") "#7F8B97"
        Append-Console ("[UPDATE] Core update failed: " + $reason + $rollbackText)
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            $reason + $rollbackText,
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
        if ($restartAfter -and -not (Test-ComfyUIRunning)) {
            Start-ComfyUI
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:coreUpdateRequestPath) -and
        [System.IO.File]::Exists($script:coreUpdateRequestPath)) {
        try {
            [System.IO.File]::Delete($script:coreUpdateRequestPath)
        }
        catch {
        }
    }
    $script:coreUpdateRequestPath = ""
    Update-HomeNotice
}

function Set-ExtensionUiBusy {
    param(
        [bool]$Busy,
        [string]$Action = ""
    )

    $catalogAction = $Action -in @(
        "SearchCatalog",
        "RefreshCatalog",
        "Install",
        "Restore"
    )
    $installedAction = $Action -in @(
        "ListInstalled",
        "Enable",
        "Disable",
        "Remove",
        "Restore"
    )
    if (-not $Busy) {
        $catalogAction = $true
        $installedAction = $true
    }

    $script:ExtensionCatalogProgress.Visibility = if ($Busy -and $catalogAction) {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }
    $script:InstalledExtensionsProgress.Visibility = if ($Busy -and $installedAction) {
        [System.Windows.Visibility]::Visible
    }
    else {
        [System.Windows.Visibility]::Collapsed
    }

    # A single worker serializes all extension operations. Disable controls on
    # both pages so a click cannot be silently dropped or race a path mutation.
    foreach ($control in @(
        $script:BtnRefreshExtensionCatalog,
        $script:BtnRefreshInstalledExtensions,
        $script:InstalledExtensionsSearchBox,
        $script:InstalledExtensionsFilterCombo
    )) {
        $control.IsEnabled = -not $Busy
    }
    # Read-only catalog searches are debounced and serialized by the worker.
    # Keep the editor enabled while they run so typing and IME composition do
    # not lose focus between consecutive queries. Mutations still lock it.
    $script:ExtensionCatalogSearchBox.IsEnabled = (
        -not $Busy -or
        $Action -in @("SearchCatalog", "RefreshCatalog", "ListInstalled")
    )

    if ($Busy) {
        $script:BtnEnableInstalledExtension.IsEnabled = $false
        $script:BtnDisableInstalledExtension.IsEnabled = $false
        $script:BtnRemoveInstalledExtension.IsEnabled = $false
        $script:BtnOpenInstalledExtensionFolder.IsEnabled = $false
        $script:BtnInstallSelectedExtension.IsEnabled = $false
        if ($Action -in @("Install", "Restore")) {
            $script:BtnInstallSelectedExtension.Content = "处理中…"
        }
    }
    else {
        Update-InstalledExtensionActions
        Update-ExtensionCatalogActions
    }
}

function Get-ExtensionPropertyValue {
    param(
        [object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function ConvertTo-ExtensionBoolean {
    param(
        [object]$Value,
        [bool]$DefaultValue = $false
    )

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($Value -is [string]) {
        $parsed = $false
        if ([bool]::TryParse([string]$Value, [ref]$parsed)) {
            return $parsed
        }
    }
    return $DefaultValue
}

function ConvertTo-ExtensionWorkerResult {
    param([object]$Result)

    if ($null -eq $Result) {
        throw "扩展工作进程返回了空结果。"
    }
    $okProperty = $Result.PSObject.Properties["ok"]
    if ($null -eq $okProperty -or $okProperty.Value -isnot [bool]) {
        throw "扩展工作进程返回结果缺少有效的 ok 字段。"
    }

    return [pscustomobject][ordered]@{
        ok = [bool]$okProperty.Value
        code = [string](
            Get-ExtensionPropertyValue $Result "code" "E_UNKNOWN"
        )
        message = [string](
            Get-ExtensionPropertyValue $Result "message" ""
        )
        data = Get-ExtensionPropertyValue $Result "data" $null
    }
}

function Test-ExtensionCatalogQueryCurrent {
    param([string]$CompletedQuery)

    $currentQuery = ([string]$script:ExtensionCatalogSearchBox.Text).Trim()
    return [string]::Equals(
        ([string]$CompletedQuery).Trim(),
        $currentQuery,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function ConvertTo-ExtensionItemArray {
    param(
        [object]$Data,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Installed", "Catalog")]
        [string]$Kind
    )

    if ($null -eq $Data) {
        return @()
    }
    $itemsProperty = $Data.PSObject.Properties["items"]
    if ($null -eq $itemsProperty -or $null -eq $itemsProperty.Value) {
        return @()
    }

    $normalizedItems = @(
        foreach ($item in @($itemsProperty.Value)) {
            if ($null -eq $item) {
                continue
            }

            $id = [string](Get-ExtensionPropertyValue $item "Id" "")
            $displayName = [string](
                Get-ExtensionPropertyValue $item "DisplayName" ""
            )
            $directory = [string](
                Get-ExtensionPropertyValue $item "Directory" ""
            )
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $displayName = if (-not [string]::IsNullOrWhiteSpace($directory)) {
                    $directory
                }
                elseif (-not [string]::IsNullOrWhiteSpace($id)) {
                    $id
                }
                else {
                    "未命名扩展"
                }
            }

            if ($Kind -eq "Installed") {
                $canEnable = ConvertTo-ExtensionBoolean (
                    Get-ExtensionPropertyValue $item "CanEnable" $false
                )
                $canDisable = ConvertTo-ExtensionBoolean (
                    Get-ExtensionPropertyValue $item "CanDisable" $false
                )
                $canRestore = ConvertTo-ExtensionBoolean (
                    Get-ExtensionPropertyValue $item "CanRestore" $false
                )
                $canRemove = ConvertTo-ExtensionBoolean (
                    Get-ExtensionPropertyValue $item "CanRemove" $false
                )
                $canOpenFolder = ConvertTo-ExtensionBoolean (
                    Get-ExtensionPropertyValue $item "CanOpenFolder" $false
                )
                $state = [string](
                    Get-ExtensionPropertyValue $item "State" "attention"
                )
                if ($state -notin @(
                    "enabled",
                    "disabled",
                    "recoverable",
                    "attention"
                ) -or
                    ($state -eq "enabled" -and -not $canDisable) -or
                    ($state -eq "disabled" -and -not $canEnable) -or
                    ($state -eq "recoverable" -and -not $canRestore)) {
                    $state = "attention"
                }
                if ([string]::IsNullOrWhiteSpace($id)) {
                    $canEnable = $false
                    $canDisable = $false
                    $canRestore = $false
                    $canRemove = $false
                    $canOpenFolder = $false
                    $state = "attention"
                }

                [pscustomobject][ordered]@{
                    Id = $id
                    DisplayName = $displayName
                    StateText = [string](
                        Get-ExtensionPropertyValue $item "StateText" "需要处理"
                    )
                    SourceText = [string](
                        Get-ExtensionPropertyValue $item "SourceText" "未知来源"
                    )
                    VersionText = [string](
                        Get-ExtensionPropertyValue $item "VersionText" "未知"
                    )
                    Path = [string](
                        Get-ExtensionPropertyValue $item "Path" ""
                    )
                    SourceUrl = [string](
                        Get-ExtensionPropertyValue $item "SourceUrl" ""
                    )
                    CanEnable = $canEnable
                    CanDisable = $canDisable
                    CanRestore = $canRestore
                    CanRemove = $canRemove
                    CanOpenFolder = $canOpenFolder
                    Directory = $directory
                    State = $state
                }
                continue
            }

            $canInstall = ConvertTo-ExtensionBoolean (
                Get-ExtensionPropertyValue $item "CanInstall" $false
            )
            $canReinstall = ConvertTo-ExtensionBoolean (
                Get-ExtensionPropertyValue $item "CanReinstall" $false
            )
            $reinstallId = [string](
                Get-ExtensionPropertyValue $item "ReinstallId" ""
            )
            if ([string]::IsNullOrWhiteSpace($id)) {
                $canInstall = $false
            }
            if ([string]::IsNullOrWhiteSpace($reinstallId)) {
                $canReinstall = $false
            }
            if ($canInstall -and $canReinstall) {
                # Fail closed if a worker result ever offers two different
                # mutations for one row.
                $canInstall = $false
                $canReinstall = $false
            }
            [pscustomobject][ordered]@{
                Id = $id
                DisplayName = $displayName
                Description = [string](
                    Get-ExtensionPropertyValue $item "Description" ""
                )
                SourceText = [string](
                    Get-ExtensionPropertyValue $item "SourceText" "扩展目录"
                )
                StateText = [string](
                    Get-ExtensionPropertyValue $item "StateText" ""
                )
                SourceUrl = [string](
                    Get-ExtensionPropertyValue $item "SourceUrl" ""
                )
                CanInstall = $canInstall
                CanReinstall = $canReinstall
                ReinstallId = $reinstallId
                Directory = $directory
            }
        }
    )
    return [object[]]$normalizedItems
}

function Update-InstalledExtensionActions {
    $item = $script:InstalledExtensionsGrid.SelectedItem
    $available = ($null -ne $item -and $null -eq $script:extensionJob)
    $script:BtnEnableInstalledExtension.IsEnabled = (
        $available -and [bool]$item.CanEnable
    )
    $script:BtnDisableInstalledExtension.IsEnabled = (
        $available -and [bool]$item.CanDisable
    )
    $script:BtnRemoveInstalledExtension.IsEnabled = (
        $available -and [bool]$item.CanRemove
    )
    $script:BtnOpenInstalledExtensionFolder.IsEnabled = (
        $available -and
        [bool]$item.CanOpenFolder -and
        -not [string]::IsNullOrWhiteSpace([string]$item.Path) -and
        [System.IO.Directory]::Exists([string]$item.Path)
    )
}

function Update-ExtensionCatalogActions {
    $item = $script:ExtensionCatalogGrid.SelectedItem
    $available = ($null -ne $item -and $null -eq $script:extensionJob)
    $mutation = Resolve-ExtensionCatalogMutation -Item $item
    $script:BtnInstallSelectedExtension.Content = if (
        $null -ne $mutation -and $mutation.Action -eq "Restore"
    ) {
        "重新安装"
    }
    else {
        "安装"
    }
    $script:BtnInstallSelectedExtension.IsEnabled = (
        $available -and $null -ne $mutation
    )
    $sourceUrl = if ($available) { [string]$item.SourceUrl } else { "" }
    $sourceUri = $null
    $script:BtnOpenExtensionSource.IsEnabled = (
        [System.Uri]::TryCreate(
            $sourceUrl,
            [System.UriKind]::Absolute,
            [ref]$sourceUri
        ) -and
        $sourceUri.Scheme -eq "https" -and
        $sourceUri.Host -eq "github.com"
    )
}

function Resolve-ExtensionCatalogMutation {
    param([object]$Item)

    if ($null -eq $Item) {
        return $null
    }
    $canInstall = ConvertTo-ExtensionBoolean (
        Get-ExtensionPropertyValue $Item "CanInstall" $false
    )
    $canReinstall = ConvertTo-ExtensionBoolean (
        Get-ExtensionPropertyValue $Item "CanReinstall" $false
    )
    if ($canInstall -eq $canReinstall) {
        return $null
    }
    if ($canReinstall) {
        $reinstallId = [string](
            Get-ExtensionPropertyValue $Item "ReinstallId" ""
        )
        if ([string]::IsNullOrWhiteSpace($reinstallId)) {
            return $null
        }
        return [pscustomobject][ordered]@{
            Action = "Restore"
            Id = $reinstallId
        }
    }
    $catalogId = [string](Get-ExtensionPropertyValue $Item "Id" "")
    if ([string]::IsNullOrWhiteSpace($catalogId)) {
        return $null
    }
    return [pscustomobject][ordered]@{
        Action = "Install"
        Id = $catalogId
    }
}

function Update-InstalledExtensionView {
    $query = $script:InstalledExtensionsSearchBox.Text.Trim()
    $filter = Get-ComboTag $script:InstalledExtensionsFilterCombo
    $items = @(
        foreach ($item in @($script:installedExtensionItems)) {
            $matchesQuery = [string]::IsNullOrWhiteSpace($query)
            if (-not $matchesQuery) {
                foreach ($textValue in @(
                    [string]$item.DisplayName,
                    [string]$item.SourceText,
                    [string]$item.VersionText
                )) {
                    if ($textValue.IndexOf(
                            $query,
                            [System.StringComparison]::OrdinalIgnoreCase
                        ) -ge 0) {
                        $matchesQuery = $true
                        break
                    }
                }
            }
            if (-not $matchesQuery) {
                continue
            }

            $matchesFilter = switch ($filter) {
                "enabled" {
                    [string]$item.State -eq "enabled"
                    break
                }
                "disabled" {
                    [string]$item.State -eq "disabled"
                    break
                }
                "recoverable" {
                    [string]$item.State -eq "recoverable"
                    break
                }
                "attention" {
                    [string]$item.State -eq "attention"
                    break
                }
                default { $true }
            }
            if ($matchesFilter) {
                $item
            }
        }
    )

    $script:InstalledExtensionsGrid.ItemsSource = [object[]]$items
    $script:InstalledExtensionsStatusText.Text = (
        "显示 {0} 项，共 {1} 项；整合包内置扩展受保护。" -f
        $items.Count,
        @($script:installedExtensionItems).Count
    )
    Update-InstalledExtensionActions
}

function ConvertTo-LauncherProcessArgument {
    param([string]$Value)

    if ($null -eq $Value) { $Value = "" }
    if ($Value.IndexOf([char]0) -ge 0 -or
        $Value.Contains("`r") -or $Value.Contains("`n")) {
        throw "外部进程参数包含非法字符。"
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

function Stop-ExtensionWorkerProcess {
    param([object]$WorkerProcess)

    if ($null -eq $WorkerProcess) { return }
    $process = $WorkerProcess.Process
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $killerInfo = New-Object System.Diagnostics.ProcessStartInfo
                $killerInfo.FileName = "taskkill.exe"
                $killerInfo.Arguments = "/PID $($process.Id) /T /F"
                $killerInfo.UseShellExecute = $false
                $killerInfo.CreateNoWindow = $true
                $killerInfo.RedirectStandardOutput = $true
                $killerInfo.RedirectStandardError = $true
                $killer = New-Object System.Diagnostics.Process
                $killer.StartInfo = $killerInfo
                [void]$killer.Start()
                [void]$killer.WaitForExit(5000)
                $killer.Dispose()
            }
        }
        catch {
            try { $process.Kill() } catch {}
        }
        try { $process.Dispose() } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$WorkerProcess.ResultPath)) {
        try {
            [System.IO.File]::Delete([string]$WorkerProcess.ResultPath)
        }
        catch {
        }
    }
}

function Start-ExtensionWorkerAction {
    param(
        [ValidateSet(
            "ListInstalled",
            "SearchCatalog",
            "RefreshCatalog",
            "Enable",
            "Disable",
            "Install",
            "Remove",
            "Restore"
        )]
        [string]$Action,
        [string]$Id = "",
        [string]$Query = "",
        [switch]$RestartAfter
    )

    $Query = ([string]$Query).Trim()
    if ($null -ne $script:extensionJob) {
        if ($Action -eq "SearchCatalog") {
            $script:pendingCatalogQuery = $Query
            $script:ExtensionCatalogStatusText.Text = "等待当前扩展任务完成…"
        }
        else {
            $busyMessage = "已有扩展任务正在进行，请完成后再试。"
            $script:InstalledExtensionsStatusText.Text = $busyMessage
            $script:ExtensionCatalogStatusText.Text = $busyMessage
        }
        return
    }
    if ($null -ne $script:coreUpdateJob -or
        $null -ne $script:dependencyRepairJob) {
        $message = "版本维护任务正在进行，请完成后再管理扩展。"
        $script:InstalledExtensionsStatusText.Text = $message
        $script:ExtensionCatalogStatusText.Text = $message
        return
    }

    $isMutation = $Action -in @(
        "Enable",
        "Disable",
        "Install",
        "Remove",
        "Restore"
    )
    $workerPath = $script:extensionWorkerPath
    $workerRoot = $script:root
    $workerSettingsPath = $script:settingsPath
    if ($Action -eq "SearchCatalog") {
        # The query being started is the newest known query. Do not replay an
        # older queued value after this job completes.
        $script:pendingCatalogQuery = $null
    }
    if ($isMutation) {
        Set-ExtensionMaintenanceControls $true
    }

    $newJob = $null
    try {
        $stateRoot = Join-Path $workerRoot "user\launcher\state"
        if (-not [System.IO.Directory]::Exists($stateRoot)) {
            [void][System.IO.Directory]::CreateDirectory($stateRoot)
        }
        $resultPath = Join-Path $stateRoot (
            "extension-result-" + [Guid]::NewGuid().ToString("N") + ".json"
        )
        $powerShellPath = Join-Path $PSHOME "powershell.exe"
        if (-not [System.IO.File]::Exists($powerShellPath)) {
            $powerShellPath = (Get-Process -Id $PID).Path
        }
        $processArguments = @(
            "-NoProfile", "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", $workerPath,
            "-Action", $Action,
            "-Root", $workerRoot,
            "-SettingsPath", $workerSettingsPath,
            "-ResultPath", $resultPath
        )
        if (-not [string]::IsNullOrWhiteSpace($Id)) {
            $processArguments += @("-Id", $Id)
        }
        if (-not [string]::IsNullOrWhiteSpace($Query)) {
            $processArguments += @("-Query", $Query)
        }
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powerShellPath
        $startInfo.Arguments = (
            $processArguments |
                ForEach-Object { ConvertTo-LauncherProcessArgument $_ }
        ) -join " "
        $startInfo.WorkingDirectory = $workerRoot
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw "无法创建扩展后台进程。"
        }
        $newJob = [pscustomobject]@{
            Process = $process
            StdOutTask = $process.StandardOutput.ReadToEndAsync()
            StdErrTask = $process.StandardError.ReadToEndAsync()
            ResultPath = $resultPath
        }
    }
    catch {
        $safeMessage = ConvertTo-LauncherSafeDiagnosticText (
            "无法启动扩展后台任务：" + $_.Exception.Message
        )
        $script:extensionJob = $null
        $script:extensionJobAction = ""
        $script:extensionJobQuery = ""
        $script:extensionJobIsMutation = $false
        $script:extensionRestartAfter = $false
        Set-ExtensionUiBusy -Busy $false -Action $Action
        if ($isMutation) {
            Set-ExtensionMaintenanceControls $false
        }
        if ($Action -in @(
            "SearchCatalog",
            "RefreshCatalog",
            "Install",
            "Restore"
        )) {
            $script:ExtensionCatalogStatusText.Text = $safeMessage
            $script:ExtensionCatalogStatusText.Foreground = Get-Brush "#FF8D99"
        }
        if ($Action -in @(
            "ListInstalled",
            "Enable",
            "Disable",
            "Remove",
            "Restore"
        )) {
            $script:InstalledExtensionsStatusText.Text = $safeMessage
            $script:InstalledExtensionsStatusText.Foreground = Get-Brush "#FF8D99"
        }
        Append-Console ("[EXTENSIONS] " + $safeMessage)
        if ($isMutation) {
            [void][System.Windows.MessageBox]::Show(
                $script:window,
                $safeMessage,
                (Get-UiText "DialogTitle"),
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
            if ($RestartAfter -and -not (Test-ComfyUIRunning)) {
                Start-ComfyUI
            }
        }
        return
    }

    $script:extensionJob = $newJob
    $script:extensionJobStartedUtc = [DateTimeOffset]::UtcNow
    $script:extensionJobAction = $Action
    $script:extensionJobQuery = if ($Action -eq "SearchCatalog") {
        [string]$Query
    }
    else {
        ""
    }
    $script:extensionJobIsMutation = $isMutation
    $script:extensionRestartAfter = [bool]$RestartAfter

    Set-ExtensionUiBusy -Busy $true -Action $Action
    switch ($Action) {
        "ListInstalled" {
            $script:InstalledExtensionsStatusText.Foreground = Get-Brush "#788895"
            $script:InstalledExtensionsStatusText.Text = "正在读取已安装扩展…"
        }
        "SearchCatalog" {
            $script:ExtensionCatalogStatusText.Foreground = Get-Brush "#788895"
            $script:ExtensionCatalogStatusText.Text = "正在查询扩展目录…"
        }
        "RefreshCatalog" {
            $script:ExtensionCatalogStatusText.Foreground = Get-Brush "#788895"
            $script:ExtensionCatalogStatusText.Text = "正在刷新扩展目录索引…"
        }
        default {
            $script:InstalledExtensionsStatusText.Foreground = Get-Brush "#788895"
            $script:ExtensionCatalogStatusText.Foreground = Get-Brush "#788895"
            $statusText = (
                "正在下载、检查依赖并测试节点；" +
                "首次安装通常需要 1–2 分钟，请勿关闭启动器…"
            )
            $script:InstalledExtensionsStatusText.Text = $statusText
            $script:ExtensionCatalogStatusText.Text = $statusText
            Set-LauncherStatus "正在维护自定义节点" "#6F85FF"
        }
    }
}

function Update-ExtensionMutationProgress {
    if (-not [bool]$script:extensionJobIsMutation) {
        return
    }
    try {
        $transactionsRoot = Join-Path `
            $script:root `
            "user\launcher\extensions\transactions"
        if (-not [System.IO.Directory]::Exists($transactionsRoot)) {
            return
        }
        $latest = Get-ChildItem `
            -LiteralPath $transactionsRoot `
            -Directory `
            -Force `
            -ErrorAction Stop |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -eq $latest -or
            $latest.LastWriteTimeUtc -lt
                $script:extensionJobStartedUtc.UtcDateTime.AddSeconds(-2)) {
            return
        }
        $manifestPath = Join-Path $latest.FullName "transaction.json"
        if (-not [System.IO.File]::Exists($manifestPath) -or
            (Get-Item -LiteralPath $manifestPath).Length -gt 1MB) {
            return
        }
        $manifest = [System.IO.File]::ReadAllText(
            $manifestPath,
            [System.Text.Encoding]::UTF8
        ) | ConvertFrom-Json
        $phaseText = switch ([string]$manifest.phase) {
            "prepared" { "正在准备安装任务…" }
            "downloading" { "正在下载插件源码…" }
            "validating" { "正在检查插件文件安全性…" }
            "dependency-preflight" { "正在分析 Python 依赖与回滚方案…" }
            "installing-dependencies" { "正在下载并安装插件依赖…" }
            "activating" { "正在启用插件目录…" }
            "health-check" {
                "正在隔离启动插件进行验证，通常约需 1 分钟…"
            }
            "moving-to-backup" { "正在安全移除并保留恢复备份…" }
            "restoring" { "正在恢复插件备份…" }
            default { "" }
        }
        if (-not [string]::IsNullOrWhiteSpace($phaseText)) {
            $script:InstalledExtensionsStatusText.Text = $phaseText
            $script:ExtensionCatalogStatusText.Text = $phaseText
        }
    }
    catch {
        # Progress text is best-effort and must not affect the transaction.
    }
}

function Complete-ExtensionWorkerAction {
    if ($null -eq $script:extensionJob) {
        return
    }

    $process = $script:extensionJob.Process
    if ($null -eq $process -or -not $process.HasExited) {
        Update-ExtensionMutationProgress
        return
    }

    $action = [string]$script:extensionJobAction
    $jobQuery = [string]$script:extensionJobQuery
    $isMutation = [bool]$script:extensionJobIsMutation
    $restartAfter = [bool]$script:extensionRestartAfter
    $output = @()
    $jobErrors = @()
    try {
        if ([System.IO.File]::Exists($script:extensionJob.ResultPath)) {
            $output = @([System.IO.File]::ReadAllText(
                $script:extensionJob.ResultPath,
                [System.Text.Encoding]::UTF8
            ))
        }
        else {
            $output = @(
                $script:extensionJob.StdOutTask.GetAwaiter().GetResult()
            )
        }
        $standardError = (
            $script:extensionJob.StdErrTask.GetAwaiter().GetResult()
        )
        if (-not [string]::IsNullOrWhiteSpace($standardError)) {
            $jobErrors += $standardError
        }
    }
    catch {
        $jobErrors += $_
    }
    Stop-ExtensionWorkerProcess $script:extensionJob
    $script:extensionJob = $null
    $script:extensionJobStartedUtc = [DateTimeOffset]::MinValue
    $script:extensionJobAction = ""
    $script:extensionJobQuery = ""
    $script:extensionJobIsMutation = $false
    $script:extensionRestartAfter = $false
    Set-ExtensionUiBusy -Busy $false -Action $action
    if ($isMutation) {
        Set-ExtensionMaintenanceControls $false
    }

    $result = $null
    try {
        $jsonText = [string]($output -join "")
        if ([string]::IsNullOrWhiteSpace($jsonText)) {
            throw "扩展工作进程没有返回结果。"
        }
        $result = ConvertTo-ExtensionWorkerResult (
            $jsonText | ConvertFrom-Json
        )
        if ([bool]$result.ok -and
            $action -in @("ListInstalled", "SearchCatalog")) {
            $dataItems = if ($null -ne $result.data) {
                $result.data.PSObject.Properties["items"]
            }
            else {
                $null
            }
            if ($null -eq $dataItems) {
                throw "扩展工作进程返回的数据缺少 items 字段。"
            }
        }
    }
    catch {
        $reason = if ($jobErrors.Count -gt 0) {
            [string]$jobErrors[0]
        }
        else {
            $_.Exception.Message
        }
        $result = [pscustomobject]@{
            ok = $false
            message = ConvertTo-LauncherSafeDiagnosticText $reason
            data = $null
        }
    }

    if ($action -eq "SearchCatalog") {
        $currentQuery = [string]$script:ExtensionCatalogSearchBox.Text.Trim()
        if (-not (Test-ExtensionCatalogQueryCurrent -CompletedQuery $jobQuery)) {
            # The editor changed while this search was running. Never paint an
            # obsolete result over the newest input; replace it immediately
            # with one search for the current text.
            $script:pendingCatalogQuery = $null
            if ($null -ne $script:extensionCatalogSearchTimer) {
                $script:extensionCatalogSearchTimer.Stop()
            }
            Start-ExtensionWorkerAction `
                -Action "SearchCatalog" `
                -Query $currentQuery
            return
        }
        # A queued query equal to the completed query adds no value.
        $script:pendingCatalogQuery = $null
    }

    if ([bool]$result.ok) {
        switch ($action) {
            "ListInstalled" {
                $script:installedExtensionItems = ConvertTo-ExtensionItemArray `
                    -Data $result.data `
                    -Kind "Installed"
                $script:installedExtensionsLoaded = $true
                Update-InstalledExtensionView
            }
            "SearchCatalog" {
                $needsInitialCatalogRefresh = (
                    -not $script:extensionCatalogInitialRefreshAttempted -and
                    [bool]$result.data.stale -and
                    [int]$result.data.count -eq 0 -and
                    [string]::IsNullOrWhiteSpace(
                        [string]$result.data.fetchedAtUtc
                    )
                )
                if ($needsInitialCatalogRefresh) {
                    $script:extensionCatalogInitialRefreshAttempted = $true
                    $script:ExtensionCatalogStatusText.Foreground = Get-Brush "#788895"
                    $script:ExtensionCatalogStatusText.Text = "首次使用，正在获取扩展目录…"
                    Start-ExtensionWorkerAction -Action "RefreshCatalog"
                    return
                }
                $script:extensionCatalogItems = ConvertTo-ExtensionItemArray `
                    -Data $result.data `
                    -Kind "Catalog"
                $script:extensionCatalogLoaded = $true
                $script:ExtensionCatalogGrid.ItemsSource = (
                    [object[]]$script:extensionCatalogItems
                )
                $script:ExtensionCatalogStatusText.Text = (
                    "找到 {0} 项扩展目录条目；仅支持 GitHub HTTPS 来源。" -f
                    @($script:extensionCatalogItems).Count
                )
                Update-ExtensionCatalogActions
            }
            "RefreshCatalog" {
                $script:extensionCatalogLoaded = $false
                $script:ExtensionCatalogStatusText.Text = [string]$result.message
                Start-ExtensionWorkerAction `
                    -Action "SearchCatalog" `
                    -Query $script:ExtensionCatalogSearchBox.Text.Trim()
                return
            }
            default {
                $message = [string]$result.message
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = "扩展操作已完成。"
                }
                $script:InstalledExtensionsStatusText.Text = $message
                $script:ExtensionCatalogStatusText.Text = $message
                Append-Console ("[EXTENSIONS] " + $message)
                $script:installedExtensionsLoaded = $false
                $script:extensionCatalogLoaded = $false
                $script:extensionPostMutationRefresh = $true
                Start-ExtensionWorkerAction -Action "ListInstalled"
                if ($restartAfter -and -not (Test-ComfyUIRunning)) {
                    Start-ComfyUI
                }
                else {
                    Set-LauncherStatus (Get-UiText "StatusReady") "#7F8B97"
                }
                return
            }
        }
    }
    else {
        $message = [string]$result.message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "扩展操作失败。"
        }
        $studentHint = switch ([string]$result.code) {
            "E_NETWORK" {
                "下载没有完成，整合包文件未被改动。请检查网络或代理后重试。"
            }
            "E_PROCESS_TIMEOUT" {
                "插件已下载，但后台依赖检查超时；本次变更已自动回滚。请把插件名称和下方原因发给老师。"
            }
            "E_DEPENDENCY_CHANGE_BLOCKED" {
                "此插件会修改核心环境，或缺少可自动回滚的安装包；为避免把整合包装坏，已安全取消。请把插件名称和下方原因发给老师。"
            }
            "E_DEPENDENCY_FAILED" {
                "插件依赖安装后未通过兼容检查，已自动恢复到安装前状态。请把插件名称和下方原因发给老师。"
            }
            "E_SCRIPT_REQUIRED" {
                "此插件要求运行作者提供的安装脚本。为保护学员电脑，启动器不会自动执行未经审核的脚本。请联系老师处理。"
            }
            "E_HEALTH_CHECK" {
                "插件已经下载，但隔离启动检查未通过；插件和新增依赖已自动回滚，不会影响原整合包。"
            }
            "E_DISK_FULL" {
                "磁盘可用空间不足，安装已安全取消，请清理空间后重试。"
            }
            "E_ROLLBACK_FAILED" {
                "自动恢复没有完整完成。请不要继续启动或安装插件，立即把本提示发给老师处理。"
            }
            default { "" }
        }
        $fullMessage = if ([string]::IsNullOrWhiteSpace($studentHint)) {
            $message
        }
        else {
            $studentHint + [Environment]::NewLine +
            [Environment]::NewLine + "详细原因：" + $message
        }
        $safeMessage = ConvertTo-LauncherSafeDiagnosticText $fullMessage
        if ($action -in @(
            "SearchCatalog",
            "RefreshCatalog",
            "Install",
            "Restore"
        )) {
            $script:ExtensionCatalogStatusText.Text = $safeMessage
            $script:ExtensionCatalogStatusText.Foreground = Get-Brush "#FF8D99"
        }
        if ($action -in @(
            "ListInstalled",
            "Enable",
            "Disable",
            "Remove",
            "Restore"
        )) {
            $script:InstalledExtensionsStatusText.Text = $safeMessage
            $script:InstalledExtensionsStatusText.Foreground = Get-Brush "#FF8D99"
        }
        Append-Console ("[EXTENSIONS] " + $safeMessage)
        if ($isMutation) {
            [void][System.Windows.MessageBox]::Show(
                $script:window,
                $safeMessage,
                (Get-UiText "DialogTitle"),
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
        if ($restartAfter -and -not (Test-ComfyUIRunning)) {
            Start-ComfyUI
        }
        else {
            Set-LauncherStatus (Get-UiText "StatusReady") "#7F8B97"
        }
    }

    if ($action -eq "ListInstalled" -and
        $script:extensionPostMutationRefresh) {
        $script:extensionPostMutationRefresh = $false
        Start-ExtensionWorkerAction `
            -Action "SearchCatalog" `
            -Query $script:ExtensionCatalogSearchBox.Text.Trim()
        return
    }
    if ($null -ne $script:pendingCatalogQuery) {
        $query = [string]$script:pendingCatalogQuery
        $script:pendingCatalogQuery = $null
        Start-ExtensionWorkerAction -Action "SearchCatalog" -Query $query
    }
}

function Request-ExtensionMutation {
    param(
        [ValidateSet("Enable", "Disable", "Install", "Remove", "Restore")]
        [string]$Action,
        [object]$Item
    )

    if ($null -eq $Item -or $null -ne $script:extensionJob) {
        return
    }
    $mutationId = if ($Action -eq "Restore") {
        $candidateId = [string](
            Get-ExtensionPropertyValue $Item "ReinstallId" ""
        )
        if ([string]::IsNullOrWhiteSpace($candidateId)) {
            [string](Get-ExtensionPropertyValue $Item "Id" "")
        }
        else {
            $candidateId
        }
    }
    else {
        [string](Get-ExtensionPropertyValue $Item "Id" "")
    }
    if ([string]::IsNullOrWhiteSpace($mutationId)) {
        return
    }

    $actionText = switch ($Action) {
        "Enable" { "启用" }
        "Disable" { "停用" }
        "Install" { "安装" }
        "Remove" { "移除" }
        "Restore" { "重新安装" }
    }
    $details = switch ($Action) {
        "Install" {
            "安装器仅接受当前扩展目录中的 GitHub HTTPS 来源，并会在写入前检查目录和 Python 依赖。"
        }
        "Remove" {
            "仅启动器安装的扩展可以移除；文件将进入本地安全备份，Python 依赖暂不卸载。"
        }
        "Restore" {
            "使用启动器保留的本地安全备份重新安装，不重新下载，也不重复安装 Python 依赖。"
        }
        default {
            "此操作需要 ComfyUI 停止，完成后才会在下次启动生效。"
        }
    }
    $wasRunning = Test-ComfyUIRunning
    $runningText = if ($wasRunning) {
        "`n`nComfyUI 当前正在运行，将先停止服务，完成后自动恢复。"
    }
    else {
        ""
    }
    $confirmationMessage = "{0}扩展【{1}】？`n`n{2}{3}" -f @(
        $actionText,
        [string]$Item.DisplayName,
        $details,
        $runningText
    )
    $answer = [System.Windows.MessageBox]::Show(
        $script:window,
        $confirmationMessage,
        (Get-UiText "DialogTitle"),
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }

    if ($wasRunning) {
        $stopConfirmed = Stop-ComfyUI
        if (-not $stopConfirmed -or (Test-ComfyUIRunning)) {
            [void][System.Windows.MessageBox]::Show(
                $script:window,
                "ComfyUI 未能完全停止，扩展操作已取消。",
                (Get-UiText "DialogTitle"),
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
            return
        }
    }

    Start-ExtensionWorkerAction `
        -Action $Action `
        -Id $mutationId `
        -RestartAfter:$wasRunning
}

function Save-UpdatePreferences {
    $script:launcherSettings.updates.autoCheck = ($script:AutoUpdateCheck.IsChecked -eq $true)
    $script:launcherSettings.updates.channel = Get-ComboTag $script:UpdateChannelCombo
    $script:settingsGeneration++
    Save-LauncherSettingsIfAllowed -Path $script:settingsPath -Settings $script:launcherSettings
}

function Save-LauncherTextAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($parent)) {
        [void][System.IO.Directory]::CreateDirectory($parent)
    }

    $tempPath = Join-Path $parent ([System.IO.Path]::GetFileName($Path) + "." + [Guid]::NewGuid().ToString("N") + ".tmp")
    $backupPath = $Path + ".bak"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Text, $script:utf8)
        if ([System.IO.File]::Exists($Path)) {
            [System.IO.File]::Replace($tempPath, $Path, $backupPath, $true)
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    }
    finally {
        if ([System.IO.File]::Exists($tempPath)) {
            [System.IO.File]::Delete($tempPath)
        }
    }
}

function Start-MigrationInventoryScan {
    if ($null -ne $script:inventoryJob) {
        return
    }
    if (Test-ComfyUIRunning) {
        $script:InventoryStatusText.Text = "请先停止 ComfyUI，再生成完整的版本清单。"
        $script:InventoryStatusText.Foreground = Get-Brush "#FFB454"
        return
    }

    $scanScript = {
        param(
            [string]$Root,
            [string]$LauncherVersion,
            [string]$CoreVersion
        )

        $ErrorActionPreference = "Stop"
        trap {
            [ordered]@{
                scanError = [string]$_.Exception.Message
                scriptLineNumber = [int]$_.InvocationInfo.ScriptLineNumber
                sourceLine = [string]$_.InvocationInfo.Line
            } | ConvertTo-Json -Compress
            break
        }

        function Get-RelativeInventoryPath {
            param([string]$BasePath, [string]$TargetPath)
            $baseUri = [System.Uri]::new(($BasePath.TrimEnd("\") + "\"))
            $targetUri = [System.Uri]::new($TargetPath)
            return [System.Uri]::UnescapeDataString(
                $baseUri.MakeRelativeUri($targetUri).ToString()
            ).Replace("/", "\")
        }

        function Get-InventoryTreeSummary {
            param([string]$Path, [string]$RootPath)

            $fileCount = [int64]0
            $directoryCount = [int64]0
            $totalBytes = [int64]0
            $reparsePoints = New-Object System.Collections.Generic.List[string]
            $warnings = New-Object System.Collections.Generic.List[string]
            $stack = New-Object System.Collections.Generic.Stack[string]
            if ([System.IO.Directory]::Exists($Path)) {
                $stack.Push([System.IO.Path]::GetFullPath($Path))
            }

            while ($stack.Count -gt 0) {
                $current = $stack.Pop()
                $entries = $null
                try {
                    $entries = [System.IO.Directory]::EnumerateFileSystemEntries($current)
                }
                catch {
                    $warnings.Add("无法读取：" + (Get-RelativeInventoryPath $RootPath $current))
                    continue
                }

                foreach ($entry in $entries) {
                    try {
                        $attributes = [System.IO.File]::GetAttributes($entry)
                        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                            $reparsePoints.Add((Get-RelativeInventoryPath $RootPath $entry))
                            continue
                        }
                        if (($attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                            $directoryCount++
                            $stack.Push($entry)
                        }
                        else {
                            $fileCount++
                            $totalBytes += ([System.IO.FileInfo]::new($entry)).Length
                        }
                    }
                    catch {
                        $warnings.Add("无法读取：" + (Get-RelativeInventoryPath $RootPath $entry))
                    }
                }
            }

            return [pscustomobject]@{
                fileCount = $fileCount
                directoryCount = $directoryCount
                totalBytes = $totalBytes
                reparsePoints = $reparsePoints.ToArray()
                warnings = $warnings.ToArray()
            }
        }

        $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd("\")
        $drive = [System.IO.DriveInfo]::new([System.IO.Path]::GetPathRoot($normalizedRoot))
        $pythonExecutable = Join-Path $normalizedRoot ".ext\python.exe"
        $sitePackagesPath = Join-Path $normalizedRoot ".ext\Lib\site-packages"
        $pythonVersion = "未知"
        if ([System.IO.File]::Exists($pythonExecutable)) {
            try {
                $pythonVersion = (& $pythonExecutable --version 2>&1 | Select-Object -First 1).ToString().Replace("Python ", "")
            }
            catch {
                $pythonVersion = "检测失败"
            }
        }
        $pythonAbi = "未知"
        if ($pythonVersion -match "^(\d+)\.(\d+)") {
            $pythonAbi = "cp" + $matches[1] + $matches[2]
        }
        $pythonHash = ""
        if ([System.IO.File]::Exists($pythonExecutable)) {
            try {
                $pythonHash = (Get-FileHash -LiteralPath $pythonExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            catch {
                $pythonHash = ""
            }
        }

        $knownDirectories = [ordered]@{}
        $allReparsePoints = New-Object System.Collections.Generic.List[string]
        $allWarnings = New-Object System.Collections.Generic.List[string]
        foreach ($directoryName in @("custom_nodes", "models", "input", "output", "user")) {
            $summary = Get-InventoryTreeSummary (Join-Path $normalizedRoot $directoryName) $normalizedRoot
            $knownDirectories[$directoryName] = [pscustomobject]@{
                fileCount = $summary.fileCount
                directoryCount = $summary.directoryCount
                totalBytes = $summary.totalBytes
            }
            foreach ($item in $summary.reparsePoints) { $allReparsePoints.Add($item) }
            foreach ($item in $summary.warnings) { $allWarnings.Add($item) }
        }

        foreach ($topEntryPath in @([System.IO.Directory]::GetFileSystemEntries($normalizedRoot))) {
            try {
                $topAttributes = [System.IO.File]::GetAttributes($topEntryPath)
                if (($topAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $relativeTop = Get-RelativeInventoryPath $normalizedRoot $topEntryPath
                    if (-not $allReparsePoints.Contains($relativeTop)) {
                        $allReparsePoints.Add($relativeTop)
                    }
                }
            }
            catch {
                $allWarnings.Add("无法读取顶层对象：" + (Get-RelativeInventoryPath $normalizedRoot $topEntryPath))
            }
        }

        $customNodeItems = New-Object System.Collections.Generic.List[object]
        $customNodesPath = Join-Path $normalizedRoot "custom_nodes"
        if ([System.IO.Directory]::Exists($customNodesPath)) {
            foreach ($nodePath in @([System.IO.Directory]::GetDirectories($customNodesPath))) {
                $node = [System.IO.DirectoryInfo]::new($nodePath)
                $hasConfig = $false
                foreach ($configPath in @([System.IO.Directory]::GetFiles(
                    $node.FullName,
                    "*",
                    [System.IO.SearchOption]::TopDirectoryOnly
                ))) {
                    if ([System.IO.Path]::GetFileName($configPath) -match "^(config|settings).*\.(json|ya?ml|toml)$|^\.env$") {
                        $hasConfig = $true
                        break
                    }
                }
                $customNodeItems.Add([pscustomobject]@{
                    relativePath = "custom_nodes\" + $node.Name
                    hasGit = [System.IO.Directory]::Exists((Join-Path $node.FullName ".git"))
                    hasRequirements = [System.IO.File]::Exists((Join-Path $node.FullName "requirements.txt"))
                    hasInstallScript = (
                        [System.IO.File]::Exists((Join-Path $node.FullName "install.py")) -or
                        [System.IO.File]::Exists((Join-Path $node.FullName "install.ps1")) -or
                        [System.IO.File]::Exists((Join-Path $node.FullName "install.bat"))
                    )
                    hasLocalConfig = $hasConfig
                })
            }
        }

        $blockers = New-Object System.Collections.Generic.List[string]
        $blockers.Add("当前仍为 legacy-flat 布局")
        $blockers.Add("缺少可信的文件归属和签名安装清单")
        $blockers.Add("嵌入式 Python 环境仍与当前运行时共享且可变")
        if ($allReparsePoints.Count -gt 0) {
            $blockers.Add("检测到 Reparse Point，迁移器必须拒绝跟随")
        }
        $installScriptCount = 0
        foreach ($customNodeItem in $customNodeItems) {
            if ($customNodeItem.hasInstallScript) {
                $installScriptCount++
            }
        }
        if ($installScriptCount -gt 0) {
            $allWarnings.Add("有 $installScriptCount 个自定义节点包含安装脚本")
        }
        $allWarnings.Add("未执行全盘硬链接检测；下一阶段迁移预检必须补充")
        $packageCount = 0
        if ([System.IO.Directory]::Exists($sitePackagesPath)) {
            $packageCount = [System.IO.Directory]::GetDirectories(
                $sitePackagesPath,
                "*.dist-info",
                [System.IO.SearchOption]::TopDirectoryOnly
            ).Count
        }

        $inventory = [ordered]@{
            schemaVersion = 1
            scanId = [Guid]::NewGuid().ToString()
            generatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
            launcherVersion = $LauncherVersion
            installation = [ordered]@{
                rootPath = $normalizedRoot
                fileSystem = $drive.DriveFormat
                freeBytes = [int64]$drive.AvailableFreeSpace
                isWritable = $true
            }
            comfyui = [ordered]@{
                detectedVersion = $CoreVersion
                versionEvidence = "comfyui_version.py"
                entryPoint = "main.py"
                hasGit = [System.IO.Directory]::Exists((Join-Path $normalizedRoot ".git"))
            }
            python = [ordered]@{
                executable = ".ext\python.exe"
                version = $pythonVersion
                architecture = $env:PROCESSOR_ARCHITECTURE
                abi = $pythonAbi
                executableSha256 = $pythonHash
                sitePackagesPath = ".ext\Lib\site-packages"
                packageCount = $packageCount
            }
            directories = $knownDirectories
            customNodes = $customNodeItems.ToArray()
            filesystemRisks = [ordered]@{
                reparsePoints = $allReparsePoints.ToArray()
                symlinks = @()
                junctions = @()
                hardlinkCandidates = @()
                lockedCriticalFiles = @()
            }
            migrationReadiness = [ordered]@{
                status = "blocked"
                blockers = $blockers.ToArray()
                warnings = $allWarnings.ToArray()
            }
        }

        $inventory | ConvertTo-Json -Depth 10 -Compress
    }

    try {
        $script:lastInventoryScanSucceeded = $false
        $script:inventoryJob = Start-Job `
            -ScriptBlock $scanScript `
            -ArgumentList @(
                $script:root,
                [string]$script:launcherVersionInfo.version,
                [string]$script:coreVersion
            )
        $script:InventoryProgress.Visibility = [System.Windows.Visibility]::Visible
        $script:InventoryStatusText.Text = "正在整理版本与目录信息，不会修改任何文件。"
        $script:InventoryStatusText.Foreground = Get-Brush "#FFD47C"
        $script:BtnInventoryScan.IsEnabled = $false
        $script:BtnCancelInventory.Visibility = [System.Windows.Visibility]::Visible
    }
    catch {
        $script:inventoryJob = $null
        $script:InventoryStatusText.Text = "无法启动扫描：" + $_.Exception.Message
        $script:InventoryStatusText.Foreground = Get-Brush "#FF8D99"
    }
}

function Stop-MigrationInventoryScan {
    if ($null -eq $script:inventoryJob) {
        return
    }
    try {
        Stop-Job -Job $script:inventoryJob -ErrorAction SilentlyContinue
        $script:InventoryStatusText.Text = "正在停止整理..."
        $script:InventoryStatusText.Foreground = Get-Brush "#FFB454"
    }
    catch {
        $script:InventoryStatusText.Text = "取消失败：" + $_.Exception.Message
        $script:InventoryStatusText.Foreground = Get-Brush "#FF8D99"
    }
}

function Complete-MigrationInventoryScan {
    if ($null -eq $script:inventoryJob) {
        return
    }

    $state = [string]$script:inventoryJob.State
    if ($state -in @("NotStarted", "Running", "Stopping", "Blocked")) {
        return
    }

    try {
        if ($state -eq "Completed") {
            $payload = @(Receive-Job -Job $script:inventoryJob -ErrorAction Stop)
            $jsonText = [string]($payload -join [Environment]::NewLine)
            if ([string]::IsNullOrWhiteSpace($jsonText)) {
                throw "扫描任务没有返回有效清单。"
            }
            $inventoryData = $jsonText | ConvertFrom-Json
            if ($null -ne $inventoryData.PSObject.Properties["scanError"]) {
                throw ("{0}（扫描脚本第 {1} 行：{2}）" -f
                    [string]$inventoryData.scanError,
                    [int]$inventoryData.scriptLineNumber,
                    [string]$inventoryData.sourceLine
                )
            }
            Save-LauncherTextAtomic -Path $script:inventoryPath -Text $jsonText
            $script:lastInventoryScanSucceeded = $true
            if (-not $script:isClosing) {
                $script:InventoryStatusText.Text = "版本清单已生成 · " + [DateTime]::Now.ToString("MM-dd HH:mm")
                $script:InventoryStatusText.Foreground = Get-Brush "#79D99D"
                Append-Console ("[INVENTORY] Read-only migration inventory saved: " + $script:inventoryPath)
            }
        }
        elseif ($state -eq "Stopped") {
            if (-not $script:isClosing) {
                $script:InventoryStatusText.Text = "版本整理已取消，没有改动现有文件。"
                $script:InventoryStatusText.Foreground = Get-Brush "#AAB5BE"
            }
        }
        else {
            $jobErrors = @()
            $failedPayload = @(Receive-Job -Job $script:inventoryJob -ErrorAction SilentlyContinue -ErrorVariable jobErrors)
            $reason = [string]$script:inventoryJob.JobStateInfo.Reason
            if ($failedPayload.Count -gt 0) {
                $failedText = [string]($failedPayload -join [Environment]::NewLine)
                try {
                    $failedData = $failedText | ConvertFrom-Json
                    if ($null -ne $failedData.PSObject.Properties["scanError"]) {
                        $reason = "{0}（扫描脚本第 {1} 行：{2}）" -f
                            [string]$failedData.scanError,
                            [int]$failedData.scriptLineNumber,
                            [string]$failedData.sourceLine
                    }
                }
                catch {
                }
            }
            if ($jobErrors.Count -gt 0 -and [string]::IsNullOrWhiteSpace($reason)) {
                $reason = [string]$jobErrors[0].Exception.Message
            }
            if ([string]::IsNullOrWhiteSpace($reason)) {
                $reason = "后台扫描任务失败。"
            }
            throw $reason
        }
    }
    catch {
        if (-not $script:isClosing) {
            $script:InventoryStatusText.Text = "扫描失败：" + $_.Exception.Message
            $script:InventoryStatusText.Foreground = Get-Brush "#FF8D99"
        }
    }
    finally {
        try { Remove-Job -Job $script:inventoryJob -Force -ErrorAction SilentlyContinue } catch {}
        $script:inventoryJob = $null
        if (-not $script:isClosing) {
            $script:InventoryProgress.Visibility = [System.Windows.Visibility]::Collapsed
            $script:BtnInventoryScan.IsEnabled = Test-OnlineCoreMaintenanceEnabled
            $script:BtnCancelInventory.Visibility = [System.Windows.Visibility]::Collapsed
        }
    }
}

function Start-DependencyRepair {
    if (-not (Test-OnlineCoreMaintenanceEnabled)) {
        $script:InventoryStatusText.Text = (
            "当前便携发布版不在线修改内置 Python；版本依赖随整合包维护版更新。"
        )
        $script:InventoryStatusText.Foreground = Get-Brush "#FFCC66"
        $script:BtnInventoryScan.Content = "修复整合包"
        $script:BtnInventoryScan.IsEnabled = $false
        return
    }

    if ($null -ne $script:dependencyRepairJob -or
        $null -ne $script:coreUpdateJob -or
        (
            $null -ne $script:extensionJob -and
            $script:extensionJobIsMutation
        )) {
        return
    }

    $requirementsPath = Join-Path $script:root "requirements.txt"
    if (-not [System.IO.File]::Exists($requirementsPath)) {
        $script:InventoryStatusText.Text = "无法恢复：当前版本缺少 requirements.txt。"
        $script:InventoryStatusText.Foreground = Get-Brush "#FF8D99"
        return
    }

    $wasRunning = Test-ComfyUIRunning
    $sourceHost = ""
    try {
        $sourceHost = ([System.Uri](
            Get-LauncherPypiIndexUrl $script:launcherSettings
        )).Host
    }
    catch {
        $sourceHost = "当前 PyPI 源"
    }
    $confirmationText = @(
        "将按当前 ComfyUI 版本恢复内置 Python 依赖："
        ""
        ("当前核心：{0}" -f $script:coreVersion)
        ("依赖清单：requirements.txt")
        ("软件源：{0}" -f $sourceHost)
        ""
        "该操作会补齐缺失或不兼容的依赖，并执行隔离核心启动检查。"
        "不会删除额外依赖，也不会改动 models、input、output、custom_nodes 或 user。"
        $(if ($wasRunning) { "ComfyUI 将暂时停止，完成后自动恢复运行。" } else { "" })
        ""
        "是否继续？"
    ) -join [Environment]::NewLine
    $answer = [System.Windows.MessageBox]::Show(
        $script:window,
        $confirmationText,
        (Get-UiText "DialogTitle"),
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        return
    }

    if ($wasRunning) {
        $stopConfirmed = Stop-ComfyUI
        if (-not $stopConfirmed -or (Test-ComfyUIRunning)) {
            $script:InventoryStatusText.Text = "ComfyUI 未能完全停止，依赖恢复已取消。"
            $script:InventoryStatusText.Foreground = Get-Brush "#FF8D99"
            return
        }
    }

    try {
        $repairId = [Guid]::NewGuid().ToString("N")
        $stateRoot = Join-Path $script:root "user\launcher\state"
        $logRoot = Join-Path $script:root "user\launcher\logs"
        foreach ($directoryPath in @($stateRoot, $logRoot)) {
            if (-not [System.IO.Directory]::Exists($directoryPath)) {
                [void][System.IO.Directory]::CreateDirectory($directoryPath)
            }
        }

        $requestPath = Join-Path $stateRoot (
            "dependency-repair-request-" + $repairId + ".json"
        )
        $statusPath = Join-Path $stateRoot (
            "dependency-repair-status-" + $repairId + ".json"
        )
        $logPath = Join-Path $logRoot (
            "dependency-repair-" +
            [DateTime]::Now.ToString("yyyyMMdd-HHmmss") +
            ".log"
        )
        $request = [ordered]@{
            schemaVersion = 1
            operation = "repair-dependencies"
            root = $script:root
            currentVersion = $script:coreVersion
            pythonPath = $script:pythonPath
            pypiIndexUrl = Get-LauncherPypiIndexUrl $script:launcherSettings
            proxyMode = [string]$script:launcherSettings.network.proxy.mode
            proxyAddress = [string]$script:launcherSettings.network.proxy.address
            proxyPort = [int]$script:launcherSettings.network.proxy.port
            statusPath = $statusPath
            logPath = $logPath
        }
        Save-LauncherTextAtomic `
            -Path $requestPath `
            -Text ($request | ConvertTo-Json -Depth 6)

        $script:dependencyRepairRequestPath = $requestPath
        $script:dependencyRepairStatusPath = $statusPath
        $script:dependencyRepairLastStatusJson = ""
        $script:dependencyRepairLastStage = ""
        $script:dependencyRepairRestartAfter = $wasRunning
        $script:dependencyRepairJob = Start-Job `
            -FilePath $script:coreUpdaterPath `
            -ArgumentList @($requestPath)

        $script:InventoryProgress.IsIndeterminate = $true
        $script:InventoryProgress.Visibility = [System.Windows.Visibility]::Visible
        $script:InventoryStatusText.Text = "正在准备恢复当前版本依赖…"
        $script:InventoryStatusText.Foreground = Get-Brush "#AAB5BE"
        $script:BtnInventoryScan.Content = "正在恢复…"
        $script:BtnInventoryScan.IsEnabled = $false
        $script:BtnCheckCoreUpdate.IsEnabled = $false
        $script:BtnInstallCoreUpdate.IsEnabled = $false
        Set-LauncherStatus "正在恢复版本依赖" "#6F85FF"
        Append-Console (
            "[DEPENDENCY] Repair started for ComfyUI " + $script:coreVersion
        )
    }
    catch {
        if ($wasRunning -and -not (Test-ComfyUIRunning)) {
            Start-ComfyUI
        }
        $script:dependencyRepairJob = $null
        $script:InventoryStatusText.Text = "无法开始恢复：" + $_.Exception.Message
        $script:InventoryStatusText.Foreground = Get-Brush "#FF8D99"
        $script:BtnInventoryScan.Content = "修复整合包"
        $script:BtnInventoryScan.IsEnabled = Test-OnlineCoreMaintenanceEnabled
        Update-CoreUpdateAvailability
    }
}

function Complete-DependencyRepair {
    if ($null -eq $script:dependencyRepairJob) {
        return
    }

    $status = $null
    if (-not [string]::IsNullOrWhiteSpace($script:dependencyRepairStatusPath) -and
        [System.IO.File]::Exists($script:dependencyRepairStatusPath)) {
        try {
            $statusJson = [System.IO.File]::ReadAllText(
                $script:dependencyRepairStatusPath,
                $script:utf8
            )
            if (-not [string]::IsNullOrWhiteSpace($statusJson)) {
                $status = $statusJson | ConvertFrom-Json
                if ($statusJson -ne $script:dependencyRepairLastStatusJson) {
                    $script:dependencyRepairLastStatusJson = $statusJson
                    $script:InventoryStatusText.Text = [string]$status.message
                    $script:InventoryStatusText.Foreground = Get-Brush "#AAB5BE"
                    $percent = [int]$status.percent
                    if ($percent -ge 0 -and $percent -le 100) {
                        $script:InventoryProgress.IsIndeterminate = $false
                        $script:InventoryProgress.Minimum = 0
                        $script:InventoryProgress.Maximum = 100
                        $script:InventoryProgress.Value = $percent
                    }
                    else {
                        $script:InventoryProgress.IsIndeterminate = $true
                    }
                    if ([string]$status.stage -ne $script:dependencyRepairLastStage) {
                        $script:dependencyRepairLastStage = [string]$status.stage
                        Append-Console (
                            "[DEPENDENCY] {0}: {1}" -f
                            [string]$status.stage,
                            [string]$status.message
                        )
                    }
                }
            }
        }
        catch {
            # Atomic status writes may briefly race with security software.
        }
    }

    $jobState = [string]$script:dependencyRepairJob.State
    if ($jobState -notin @("Completed", "Failed", "Stopped")) {
        return
    }

    $jobOutput = ""
    $jobErrors = @()
    try {
        $jobOutput = Receive-Job `
            -Job $script:dependencyRepairJob `
            -ErrorVariable jobErrors `
            -ErrorAction SilentlyContinue |
            Out-String
    }
    catch {
        $jobErrors += $_
    }
    try {
        Remove-Job `
            -Job $script:dependencyRepairJob `
            -Force `
            -ErrorAction SilentlyContinue
    }
    catch {
    }
    $script:dependencyRepairJob = $null

    $script:InventoryProgress.Visibility = [System.Windows.Visibility]::Collapsed
    $script:BtnInventoryScan.Content = "修复整合包"
    $script:BtnInventoryScan.IsEnabled = Test-OnlineCoreMaintenanceEnabled
    $restartAfter = [bool]$script:dependencyRepairRestartAfter
    $script:dependencyRepairRestartAfter = $false

    $success = (
        $null -ne $status -and
        [bool]$status.completed -and
        [bool]$status.success
    )
    if ($success) {
        $script:InventoryStatusText.Text = "版本依赖恢复完成 · " +
            [DateTime]::Now.ToString("MM-dd HH:mm")
        $script:InventoryStatusText.Foreground = Get-Brush "#79D99D"
        Set-LauncherStatus (Get-UiText "StatusReady") "#7F8B97"
        Append-Console "[DEPENDENCY] Repair completed; core health check passed."
        if ($restartAfter) {
            Start-ComfyUI
        }
    }
    else {
        $reason = "依赖恢复进程异常结束。"
        if ($null -ne $status -and
            -not [string]::IsNullOrWhiteSpace([string]$status.message)) {
            $reason = [string]$status.message
        }
        elseif ($jobErrors.Count -gt 0) {
            $reason = [string]$jobErrors[0]
        }
        elseif (-not [string]::IsNullOrWhiteSpace($jobOutput)) {
            $reason = $jobOutput.Trim()
        }
        $script:InventoryStatusText.Text = $reason
        $script:InventoryStatusText.Foreground = Get-Brush "#FF8D99"
        Set-LauncherStatus (Get-UiText "StatusReady") "#7F8B97"
        Append-Console ("[DEPENDENCY] Repair failed: " + $reason)
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            $reason,
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
        if ($restartAfter -and -not (Test-ComfyUIRunning)) {
            Start-ComfyUI
        }
    }

    foreach ($transientPath in @(
        $script:dependencyRepairRequestPath,
        $script:dependencyRepairStatusPath
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$transientPath) -and
            [System.IO.File]::Exists([string]$transientPath)) {
            try {
                [System.IO.File]::Delete([string]$transientPath)
            }
            catch {
            }
        }
    }
    $script:dependencyRepairRequestPath = ""
    $script:dependencyRepairStatusPath = ""
    Update-CoreUpdateAvailability
}

function Test-ShouldAutoCheckUpdates {
    if ($script:AutoUpdateCheck.IsChecked -ne $true) {
        return $false
    }
    $lastCheck = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        [string]$script:launcherSettings.updates.lastCheckUtc,
        [ref]$lastCheck
    )) {
        return $true
    }
    return (([DateTimeOffset]::UtcNow - $lastCheck).TotalHours -ge 24)
}

function Get-SelectedMode {
    $selectedItem = $script:PresetCombo.SelectedItem
    if ($null -eq $selectedItem) {
        return "auto"
    }
    return [string]$selectedItem.Tag
}

function Get-SelectedModeLabel {
    $selectedItem = $script:PresetCombo.SelectedItem
    if ($null -eq $selectedItem) {
        return "Auto"
    }
    return [string]$selectedItem.Content
}

function Get-ConfiguredPort {
    $port = 0
    if (-not [int]::TryParse($script:PortBox.Text.Trim(), [ref]$port)) {
        return 0
    }
    if ($port -lt 1024 -or $port -gt 65535) {
        return 0
    }
    return $port
}

function Update-LauncherSummary {
    $port = Get-ConfiguredPort
    if ($port -eq 0) {
        $port = 1080
    }
    $script:ModeText.Text = Get-SelectedModeLabel
    $script:AddressText.Text = "http://127.0.0.1:$port"
}

function Open-ShellTarget {
    param([string]$Target)

    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $Target
        $startInfo.UseShellExecute = $true
        [void][System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            $_.Exception.Message,
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
}

function Open-PackageFolder {
    param([string]$RelativePath)

    $target = $script:root
    if (-not [string]::IsNullOrEmpty($RelativePath)) {
        $target = [System.IO.Path]::GetFullPath((Join-Path $script:root $RelativePath))
        if ([System.IO.Path]::GetDirectoryName($target) -ne $script:root) {
            throw "Folder target is outside the package root: $target"
        }
    }

    if (-not [System.IO.Directory]::Exists($target)) {
        [void][System.IO.Directory]::CreateDirectory($target)
    }
    Open-ShellTarget $target
}

function Remove-DirectoryTreeWithoutFollowingReparse {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ApprovedRoot
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($ApprovedRoot).TrimEnd("\")
    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not $normalizedPath.StartsWith(
        $normalizedRoot + "\",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to delete a tree outside the approved root: $normalizedPath"
    }

    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push([pscustomobject]@{
        Path = $normalizedPath
        Expanded = $false
    })

    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $itemPath = [System.IO.Path]::GetFullPath([string]$item.Path)
        if (-not $itemPath.StartsWith(
            $normalizedRoot + "\",
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to traverse outside the approved root: $itemPath"
        }

        $attributes = [System.IO.File]::GetAttributes($itemPath)
        $isReparsePoint = (
            ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        )
        if ($isReparsePoint) {
            [System.IO.Directory]::Delete($itemPath, $false)
            continue
        }

        if ($item.Expanded) {
            [System.IO.File]::SetAttributes(
                $itemPath,
                $attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
            )
            [System.IO.Directory]::Delete($itemPath, $false)
            continue
        }

        $stack.Push([pscustomobject]@{
            Path = $itemPath
            Expanded = $true
        })
        foreach ($childPath in [System.IO.Directory]::EnumerateFileSystemEntries($itemPath)) {
            $normalizedChild = [System.IO.Path]::GetFullPath($childPath)
            if (-not $normalizedChild.StartsWith(
                $normalizedRoot + "\",
                [System.StringComparison]::OrdinalIgnoreCase
            )) {
                throw "Refusing to traverse an unsafe child path: $normalizedChild"
            }

            $childAttributes = [System.IO.File]::GetAttributes($normalizedChild)
            $isDirectory = (
                ($childAttributes -band [System.IO.FileAttributes]::Directory) -ne 0
            )
            $childIsReparsePoint = (
                ($childAttributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            )
            if ($isDirectory) {
                if ($childIsReparsePoint) {
                    [System.IO.Directory]::Delete($normalizedChild, $false)
                }
                else {
                    $stack.Push([pscustomobject]@{
                        Path = $normalizedChild
                        Expanded = $false
                    })
                }
            }
            else {
                [System.IO.File]::SetAttributes(
                    $normalizedChild,
                    $childAttributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                )
                [System.IO.File]::Delete($normalizedChild)
            }
        }
    }
}

function Clear-ApprovedFolderContents {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("temp")]
        [string[]]$FolderNames
    )

    $resolvedRoot = [System.IO.Path]::GetFullPath($script:root).TrimEnd("\")
    foreach ($folderName in $FolderNames) {
        $folderPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $folderName))
        if ([System.IO.Path]::GetDirectoryName($folderPath) -ne $resolvedRoot) {
            throw "Refusing to clean an unsafe path: $folderPath"
        }

        if (-not [System.IO.Directory]::Exists($folderPath)) {
            [void][System.IO.Directory]::CreateDirectory($folderPath)
            continue
        }

        foreach ($child in @(Get-ChildItem -LiteralPath $folderPath -Force -ErrorAction SilentlyContinue)) {
            $childPath = [System.IO.Path]::GetFullPath($child.FullName)
            if ([System.IO.Path]::GetDirectoryName($childPath) -ne $folderPath) {
                throw "Refusing to clean a non-direct child: $childPath"
            }

            $isReparsePoint = (
                ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            )
            if ($child.PSIsContainer) {
                if ($isReparsePoint) {
                    [System.IO.Directory]::Delete($childPath, $false)
                }
                else {
                    Remove-DirectoryTreeWithoutFollowingReparse `
                        -Path $childPath `
                        -ApprovedRoot $folderPath
                }
            }
            else {
                $child.Attributes = $child.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                [System.IO.File]::Delete($childPath)
            }
        }
    }
}

function Invoke-RuntimeTempCleanup {
    param([switch]$Silent)

    Clear-ApprovedFolderContents @("temp")

    if (-not $Silent) {
        Set-LauncherStatus (Get-UiText "StatusTempCleaned") "#ECFF3D"
        Append-LauncherLog "LogTempCleaned"
    }
}

function Test-TcpPort {
    param([int]$Port)

    $client = New-Object System.Net.Sockets.TcpClient
    $asyncResult = $null
    try {
        $asyncResult = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne(100, $false)) {
            return $false
        }
        if (-not $client.Connected) {
            return $false
        }
        $client.EndConnect($asyncResult)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $asyncResult) {
            $asyncResult.AsyncWaitHandle.Close()
        }
        $client.Close()
    }
}

function Read-NewLogContent {
    param(
        [string]$Path,
        [long]$Offset
    )

    $result = [pscustomobject]@{
        Text = ""
        Offset = $Offset
    }

    if ([string]::IsNullOrEmpty($Path) -or -not [System.IO.File]::Exists($Path)) {
        return $result
    }

    $stream = $null
    $reader = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        )
        if ($Offset -gt $stream.Length) {
            $Offset = 0
        }
        [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream, $script:utf8, $true)
        $result.Text = $reader.ReadToEnd()
        $result.Offset = $stream.Position
    }
    catch {
        return $result
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }

    return $result
}

function Read-PendingLogs {
    if (-not [string]::IsNullOrEmpty($script:stdoutPath)) {
        $stdoutResult = Read-NewLogContent $script:stdoutPath $script:stdoutOffset
        $script:stdoutOffset = $stdoutResult.Offset
        if (-not [string]::IsNullOrEmpty($stdoutResult.Text)) {
            Append-Console $stdoutResult.Text
        }
    }

    if (-not [string]::IsNullOrEmpty($script:stderrPath)) {
        $stderrResult = Read-NewLogContent $script:stderrPath $script:stderrOffset
        $script:stderrOffset = $stderrResult.Offset
        if (-not [string]::IsNullOrEmpty($stderrResult.Text)) {
            Append-Console $stderrResult.Text
        }
    }
}

function Remove-TemporaryLogs {
    foreach ($logPath in @($script:stdoutPath, $script:stderrPath)) {
        if (-not [string]::IsNullOrEmpty($logPath) -and [System.IO.File]::Exists($logPath)) {
            try {
                [System.IO.File]::Delete($logPath)
            }
            catch {
                # Temporary logs can be reclaimed by Windows if a process is still releasing them.
            }
        }
    }
    $script:stdoutPath = ""
    $script:stderrPath = ""
    $script:stdoutOffset = 0
    $script:stderrOffset = 0
}

function Test-ComfyUIRunning {
    if ($null -eq $script:comfyProcess) {
        return $false
    }
    try {
        return (-not $script:comfyProcess.HasExited)
    }
    catch {
        return $false
    }
}

function Test-ComfyUIProcessExited {
    param(
        [object]$Process,
        [int]$ProcessId
    )

    if ($null -ne $Process) {
        try {
            return [bool]$Process.HasExited
        }
        catch {
        }
    }
    if ($ProcessId -le 0) {
        return $false
    }

    $existingProcess = $null
    try {
        $existingProcess = [System.Diagnostics.Process]::GetProcessById(
            $ProcessId
        )
        return $false
    }
    catch [System.ArgumentException] {
        return $true
    }
    catch {
        # Access or inspection failures must never be treated as a confirmed
        # stop when a maintenance operation may mutate files.
        return $false
    }
    finally {
        if ($null -ne $existingProcess) {
            try {
                $existingProcess.Dispose()
            }
            catch {
            }
        }
    }
}

function Enter-ComfyUIChildEnvironment {
    $embeddedBinaryPath = Join-Path $root ".ext\Library\bin"
    $bundledSoxPath = Join-Path $root "tools\sox"
    $currentProcessPath = [Environment]::GetEnvironmentVariable(
        "PATH",
        [EnvironmentVariableTarget]::Process
    )
    $childProcessPath = if ([string]::IsNullOrWhiteSpace($currentProcessPath)) {
        $bundledSoxPath + ";" + $embeddedBinaryPath
    }
    else {
        $bundledSoxPath + ";" + $embeddedBinaryPath + ";" + $currentProcessPath
    }

    $values = [ordered]@{
        "PATH" = $childProcessPath
        "TORCHDYNAMO_DISABLE" = "1"
        "CUDA_MODULE_LOADING" = "LAZY"
        "PYTORCH_CUDA_ALLOC_CONF" = "expandable_segments:True"
        "PYTHONUNBUFFERED" = "1"
        "PYTHONIOENCODING" = "utf-8"
        "NUMBA_CACHE_DIR" = Join-Path $root "user\cache\numba"
        "NO_ALBUMENTATIONS_UPDATE" = "1"
        "COMFYUI_MANAGER_SKIP_STARTUP_REFRESH" = "1"
        "HF_ENDPOINT" = Get-LauncherHuggingFaceEndpoint $script:launcherSettings
        "PIP_INDEX_URL" = Get-LauncherPypiIndexUrl $script:launcherSettings
    }

    switch ([string]$script:launcherSettings.network.proxy.mode) {
        "none" {
            foreach ($name in @(
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "all_proxy"
            )) {
                $values[$name] = $null
            }
            $values["NO_PROXY"] = "*"
            $values["no_proxy"] = "*"
        }
        "custom" {
            $proxyUri = Get-LauncherProxyUri $script:launcherSettings
            if ($null -eq $proxyUri) {
                throw "自定义代理地址或端口无效。"
            }
            $proxyText = $proxyUri.AbsoluteUri
            foreach ($name in @(
                "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                "http_proxy", "https_proxy", "all_proxy"
            )) {
                $values[$name] = $proxyText
            }
            $values["NO_PROXY"] = "127.0.0.1,localhost"
            $values["no_proxy"] = "127.0.0.1,localhost"
        }
    }

    $original = @{}
    try {
        foreach ($entry in $values.GetEnumerator()) {
            $originalValue = [Environment]::GetEnvironmentVariable(
                $entry.Key,
                [EnvironmentVariableTarget]::Process
            )
            $original[$entry.Key] = [pscustomobject]@{
                # The IDictionary returned by GetEnvironmentVariables is
                # case-sensitive even though Windows environment names are
                # not.  It normally exposes `Path`, so Contains("PATH") is
                # false and the old code deleted Path after launching Python.
                Exists = ($null -ne $originalValue)
                Value = $originalValue
            }
            [Environment]::SetEnvironmentVariable(
                $entry.Key,
                $entry.Value,
                [EnvironmentVariableTarget]::Process
            )
        }
    }
    catch {
        foreach ($name in $original.Keys) {
            if ($original[$name].Exists) {
                [Environment]::SetEnvironmentVariable(
                    $name,
                    $original[$name].Value,
                    [EnvironmentVariableTarget]::Process
                )
            }
            else {
                Remove-Item `
                    -LiteralPath ("Env:" + $name) `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
        throw
    }

    return [pscustomobject]@{
        Original = $original
    }
}

function Exit-ComfyUIChildEnvironment {
    param([object]$Scope)

    if ($null -eq $Scope) {
        return
    }
    foreach ($name in $Scope.Original.Keys) {
        if ($Scope.Original[$name].Exists) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $Scope.Original[$name].Value,
                [EnvironmentVariableTarget]::Process
            )
        }
        else {
            Remove-Item `
                -LiteralPath ("Env:" + $name) `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Set-RunningControls {
    param([bool]$Running)

    $script:BtnStart.IsEnabled = -not $Running
    $script:BtnAdvancedStart.IsEnabled = -not $Running
    $script:BtnStop.IsEnabled = $Running
    $script:BtnRestart.IsEnabled = $Running
}

function Set-ExtensionMaintenanceControls {
    param([bool]$Busy)

    if ($Busy) {
        $script:BtnStart.IsEnabled = $false
        $script:BtnAdvancedStart.IsEnabled = $false
        $script:BtnStop.IsEnabled = $false
        $script:BtnRestart.IsEnabled = $false
        return
    }
    Set-RunningControls (Test-ComfyUIRunning)
}

function Open-ComfyUIWeb {
    $port = $script:activePort
    if ($port -eq 0) {
        $port = Get-ConfiguredPort
    }
    if ($port -eq 0) {
        $port = 1080
    }
    Open-ShellTarget "http://127.0.0.1:$port"
}

function Finalize-ComfyUIProcess {
    param([switch]$ManualStop)

    if ($null -eq $script:comfyProcess) {
        return
    }

    $startupFailed = (-not $ManualStop -and -not $script:portReady)
    Read-PendingLogs
    $exitCode = -1
    try {
        $exitCode = $script:comfyProcess.ExitCode
    }
    catch {
        $exitCode = -1
    }

    if ($ManualStop) {
        Set-LauncherStatus (Get-UiText "StatusStopped") "#7F8B97"
    }
    else {
        Set-LauncherStatus (Get-UiText "StatusExited" @($exitCode)) "#FF6475"
    }

    $failureLogPath = ""
    if ($startupFailed) {
        $failureLogPath = Save-LastStartupFailureLog `
            -Reason ("ComfyUI 进程退出，代码 {0}" -f $exitCode)
    }

    Set-RunningControls $false
    $script:BtnConsoleOpenWeb.IsEnabled = $false
    $script:portReady = $false
    $script:browserOpened = $false
    $script:activePort = 0

    try {
        $script:comfyProcess.Dispose()
    }
    catch {
    }
    $script:comfyProcess = $null
    $script:launchState = "Idle"

    if ($startupFailed -and -not $script:isClosing) {
        Show-LauncherPage $script:PageConsole $script:NavConsole
        $message = (
            "ComfyUI 没有启动成功，错误信息已保留在控制台。" +
            [Environment]::NewLine + [Environment]::NewLine +
            "退出代码：$exitCode"
        )
        if (-not [string]::IsNullOrWhiteSpace($failureLogPath)) {
            $message += (
                [Environment]::NewLine +
                "诊断日志：" + $failureLogPath +
                [Environment]::NewLine + [Environment]::NewLine +
                "请把该日志文件发给老师。"
            )
        }
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            $message,
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }

    if ($script:AutoTempCleanCheck.IsChecked -eq $true) {
        try {
            Invoke-RuntimeTempCleanup -Silent
        }
        catch {
            Append-Console ("Cleanup warning: " + $_.Exception.Message)
        }
    }

    Remove-TemporaryLogs
}

function Resolve-NvidiaSmiExecutable {
    $candidates = New-Object System.Collections.Generic.List[string]
    $systemRoot = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::Windows
    )
    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        $candidates.Add((Join-Path $systemRoot "System32\nvidia-smi.exe"))
    }
    try {
        $command = Get-Command "nvidia-smi.exe" -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            $candidates.Add([string]$command.Source)
        }
    }
    catch {
    }
    $programFiles = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::ProgramFiles
    )
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $candidates.Add((Join-Path `
            $programFiles `
            "NVIDIA Corporation\NVSMI\nvidia-smi.exe"
        ))
    }
    foreach ($candidate in $candidates) {
        if ([System.IO.File]::Exists($candidate)) {
            return [System.IO.Path]::GetFullPath($candidate)
        }
    }
    throw "nvidia-smi.exe was not found."
}

function Test-ReleaseRuntimePrerequisites {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw "当前系统不是 64 位 Windows，无法运行此整合包。"
    }

    $stateDirectory = Join-Path $script:root "user\launcher"
    if (-not [System.IO.Directory]::Exists($stateDirectory)) {
        [void][System.IO.Directory]::CreateDirectory($stateDirectory)
    }
    $writeProbe = Join-Path $stateDirectory (
        ".write-test-" + [Guid]::NewGuid().ToString("N") + ".tmp"
    )
    try {
        [System.IO.File]::WriteAllText($writeProbe, "ok", $script:utf8)
    }
    catch {
        throw "整合包所在目录不可写。请先完整解压到本地磁盘，不要直接在压缩包或受保护目录中运行。"
    }
    finally {
        if ([System.IO.File]::Exists($writeProbe)) {
            [System.IO.File]::Delete($writeProbe)
        }
    }

    $rootPath = [System.IO.Path]::GetPathRoot($script:root)
    $drive = New-Object System.IO.DriveInfo($rootPath)
    if ($drive.AvailableFreeSpace -lt 5GB) {
        throw (
            "磁盘剩余空间不足 5 GB。当前可用约 {0:N1} GB，请清理空间后重试。" -f
            ($drive.AvailableFreeSpace / 1GB)
        )
    }

    $result = [ordered]@{
        UseCpu = $false
        Warning = ""
        DriverVersion = ""
        MinimumDriverVersion = "528.33"
    }
    $gpuRows = @()
    try {
        $nvidiaSmi = Resolve-NvidiaSmiExecutable
        $gpuRows = @(
            & $nvidiaSmi `
                "--query-gpu=name,driver_version" `
                "--format=csv,noheader,nounits" `
                2>$null
        )
        if ($LASTEXITCODE -ne 0 -or $gpuRows.Count -eq 0) {
            throw "nvidia-smi did not return a device."
        }
    }
    catch {
        $result.UseCpu = $true
        $result.Warning = (
            "未检测到可用的 NVIDIA 显卡驱动。可以继续使用 CPU 兼容模式启动，" +
            "但生成速度会非常慢。建议安装 NVIDIA 官方驱动后再使用 GPU。"
        )
        return [pscustomobject]$result
    }

    $driverVersions = @(
        foreach ($row in $gpuRows) {
            $text = ([string]$row).Trim()
            $separator = $text.LastIndexOf(",")
            if ($separator -lt 1 -or $separator -ge ($text.Length - 1)) {
                continue
            }
            $driverText = $text.Substring($separator + 1).Trim()
            $driverMatch = [regex]::Match(
                $driverText,
                "^(?<major>[0-9]+)(?:\.(?<minor>[0-9]+))?"
            )
            if ($driverMatch.Success) {
                $minor = if ($driverMatch.Groups["minor"].Success) {
                    [int]$driverMatch.Groups["minor"].Value
                }
                else {
                    0
                }
                [pscustomobject]@{
                    Name = $text.Substring(0, $separator).Trim()
                    Version = $driverText
                    Major = [int]$driverMatch.Groups["major"].Value
                    Minor = $minor
                    Comparable = New-Object System.Version(
                        [int]$driverMatch.Groups["major"].Value,
                        $minor
                    )
                }
            }
        }
    )
    if ($driverVersions.Count -eq 0) {
        $result.UseCpu = $true
        $result.Warning = (
            "无法读取 NVIDIA 驱动版本。可以继续使用 CPU 兼容模式启动，" +
            "或安装 NVIDIA 官方驱动后重试。"
        )
        return [pscustomobject]$result
    }
    $outdatedDrivers = @(
        $driverVersions | Where-Object {
            $_.Comparable -lt (New-Object System.Version(528, 33))
        }
    )
    if ($outdatedDrivers.Count -gt 0) {
        $details = @(
            $outdatedDrivers |
                ForEach-Object { "$($_.Name) - $($_.Version)" }
        ) -join "；"
        $result.UseCpu = $true
        $result.Warning = (
            "NVIDIA 驱动版本过低（{0}）。本整合包使用 CUDA 12.8 兼容运行环境，" +
            "GPU 模式至少需要 528.33 驱动。可以先用 CPU 兼容模式启动，" +
            "或更新 NVIDIA 官方驱动后使用 GPU。"
        ) -f $details
        return [pscustomobject]$result
    }
    $result.DriverVersion = [string]$driverVersions[0].Version
    return [pscustomobject]$result
}

function Start-ComfyUI {
    if (Test-ComfyUIRunning -or $script:launchState -ne "Idle") {
        return
    }
    if ($null -ne $script:extensionJob -and
        $script:extensionJobIsMutation) {
        Set-LauncherStatus "扩展维护完成后才能启动 ComfyUI" "#FFCC66"
        return
    }

    $script:launchState = "Preparing"
    $port = Get-ConfiguredPort
    if ($port -eq 0) {
        $script:launchState = "Idle"
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            (Get-UiText "InvalidPort"),
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    if (Test-TcpPort $port) {
        $script:launchState = "Idle"
        Set-LauncherStatus (Get-UiText "StatusPortBusy" @($port)) "#FFB454"
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            (Get-UiText "PortBusyMessage" @($port)),
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        )
        return
    }

    try {
        $runtimeCompatibility = Test-ReleaseRuntimePrerequisites
        $useCpuCompatibilityMode = [bool]$runtimeCompatibility.UseCpu
        if ($useCpuCompatibilityMode) {
            $cpuAnswer = [System.Windows.MessageBox]::Show(
                $script:window,
                ([string]$runtimeCompatibility.Warning +
                    [Environment]::NewLine + [Environment]::NewLine +
                    "是否继续使用 CPU 兼容模式启动？"),
                (Get-UiText "DialogTitle"),
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($cpuAnswer -ne [System.Windows.MessageBoxResult]::Yes) {
                $script:launchState = "Idle"
                Set-LauncherStatus "等待更新显卡驱动" "#FFCC66"
                return
            }
        }

        if ($script:AutoTempCleanCheck.IsChecked -eq $true) {
            Invoke-RuntimeTempCleanup -Silent
        }

        $arguments = @(
            "-s",
            "main.py",
            "--listen",
            "127.0.0.1",
            "--port",
            [string]$port
        )
        if ($useCpuCompatibilityMode) {
            $arguments += "--cpu"
        }
        else {
            $mode = Get-SelectedMode
            switch ($mode) {
                "lowvram" { $arguments += "--lowvram" }
                "normalvram" { $arguments += "--normalvram" }
                "highvram" { $arguments += "--highvram" }
            }
        }

        $token = [Guid]::NewGuid().ToString("N")
        $script:stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ComfyUI-Launcher-{0}.out.log" -f $token)
        $script:stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ("ComfyUI-Launcher-{0}.err.log" -f $token)
        $script:stdoutOffset = 0
        $script:stderrOffset = 0

        # TEMPORARY PROCESS-WIDE ENVIRONMENT SCOPE. NOT THREAD-SAFE.
        # Do not start any other child process until the scope has been restored.
        $script:launchState = "PreparingEnvironment"
        $environmentScope = Enter-ComfyUIChildEnvironment
        try {
            $script:launchState = "StartingProcess"
            $script:comfyProcess = Start-Process `
                -FilePath $script:pythonPath `
                -ArgumentList $arguments `
                -WorkingDirectory $script:root `
                -WindowStyle Hidden `
                -RedirectStandardOutput $script:stdoutPath `
                -RedirectStandardError $script:stderrPath `
                -PassThru
        }
        finally {
            $script:launchState = "RestoringEnvironment"
            Exit-ComfyUIChildEnvironment $environmentScope
        }

        $script:activePort = $port
        $script:portReady = $false
        $script:browserOpened = $false
        $script:launchState = "Started"
        Set-RunningControls $true
        Set-LauncherStatus (Get-UiText "StatusStarting" @($port)) "#FFCC66"
        Update-LauncherSummary
        Append-LauncherLog "LogStarting" @(($script:pythonPath + " " + ($arguments -join " ")))
        if ($useCpuCompatibilityMode) {
            Append-Console "[COMPAT] CPU compatibility mode enabled because the NVIDIA runtime is unavailable."
        }
    }
    catch {
        if ($null -ne $script:comfyProcess) {
            try {
                $script:comfyProcess.Dispose()
            }
            catch {
            }
            $script:comfyProcess = $null
        }
        Remove-TemporaryLogs
        Set-RunningControls $false
        $script:launchState = "Idle"
        Set-LauncherStatus (Get-UiText "StatusFailed") "#FF6475"
        $failureLogPath = Save-LastStartupFailureLog -Reason $_.Exception.Message
        $failureMessage = Get-UiText "StartFailedMessage" @($_.Exception.Message)
        if (-not [string]::IsNullOrWhiteSpace($failureLogPath)) {
            $failureMessage += (
                [Environment]::NewLine + [Environment]::NewLine +
                "诊断日志：" + $failureLogPath
            )
        }
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            $failureMessage,
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        )
    }
}

function Stop-ComfyUI {
    param([switch]$RestartAfter)

    if ($null -eq $script:comfyProcess) {
        if ($RestartAfter) {
            Start-ComfyUI
        }
        return $true
    }

    $process = $script:comfyProcess
    $processId = 0
    try {
        $processId = [int]$process.Id
    }
    catch {
        Set-LauncherStatus "无法确认 ComfyUI 进程状态" "#FF6475"
        Append-Console (
            "[STOP] Unable to resolve the ComfyUI process id; stop not confirmed."
        )
        return $false
    }
    if (Test-ComfyUIProcessExited -Process $process -ProcessId $processId) {
        Finalize-ComfyUIProcess -ManualStop
        if ($RestartAfter) {
            Start-ComfyUI
        }
        return $true
    }

    Set-LauncherStatus (Get-UiText "StatusStopping") "#FFCC66"
    Append-LauncherLog "LogStopping"

    $taskkillError = ""
    try {
        $taskkillPath = Join-Path $env:SystemRoot "System32\taskkill.exe"
        $taskkillProcess = Start-Process `
            -FilePath $taskkillPath `
            -ArgumentList @("/PID", [string]$processId, "/T", "/F") `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        try {
            [void]$process.WaitForExit(5000)
        }
        catch {
        }
        try {
            $taskkillProcess.Dispose()
        }
        catch {
        }
    }
    catch {
        $taskkillError = $_.Exception.Message
    }

    if (-not (Test-ComfyUIProcessExited -Process $process -ProcessId $processId)) {
        try {
            $process.Kill()
            [void]$process.WaitForExit(3000)
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($taskkillError)) {
                $taskkillError = $_.Exception.Message
            }
        }
    }

    $processExited = Test-ComfyUIProcessExited `
        -Process $process `
        -ProcessId $processId
    $portReleased = $true
    $stopPort = [int]$script:activePort
    if ($processExited -and $stopPort -gt 0) {
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            if (-not (Test-TcpPort $stopPort)) {
                break
            }
            Start-Sleep -Milliseconds 100
        }
        $portReleased = -not (Test-TcpPort $stopPort)
    }
    if (-not $processExited -or -not $portReleased) {
        $reason = if (-not $processExited) {
            "进程仍在运行"
        }
        else {
            "监听端口仍未释放"
        }
        if (-not [string]::IsNullOrWhiteSpace($taskkillError)) {
            $reason += "：" + (
                ConvertTo-LauncherSafeDiagnosticText $taskkillError
            )
        }
        Set-LauncherStatus "ComfyUI 停止失败" "#FF6475"
        Append-Console ("[STOP] Stop not confirmed: " + $reason)
        Set-RunningControls $true
        return $false
    }

    Finalize-ComfyUIProcess -ManualStop
    if ($RestartAfter) {
        Start-ComfyUI
    }
    return $true
}

function Initialize-GpuSummary {
    try {
        $nvidiaSmi = Resolve-NvidiaSmiExecutable
        $gpuRows = @(& $nvidiaSmi "--query-gpu=name,memory.total,driver_version" "--format=csv,noheader,nounits" 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gpuRows.Count -gt 0) {
            $displayRows = @()
            foreach ($gpuRow in $gpuRows) {
                $parts = @($gpuRow -split "," | ForEach-Object { $_.Trim() })
                if ($parts.Count -ge 3) {
                    $displayRows += ("{0}  |  {1} MB" -f $parts[0], $parts[1])
                }
                else {
                    $displayRows += $gpuRow
                }
            }
            $script:GpuText.Text = $displayRows -join [Environment]::NewLine
            return
        }
    }
    catch {
    }
    $script:GpuText.Text = Get-UiText "GpuUnavailable"
}

function Set-WorkflowShowcaseSlide {
    param([int]$Index)

    $count = @($script:workflowShowcaseItems).Count
    if ($count -eq 0) {
        return
    }

    $normalizedIndex = (($Index % $count) + $count) % $count
    $script:workflowShowcaseIndex = $normalizedIndex
    $item = $script:workflowShowcaseItems[$normalizedIndex]

    $script:WorkflowShowcaseTitle.Text = [string]$item.Title
    $script:WorkflowShowcaseSubtitle.Text = [string]$item.Subtitle
    $script:WorkflowShowcasePrimaryTag.Text = [string]$item.PrimaryTag
    $script:WorkflowShowcaseSecondaryTag.Text = [string]$item.SecondaryTag
    $script:WorkflowShowcaseCounter.Text = "{0:D2} / {1:D2}" -f ($normalizedIndex + 1), $count

    $dots = @(
        $script:WorkflowShowcaseDot1,
        $script:WorkflowShowcaseDot2,
        $script:WorkflowShowcaseDot3,
        $script:WorkflowShowcaseDot4
    )
    for ($dotIndex = 0; $dotIndex -lt $dots.Count; $dotIndex++) {
        if ($dotIndex -eq $normalizedIndex) {
            $dots[$dotIndex].Fill = Get-Brush "#7F92FF"
        }
        else {
            $dots[$dotIndex].Fill = [System.Windows.Media.Brushes]::Transparent
        }
    }

    try {
        if (-not [System.IO.File]::Exists([string]$item.ImagePath)) {
            throw "Showcase image is missing: $($item.ImagePath)"
        }
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bitmap.DecodePixelWidth = 960
        $bitmap.UriSource = New-Object System.Uri(
            [string]$item.ImagePath,
            [System.UriKind]::Absolute
        )
        $bitmap.EndInit()
        $bitmap.Freeze()
        $imageBrush = New-Object System.Windows.Media.ImageBrush
        $imageBrush.ImageSource = $bitmap
        $imageBrush.Stretch = [System.Windows.Media.Stretch]::UniformToFill
        $imageBrush.AlignmentX = [System.Windows.Media.AlignmentX]::Center
        $imageBrush.AlignmentY = [System.Windows.Media.AlignmentY]::Center
        $imageBrush.Freeze()
        $script:WorkflowShowcaseImageSurface.Background = $imageBrush
    }
    catch {
        $script:WorkflowShowcaseImageSurface.Background = Get-Brush "#080D13"
        $script:WorkflowShowcaseSubtitle.Text = "本地预览暂不可用"
    }
}

function Move-WorkflowShowcase {
    param([int]$Offset)

    Set-WorkflowShowcaseSlide ($script:workflowShowcaseIndex + $Offset)
}

$script:comfyProcess = $null
$script:stdoutPath = ""
$script:stderrPath = ""
$script:stdoutOffset = 0
$script:stderrOffset = 0
$script:activePort = 0
$script:portReady = $false
$script:browserOpened = $false
$script:isClosing = $false
$script:launchState = "Idle"
$script:launcherSettings = $launcherSettings
$script:launcherVersionInfo = $launcherVersionInfo
$script:settingsPath = $settingsPath
$script:coreVersionPath = $coreVersionPath
$script:coreUpdaterPath = $coreUpdaterPath
$script:utf8 = $utf8
$script:coreVersion = Get-CoreVersion
$script:networkProbeJobs = New-Object System.Collections.ArrayList
$script:networkResults = @{}
$script:networkCurrentOps = @{}
$script:updateRequest = $null
$script:currentUpdateOpId = ""
$script:settingsGeneration = 0
$script:inventoryPath = Join-Path $root "user\launcher\state\inventory.json"
$script:inventoryJob = $null
$script:lastInventoryScanSucceeded = $false
$script:dependencyRepairJob = $null
$script:dependencyRepairRequestPath = ""
$script:dependencyRepairStatusPath = ""
$script:dependencyRepairLastStatusJson = ""
$script:dependencyRepairLastStage = ""
$script:dependencyRepairRestartAfter = $false
$script:coreUpdateAvailable = $false
$script:latestCoreVersion = ""
$script:latestCoreReleaseUrl = ""
$script:coreUpdateJob = $null
$script:coreUpdateRequestPath = ""
$script:coreUpdateStatusPath = ""
$script:coreUpdateLastStatusJson = ""
$script:coreUpdateLastStage = ""
$script:coreUpdateRestartAfter = $false
$script:extensionWorkerPath = $extensionWorkerPath
$script:extensionJob = $null
$script:extensionJobStartedUtc = [DateTimeOffset]::MinValue
$script:extensionJobAction = ""
$script:extensionJobQuery = ""
$script:extensionJobIsMutation = $false
$script:extensionRestartAfter = $false
$script:extensionPostMutationRefresh = $false
$script:installedExtensionsLoaded = $false
$script:extensionCatalogLoaded = $false
$script:extensionCatalogInitialRefreshAttempted = $false
$script:installedExtensionItems = @()
$script:extensionCatalogItems = @()
$script:pendingCatalogQuery = $null
$script:extensionCatalogSearchTimer = $null
$script:homeNoticeTarget = ""
$script:workflowShowcaseIndex = 0
$script:workflowShowcaseTimer = $null
$script:runLogExportPathProvider = $null
$script:runLogExportNotificationHandler = $null
$script:workflowShowcaseItems = @(
    [pscustomobject]@{
        Title = "Nano Banana 2 Lite · 文生图"
        Subtitle = "复古赛车海报风格的图像生成示例"
        PrimaryTag = "Text to Image"
        SecondaryTag = "Partner Nodes"
        ImagePath = Join-Path $root "tools\assets\workflow-showcase\featured-nano-banana-2.jpg"
    },
    [pscustomobject]@{
        Title = "Seedream 5.0 Pro · 图像编辑"
        Subtitle = "从线稿与参考元素构建完整空间场景"
        PrimaryTag = "Image Edit"
        SecondaryTag = "Partner Nodes"
        ImagePath = Join-Path $root "tools\assets\workflow-showcase\featured-seedream-5-edit.jpg"
    },
    [pscustomobject]@{
        Title = "Krea-2 · 文生图"
        Subtitle = "融合手绘笔触与真实材质的创意生成"
        PrimaryTag = "Text to Image"
        SecondaryTag = "ComfyUI"
        ImagePath = Join-Path $root "tools\assets\workflow-showcase\featured-krea-2.jpg"
    },
    [pscustomobject]@{
        Title = "Z-Image · 文生图"
        Subtitle = "蓝色幻境中的电影感人物生成示例"
        PrimaryTag = "Text to Image"
        SecondaryTag = "Image"
        ImagePath = Join-Path $root "tools\assets\workflow-showcase\featured-z-image.jpg"
    }
)

Initialize-NetworkControls
Initialize-UpdateControls
Set-WorkflowShowcaseSlide 0
Show-NetworkSection "network"
Initialize-GpuSummary
Update-LauncherSummary
Show-LauncherPage $PageHome $NavHome
Set-LauncherStatus (Get-UiText "StatusReady") "#7F8B97"
Append-LauncherLog "LogReady"

if ($GenerateInventory) {
    Start-MigrationInventoryScan
    while ($null -ne $script:inventoryJob) {
        Start-Sleep -Milliseconds 200
        Complete-MigrationInventoryScan
    }
    if (-not $script:lastInventoryScanSucceeded) {
        $inventoryFailure = [string]$script:InventoryStatusText.Text
        $window.Close()
        throw $inventoryFailure
    }
    Write-Output $script:inventoryPath
    $window.Close()
    exit 0
}

if ($SelfTest) {
    $titleBarProbe = "Fallback"
    try {
        $titleBarInterop = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $titleBarHandle = $titleBarInterop.EnsureHandle()
        Set-LauncherDarkTitleBar $window
        $captionProbe = 0x0018120C
        $captionProbeResult = [ComfyUILauncher.NativeDwm]::DwmSetWindowAttribute(
            $titleBarHandle,
            35,
            [ref]$captionProbe,
            4
        )
        if ($captionProbeResult -eq 0 -and $captionProbe -eq 0x0018120C) {
            $titleBarProbe = "Verified"
        }
    }
    catch {
    }
    if (@($script:workflowShowcaseItems).Count -ne 4) {
        throw "Workflow showcase does not contain the expected slides."
    }
    foreach ($showcaseItem in $script:workflowShowcaseItems) {
        if (-not [System.IO.File]::Exists([string]$showcaseItem.ImagePath)) {
            throw "Workflow showcase image is missing: $($showcaseItem.ImagePath)"
        }
    }
    Set-WorkflowShowcaseSlide 1
    if ($script:workflowShowcaseIndex -ne 1 -or
        $script:WorkflowShowcaseTitle.Text -ne [string]$script:workflowShowcaseItems[1].Title) {
        throw "Workflow showcase navigation self-test failed."
    }
    Set-WorkflowShowcaseSlide 0

    $windowsPowerShellPath = Join-Path `
        $env:SystemRoot `
        "System32\WindowsPowerShell\v1.0\powershell.exe"
    $updaterSelfTestOutput = & $windowsPowerShellPath `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $script:coreUpdaterPath `
        -SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw "Core updater self-test failed."
    }
    $updaterSelfTest = ([string]($updaterSelfTestOutput -join "")) | ConvertFrom-Json
    if ([string]$updaterSelfTest.Result -ne "OK" -or
        [string]$updaterSelfTest.ApplyRollback -ne "Verified" -or
        [string]$updaterSelfTest.PartialRollback -ne "Verified" -or
        [string]$updaterSelfTest.ProtectedData -ne "Verified" -or
        [string]$updaterSelfTest.DiskGuard -ne "Verified" -or
        [string]$updaterSelfTest.ArchiveTraversalGuard -ne "Verified" -or
        [string]$updaterSelfTest.DownloadRetryPolicy -ne "Verified" -or
        [string]$updaterSelfTest.DependencyRepairMechanics -ne "Verified" -or
        [string]$updaterSelfTest.OnlineMutationPolicy -ne "Enabled") {
        throw "Core updater transaction safety self-test failed."
    }
    $extensionWorkerResultPath = Join-Path (
        Join-Path $script:root "user\launcher\state"
    ) (
        "extension-selftest-" + [Guid]::NewGuid().ToString("N") + ".json"
    )
    try {
        [void][System.IO.Directory]::CreateDirectory(
            [System.IO.Path]::GetDirectoryName($extensionWorkerResultPath)
        )
        & $windowsPowerShellPath `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -File $script:extensionWorkerPath `
            -Action SelfTest `
            -Root $script:root `
            -ResultPath $extensionWorkerResultPath
        if ($LASTEXITCODE -ne 0 -or
            -not [System.IO.File]::Exists($extensionWorkerResultPath)) {
            throw "Extension worker process IPC self-test failed."
        }
        $extensionWorkerSelfTest = [System.IO.File]::ReadAllText(
            $extensionWorkerResultPath,
            [System.Text.Encoding]::UTF8
        ) | ConvertFrom-Json
        if (-not [bool]$extensionWorkerSelfTest.ok -or
            [string]$extensionWorkerSelfTest.action -ne "SelfTest") {
            throw "Extension worker safety self-test failed."
        }
    }
    finally {
        try {
            [System.IO.File]::Delete($extensionWorkerResultPath)
        }
        catch {
        }
    }
    if ([string]$script:BtnExtensionsTab.Content -ne "已安装扩展" -or
        [string]$script:BtnInstallExtensionTab.Content -ne "安装扩展") {
        throw "Extension management tabs are not wired to the launcher UI."
    }
    if ([string]$script:BtnInventoryScan.Content -ne "修复整合包" -or
        -not $script:BtnInventoryScan.IsEnabled) {
        throw "Online dependency repair is not enabled."
    }
    Set-ExtensionUiBusy -Busy $true -Action "SearchCatalog"
    if (-not $script:ExtensionCatalogSearchBox.IsEnabled) {
        throw "Catalog search input loses focus during read-only search."
    }
    Set-ExtensionUiBusy -Busy $true -Action "Install"
    if ($script:ExtensionCatalogSearchBox.IsEnabled) {
        throw "Catalog search input is not locked during extension mutation."
    }
    Set-ExtensionUiBusy -Busy $false -Action "Install"
    $originalCatalogSearchText = [string]$script:ExtensionCatalogSearchBox.Text
    try {
        $script:ExtensionCatalogSearchBox.Text = "ra"
        if (Test-ExtensionCatalogQueryCurrent -CompletedQuery "r") {
            throw "A stale catalog result can overwrite the current query."
        }
        if (-not (Test-ExtensionCatalogQueryCurrent -CompletedQuery "RA")) {
            throw "Catalog query currency comparison is not case-insensitive."
        }
    }
    finally {
        $script:ExtensionCatalogSearchBox.Text = $originalCatalogSearchText
    }
    $installRoute = Resolve-ExtensionCatalogMutation -Item (
        [pscustomobject]@{
            Id = "catalog:test"
            CanInstall = $true
            CanReinstall = $false
            ReinstallId = ""
        }
    )
    $reinstallRoute = Resolve-ExtensionCatalogMutation -Item (
        [pscustomobject]@{
            Id = "catalog:test"
            CanInstall = $false
            CanReinstall = $true
            ReinstallId = "managed:test"
        }
    )
    $ambiguousRoute = Resolve-ExtensionCatalogMutation -Item (
        [pscustomobject]@{
            Id = "catalog:test"
            CanInstall = $true
            CanReinstall = $true
            ReinstallId = "managed:test"
        }
    )
    if ($null -eq $installRoute -or
        [string]$installRoute.Action -ne "Install" -or
        [string]$installRoute.Id -ne "catalog:test" -or
        $null -eq $reinstallRoute -or
        [string]$reinstallRoute.Action -ne "Restore" -or
        [string]$reinstallRoute.Id -ne "managed:test" -or
        $null -ne $ambiguousRoute) {
        throw "Extension catalog mutation routing is not fail-closed."
    }
    if ([string]$script:BtnExportRunLog.Content -ne "导出运行日志") {
        throw "Run log export action is not wired to the launcher UI."
    }

    $runLogTestPath = Join-Path `
        ([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\")) `
        ("ComfyUI-RunLog-" + [Guid]::NewGuid().ToString("N") + ".txt")
    try {
        $secretToken = "hf_" + ("A" * 28)
        $ansiPrefix = [string][char]27 + "[32m"
        $ansiSuffix = [string][char]27 + "[0m"
        $profileForRunLogTest = [Environment]::GetFolderPath(
            [Environment+SpecialFolder]::UserProfile
        )
        $sampleRunLog = @(
            ($ansiPrefix + "普通日志：启动成功" + $ansiSuffix),
            "extension=SK-ComfyUI-FolderingLoader",
            "Authorization: Basic should-not-remain",
            "Cookie: session=cookie-secret; preference=dark",
            ("HF_TOKEN=" + $secretToken),
            "access_token=access-secret",
            "proxy_password=proxy-secret",
            "--access-token cli-access-secret",
            '{"token":"json-secret","client_secret":"json-client-secret"}',
            "https://user:p@ss@example.com/file",
            ("profile=" + $profileForRunLogTest + "\Documents")
        ) -join [Environment]::NewLine
        [void](Export-LauncherRunLog `
            -Text $sampleRunLog `
            -Path $runLogTestPath `
            -ExportedAt ([DateTime]"2026-01-02 03:04:05"))
        $exportedRunLog = [System.IO.File]::ReadAllText($runLogTestPath, $utf8)
        $exportedBytes = [System.IO.File]::ReadAllBytes($runLogTestPath)
        if ($exportedRunLog -notmatch "普通日志：启动成功" -or
            $exportedRunLog -notmatch "SK-ComfyUI-FolderingLoader" -or
            $exportedRunLog -notmatch "敏感字段已自动隐藏" -or
            $exportedRunLog.Contains("should-not-remain") -or
            $exportedRunLog.Contains("cookie-secret") -or
            $exportedRunLog.Contains($secretToken) -or
            $exportedRunLog.Contains("access-secret") -or
            $exportedRunLog.Contains("proxy-secret") -or
            $exportedRunLog.Contains("cli-access-secret") -or
            $exportedRunLog.Contains("json-secret") -or
            $exportedRunLog.Contains("json-client-secret") -or
            $exportedRunLog.Contains("user:p@ss") -or
            (-not [string]::IsNullOrWhiteSpace($profileForRunLogTest) -and
                $exportedRunLog.Contains($profileForRunLogTest)) -or
            (-not [string]::IsNullOrWhiteSpace($profileForRunLogTest) -and
                -not $exportedRunLog.Contains("%USERPROFILE%")) -or
            $exportedRunLog.Contains([string][char]27) -or
            $exportedRunLog -notmatch "\*\*\*" -or
            $exportedBytes.Length -lt 3 -or
            $exportedBytes[0] -ne 0xEF -or
            $exportedBytes[1] -ne 0xBB -or
            $exportedBytes[2] -ne 0xBF) {
            throw "Run log export content or redaction self-test failed."
        }

        $emptyLogRejected = $false
        try {
            [void](Export-LauncherRunLog -Text "   " -Path $runLogTestPath)
        }
        catch {
            $emptyLogRejected = $true
        }
        if (-not $emptyLogRejected) {
            throw "Empty run log export was not rejected."
        }
    }
    finally {
        $resolvedRunLogTestPath = [System.IO.Path]::GetFullPath($runLogTestPath)
        $tempTestRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\")
        if ([System.IO.Path]::GetDirectoryName($resolvedRunLogTestPath) -ne $tempTestRoot -or
            -not [System.IO.Path]::GetFileName($resolvedRunLogTestPath).StartsWith("ComfyUI-RunLog-")) {
            throw "Unsafe run log self-test path: $resolvedRunLogTestPath"
        }
        if ([System.IO.File]::Exists($resolvedRunLogTestPath)) {
            [System.IO.File]::Delete($resolvedRunLogTestPath)
        }
    }

    $runLogUiTestPath = Join-Path `
        ([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\")) `
        ("ComfyUI-RunLog-UI-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $originalConsoleText = [string]$script:ConsoleBox.Text
    try {
        $script:runLogExportTestPath = $runLogUiTestPath
        $script:runLogExportNotification = ""
        $script:runLogExportNotificationHandler = {
            param([string]$Message, [object]$Image)
            $script:runLogExportNotification = $Message
        }

        $cancelLogText = "取消保存测试日志"
        $script:ConsoleBox.Text = $cancelLogText
        $script:runLogExportPathProvider = { return "" }
        Export-CurrentRunLog
        if ([System.IO.File]::Exists($runLogUiTestPath) -or
            [string]$script:ConsoleBox.Text -ne $cancelLogText -or
            -not [string]::IsNullOrEmpty($script:runLogExportNotification)) {
            throw "Run log export cancel flow self-test failed."
        }

        $successLogText = "真实导出流程测试：中文日志保留"
        $script:ConsoleBox.Text = $successLogText
        $script:runLogExportNotification = ""
        $script:runLogExportPathProvider = {
            return [string]$script:runLogExportTestPath
        }
        Export-CurrentRunLog
        if (-not [System.IO.File]::Exists($runLogUiTestPath) -or
            [string]$script:ConsoleBox.Text -ne $successLogText -or
            [string]$script:runLogExportNotification -notmatch "运行日志已导出") {
            throw "Run log export success flow self-test failed."
        }
        $uiExportedRunLog = [System.IO.File]::ReadAllText($runLogUiTestPath, $utf8)
        if ($uiExportedRunLog -notmatch "真实导出流程测试：中文日志保留") {
            throw "Run log export UI flow did not write the current console snapshot."
        }

        $script:ConsoleBox.Text = ""
        $script:runLogExportNotification = ""
        $script:runLogExportPathProvider = {
            throw "Path provider must not run for an empty log."
        }
        Export-CurrentRunLog
        if ([string]$script:runLogExportNotification -notmatch "没有可导出的运行日志") {
            throw "Empty run log UI message self-test failed."
        }

        $script:ConsoleBox.Text = "失败提示测试"
        $script:runLogExportNotification = ""
        $script:runLogExportPathProvider = {
            return [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        }
        Export-CurrentRunLog
        if ([string]$script:runLogExportNotification -notmatch "导出运行日志失败") {
            throw "Run log export failure message self-test failed."
        }
    }
    finally {
        $script:runLogExportPathProvider = $null
        $script:runLogExportNotificationHandler = $null
        $script:runLogExportNotification = ""
        $script:runLogExportTestPath = ""
        $script:ConsoleBox.Text = $originalConsoleText
        $resolvedRunLogUiTestPath = [System.IO.Path]::GetFullPath($runLogUiTestPath)
        $tempTestRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\")
        if ([System.IO.Path]::GetDirectoryName($resolvedRunLogUiTestPath) -ne $tempTestRoot -or
            -not [System.IO.Path]::GetFileName($resolvedRunLogUiTestPath).StartsWith("ComfyUI-RunLog-UI-")) {
            throw "Unsafe run log UI self-test path: $resolvedRunLogUiTestPath"
        }
        if ([System.IO.File]::Exists($resolvedRunLogUiTestPath)) {
            [System.IO.File]::Delete($resolvedRunLogUiTestPath)
        }
    }

    $originalLatestCoreVersion = [string]$script:latestCoreVersion
    $script:latestCoreVersion = "99.99.99"
    Update-CoreUpdateAvailability
    if (-not $script:BtnInstallCoreUpdate.IsEnabled -or
        [string]$script:BtnInstallCoreUpdate.Content -ne "立即更新" -or
        [string]::IsNullOrWhiteSpace((Get-CoreUpdateArchiveUrl))) {
        throw "Online core update availability self-test failed."
    }
    $script:latestCoreVersion = $originalLatestCoreVersion
    Update-CoreUpdateAvailability

    $environmentNames = @(
        "PATH",
        "HF_ENDPOINT", "PIP_INDEX_URL",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
        "http_proxy", "https_proxy", "all_proxy",
        "NO_PROXY", "no_proxy"
    )
    $environmentBefore = @{}
    foreach ($environmentName in $environmentNames) {
        $environmentBefore[$environmentName] = [Environment]::GetEnvironmentVariable(
            $environmentName,
            [EnvironmentVariableTarget]::Process
        )
    }
    $environmentScope = Enter-ComfyUIChildEnvironment
    try {
        if ([Environment]::GetEnvironmentVariable(
            "HF_ENDPOINT",
            [EnvironmentVariableTarget]::Process
        ) -ne (Get-LauncherHuggingFaceEndpoint $script:launcherSettings)) {
            throw "HF_ENDPOINT was not applied to the child launch scope."
        }
        if ([Environment]::GetEnvironmentVariable(
            "PIP_INDEX_URL",
            [EnvironmentVariableTarget]::Process
        ) -ne (Get-LauncherPypiIndexUrl $script:launcherSettings)) {
            throw "PIP_INDEX_URL was not applied to the child launch scope."
        }
    }
    finally {
        Exit-ComfyUIChildEnvironment $environmentScope
    }
    foreach ($environmentName in $environmentNames) {
        $environmentAfter = [Environment]::GetEnvironmentVariable(
            $environmentName,
            [EnvironmentVariableTarget]::Process
        )
        if (-not [object]::Equals($environmentBefore[$environmentName], $environmentAfter)) {
            $beforeKind = if ($null -eq $environmentBefore[$environmentName]) {
                "<null>"
            }
            else {
                "'" + [string]$environmentBefore[$environmentName] + "'"
            }
            $afterKind = if ($null -eq $environmentAfter) {
                "<null>"
            }
            else {
                "'" + [string]$environmentAfter + "'"
            }
            throw (
                "Process environment restoration failed for " +
                "${environmentName}: before=$beforeKind after=$afterKind."
            )
        }
    }

    $selfTestNvidiaSmi = Resolve-NvidiaSmiExecutable
    $selfTestGpuRows = @(
        & $selfTestNvidiaSmi `
            "--query-gpu=name,driver_version" `
            "--format=csv,noheader,nounits" `
            2>$null
    )
    if ($LASTEXITCODE -ne 0 -or $selfTestGpuRows.Count -eq 0) {
        throw "NVIDIA runtime preflight self-test failed."
    }

    $selfTestToken = [Guid]::NewGuid().ToString("N")
    $selfTestParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\")
    $cleanupTestRoot = Join-Path $selfTestParent ("ComfyUI-Launcher-Cleanup-" + $selfTestToken)
    $cleanupExternalRoot = Join-Path $selfTestParent ("ComfyUI-Launcher-External-" + $selfTestToken)
    $junctionSafety = "Skipped"
    try {
        $approvedRoot = Join-Path $cleanupTestRoot "approved"
        $treeRoot = Join-Path $approvedRoot "tree"
        $nestedRoot = Join-Path $treeRoot "nested"
        [void][System.IO.Directory]::CreateDirectory($nestedRoot)
        [void][System.IO.Directory]::CreateDirectory($cleanupExternalRoot)
        [System.IO.File]::WriteAllText((Join-Path $nestedRoot "remove.txt"), "remove", $utf8)
        $externalSentinel = Join-Path $cleanupExternalRoot "keep.txt"
        [System.IO.File]::WriteAllText($externalSentinel, "keep", $utf8)
        try {
            [void](New-Item `
                -ItemType Junction `
                -Path (Join-Path $nestedRoot "external-link") `
                -Target $cleanupExternalRoot `
                -ErrorAction Stop
            )
            $junctionSafety = "Verified"
        }
        catch {
            $junctionSafety = "Unavailable"
        }

        Remove-DirectoryTreeWithoutFollowingReparse `
            -Path $treeRoot `
            -ApprovedRoot $approvedRoot
        if ([System.IO.Directory]::Exists($treeRoot)) {
            throw "Privacy cleanup self-test did not remove the approved tree."
        }
        if (-not [System.IO.File]::Exists($externalSentinel)) {
            throw "Privacy cleanup self-test followed a reparse point."
        }
    }
    finally {
        foreach ($testPath in @($cleanupTestRoot, $cleanupExternalRoot)) {
            $resolvedTestPath = [System.IO.Path]::GetFullPath($testPath)
            if ([System.IO.Path]::GetDirectoryName($resolvedTestPath) -ne $selfTestParent) {
                throw "Unsafe cleanup self-test path: $resolvedTestPath"
            }
            if ([System.IO.Directory]::Exists($resolvedTestPath)) {
                Remove-DirectoryTreeWithoutFollowingReparse `
                    -Path $resolvedTestPath `
                    -ApprovedRoot $selfTestParent
            }
        }
    }

    [pscustomobject]@{
        Result = "OK"
        Root = $root
        Controls = $controlNames.Count
        Python = $pythonPath
        Xaml = $xamlPath
        Icon = $iconPath
        TitleBarTheme = $titleBarProbe
        TaskbarIdentity = $(if ($script:appUserModelResult -eq 0) { "Verified" } else { "Unavailable" })
        ShowcaseSlides = @($script:workflowShowcaseItems).Count
        CoreUpdater = "Verified"
        ExtensionWorker = "Verified"
        CoreMutationPolicy = "Enabled"
        RunLogExport = "Verified"
        EnvironmentRestored = $true
        NvidiaPreflight = "Verified"
        ReparseCleanupSafety = $junctionSafety
    } | ConvertTo-Json -Compress
    $window.Close()
    exit 0
}

if (-not [string]::IsNullOrEmpty($RenderPreview)) {
    $previewPath = [System.IO.Path]::GetFullPath($RenderPreview)
    $previewParent = [System.IO.Path]::GetDirectoryName($previewPath)
    if (-not [System.IO.Directory]::Exists($previewParent)) {
        [void][System.IO.Directory]::CreateDirectory($previewParent)
    }

    switch ($PreviewPage) {
        "advanced" { Show-LauncherPage $script:PageAdvanced $script:NavAdvanced }
        "network" {
            Show-LauncherPage $script:PageNetwork $script:NavNetwork
            Show-NetworkSection "network"
        }
        "update" {
            Show-LauncherPage $script:PageNetwork $script:NavNetwork
            Show-NetworkSection "update"
        }
        "extensions" {
            Show-LauncherPage $script:PageNetwork $script:NavNetwork
            $script:installedExtensionsLoaded = $true
            Show-NetworkSection "extensions"
        }
        "install-extension" {
            Show-LauncherPage $script:PageNetwork $script:NavNetwork
            $script:extensionCatalogLoaded = $true
            Show-NetworkSection "install-extension"
        }
        "folders" { Show-LauncherPage $script:PageFolders $script:NavFolders }
        "console" { Show-LauncherPage $script:PageConsole $script:NavConsole }
        default { Show-LauncherPage $script:PageHome $script:NavHome }
    }

    $window.Show()
    $window.UpdateLayout()
    $window.Dispatcher.Invoke(
        [Action]{},
        [System.Windows.Threading.DispatcherPriority]::Render
    )
    $previewWidth = [Math]::Max(1, [int][Math]::Ceiling($window.ActualWidth))
    $previewHeight = [Math]::Max(1, [int][Math]::Ceiling($window.ActualHeight))
    $renderBitmap = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
        $previewWidth,
        $previewHeight,
        96,
        96,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $renderBitmap.Render($window)
    $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($renderBitmap))
    $previewStream = New-Object System.IO.FileStream(
        $previewPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write
    )
    try {
        $encoder.Save($previewStream)
    }
    finally {
        $previewStream.Dispose()
    }
    $window.Close()
    Write-Output $previewPath
    exit 0
}

$NavHome.Add_Click({ Show-LauncherPage $script:PageHome $script:NavHome })
$NavAdvanced.Add_Click({ Show-LauncherPage $script:PageAdvanced $script:NavAdvanced })
$NavNetwork.Add_Click({
    Show-LauncherPage $script:PageNetwork $script:NavNetwork
    Show-NetworkSection "network"
})
$NavFolders.Add_Click({ Show-LauncherPage $script:PageFolders $script:NavFolders })
$NavConsole.Add_Click({ Show-LauncherPage $script:PageConsole $script:NavConsole })
$BtnWorkflowPrev.Add_Click({ Move-WorkflowShowcase -1 })
$BtnWorkflowNext.Add_Click({ Move-WorkflowShowcase 1 })
$script:workflowShowcaseTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:workflowShowcaseTimer.Interval = [TimeSpan]::FromSeconds(7)
$script:workflowShowcaseTimer.Add_Tick({ Move-WorkflowShowcase 1 })
$WorkflowShowcaseCard.Add_MouseEnter({ $script:workflowShowcaseTimer.Stop() })
$WorkflowShowcaseCard.Add_MouseLeave({
    if (-not $script:isClosing) {
        $script:workflowShowcaseTimer.Start()
    }
})
$HeroVisualHost.Add_SizeChanged({ Update-HeroVisualClip })
$window.Add_Loaded({
    Update-HeroVisualClip
})
$BtnNetworkTab.Add_Click({ Show-NetworkSection "network" })
$BtnUpdateTab.Add_Click({ Show-NetworkSection "update" })
$BtnExtensionsTab.Add_Click({ Show-NetworkSection "extensions" })
$BtnInstallExtensionTab.Add_Click({ Show-NetworkSection "install-extension" })
$BtnHomeNotice.Add_Click({
    Show-LauncherPage $script:PageNetwork $script:NavNetwork
    Show-NetworkSection $(if ($script:homeNoticeTarget -eq "update") { "update" } else { "network" })
})

$PresetCombo.Add_SelectionChanged({ Update-LauncherSummary })
$PortBox.Add_TextChanged({ Update-LauncherSummary })
foreach ($networkCombo in @($HfModeCombo, $GithubModeCombo, $PypiModeCombo, $ProxyModeCombo)) {
    $networkCombo.Add_SelectionChanged({ Update-NetworkEditorVisibility })
}
$BtnSaveNetwork.Add_Click({ Save-NetworkConfiguration })
$BtnTestHf.Add_Click({ Start-NetworkTest "hf" })
$BtnTestGithub.Add_Click({ Start-NetworkTest "github" })
$BtnTestPypi.Add_Click({ Start-NetworkTest "pypi" })
$BtnTestUpdateServer.Add_Click({ Start-NetworkTest "update" })
$BtnTestAllNetworks.Add_Click({ Start-AllNetworkTests })
$BtnCopyNetworkDiagnostics.Add_Click({ Copy-NetworkDiagnostics })
$BtnInventoryScan.Add_Click({ Start-DependencyRepair })
$script:launcherCheckJob = $null
$window.Add_Loaded({
    if ($script:launcherSettings.updates.autoCheck -eq $true) {
        $script:launcherCheckJob = Start-Job -ArgumentList $script:root -ScriptBlock {
            param($packageRoot)
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $packageRoot 'tools/Update-Launcher.ps1') -Root $packageRoot -CheckOnly -NonInteractive
        }
    }
})
$window.FindName('BtnLauncherUpdate').Add_Click({
    if ($null -ne $script:coreUpdateJob -or $null -ne $script:dependencyRepairJob -or
        ($null -ne $script:extensionJob -and $script:extensionJobIsMutation)) {
        [void][System.Windows.MessageBox]::Show('请等待当前维护任务完成。', '筑梦启动器')
        return
    }
    $updater = Join-Path $script:root 'tools\Update-Launcher.ps1'
    $command = "& '" + $updater.Replace("'", "''") + "' -Root '" + $script:root.Replace("'", "''") + "' -LauncherPid " + $PID
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -WindowStyle Hidden
})

$InstalledExtensionsGrid.Add_SelectionChanged({
    Update-InstalledExtensionActions
})
$InstalledExtensionsSearchBox.Add_TextChanged({
    Update-InstalledExtensionView
})
$InstalledExtensionsFilterCombo.Add_SelectionChanged({
    Update-InstalledExtensionView
})
$BtnRefreshInstalledExtensions.Add_Click({
    Start-ExtensionWorkerAction -Action "ListInstalled"
})
$BtnEnableInstalledExtension.Add_Click({
    Request-ExtensionMutation `
        -Action "Enable" `
        -Item $script:InstalledExtensionsGrid.SelectedItem
})
$BtnDisableInstalledExtension.Add_Click({
    Request-ExtensionMutation `
        -Action "Disable" `
        -Item $script:InstalledExtensionsGrid.SelectedItem
})
$BtnRemoveInstalledExtension.Add_Click({
    Request-ExtensionMutation `
        -Action "Remove" `
        -Item $script:InstalledExtensionsGrid.SelectedItem
})
$BtnOpenInstalledExtensionFolder.Add_Click({
    $item = $script:InstalledExtensionsGrid.SelectedItem
    if ($null -ne $item -and
        [bool]$item.CanOpenFolder -and
        [System.IO.Directory]::Exists([string]$item.Path)) {
        Open-ShellTarget ([string]$item.Path)
    }
})
$ExtensionCatalogGrid.Add_SelectionChanged({
    Update-ExtensionCatalogActions
})
$script:extensionCatalogSearchTimer = New-Object `
    System.Windows.Threading.DispatcherTimer
$script:extensionCatalogSearchTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$script:extensionCatalogSearchTimer.Add_Tick({
    $script:extensionCatalogSearchTimer.Stop()
    Start-ExtensionWorkerAction `
        -Action "SearchCatalog" `
        -Query $script:ExtensionCatalogSearchBox.Text.Trim()
})
$ExtensionCatalogSearchBox.Add_TextChanged({
    $script:extensionCatalogSearchTimer.Stop()
    $script:extensionCatalogSearchTimer.Start()
})
$BtnRefreshExtensionCatalog.Add_Click({
    Start-ExtensionWorkerAction -Action "RefreshCatalog"
})
$BtnOpenExtensionSource.Add_Click({
    $item = $script:ExtensionCatalogGrid.SelectedItem
    if ($null -ne $item) {
        $sourceUrl = [string]$item.SourceUrl
        $sourceUri = $null
        if ([System.Uri]::TryCreate(
                $sourceUrl,
                [System.UriKind]::Absolute,
                [ref]$sourceUri
            ) -and
            $sourceUri.Scheme -eq "https" -and
            $sourceUri.Host -eq "github.com") {
            Open-ShellTarget $sourceUrl
        }
    }
})
$BtnInstallSelectedExtension.Add_Click({
    $item = $script:ExtensionCatalogGrid.SelectedItem
    $mutation = Resolve-ExtensionCatalogMutation -Item $item
    if ($null -ne $mutation) {
        Request-ExtensionMutation `
            -Action ([string]$mutation.Action) `
            -Item $item
    }
})

$BtnCheckCoreUpdate.Add_Click({ Start-CoreUpdateCheck })
$BtnInstallCoreUpdate.Add_Click({ Start-CoreUpdateInstall })
$BtnOpenCoreRelease.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:latestCoreReleaseUrl)) {
        Open-ShellTarget $script:latestCoreReleaseUrl
    }
})
$BtnIgnoreCoreVersion.Add_Click({
    if (-not [string]::IsNullOrWhiteSpace($script:latestCoreVersion)) {
        $script:launcherSettings.updates.ignoredCoreVersion = $script:latestCoreVersion
        Save-LauncherSettingsIfAllowed -Path $script:settingsPath -Settings $script:launcherSettings
        Update-CoreUpdateAvailability
    }
})
$AutoUpdateCheck.Add_Click({ Save-UpdatePreferences })
$UpdateChannelCombo.Add_SelectionChanged({
    if ((Get-ComboTag $script:UpdateChannelCombo) -eq "preview") {
        $answer = [System.Windows.MessageBox]::Show(
            $script:window,
            "预览版可能包含未充分验证的兼容性变更。是否切换到预览版通道？",
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            Set-ComboTag $script:UpdateChannelCombo "stable"
            return
        }
    }
    Save-UpdatePreferences
})

$BtnStart.Add_Click({ Start-ComfyUI })
$BtnAdvancedStart.Add_Click({ Start-ComfyUI })
$BtnStop.Add_Click({ Stop-ComfyUI })
$BtnRestart.Add_Click({ Stop-ComfyUI -RestartAfter })
$BtnConsoleOpenWeb.Add_Click({ Open-ComfyUIWeb })

$BtnHomeCustomNodes.Add_Click({ Open-PackageFolder "custom_nodes" })
$BtnHomeModels.Add_Click({ Open-PackageFolder "models" })
$BtnHomeOutput.Add_Click({ Open-PackageFolder "output" })
$BtnFolderRoot.Add_Click({ Open-PackageFolder "" })
$BtnFolderModels.Add_Click({ Open-PackageFolder "models" })
$BtnFolderNodes.Add_Click({ Open-PackageFolder "custom_nodes" })
$BtnFolderInput.Add_Click({ Open-PackageFolder "input" })
$BtnFolderOutput.Add_Click({ Open-PackageFolder "output" })
$BtnFolderUser.Add_Click({ Open-PackageFolder "user" })

$BtnExportRunLog.Add_Click({ Export-CurrentRunLog })

$BtnCleanTemp.Add_Click({
    $answer = [System.Windows.MessageBox]::Show(
        $script:window,
        (Get-UiText "ConfirmTempClean"),
        (Get-UiText "DialogTitle"),
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
        try {
            Invoke-RuntimeTempCleanup
        }
        catch {
            [void][System.Windows.MessageBox]::Show(
                $script:window,
                $_.Exception.Message,
                (Get-UiText "DialogTitle"),
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            )
        }
    }
})

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$pollTimer.Add_Tick({
    if ($null -ne $script:launcherCheckJob -and $script:launcherCheckJob.State -in @('Completed','Failed','Stopped')) {
        try {
            $result = @(Receive-Job $script:launcherCheckJob -ErrorAction Stop) -join "`n"
            $remote = $result | ConvertFrom-Json
            if ([version]$remote.version -gt [version]$script:launcherVersionInfo.version) {
                $script:window.FindName('BtnLauncherUpdate').Content = '发现启动器 ' + $remote.version
            }
        } catch { Append-Console ('[UPDATE] 启动器版本检查暂不可用，可稍后手动检查。') }
        finally { Remove-Job $script:launcherCheckJob -Force; $script:launcherCheckJob = $null }
    }
    Complete-NetworkTests
    Complete-CoreUpdateCheck
    Complete-CoreUpdateInstall
    Complete-DependencyRepair
    Complete-ExtensionWorkerAction
    if ($null -eq $script:comfyProcess) {
        return
    }

    Read-PendingLogs
    if ($script:comfyProcess.HasExited) {
        Finalize-ComfyUIProcess
        return
    }

    if (-not $script:portReady -and $script:activePort -gt 0 -and (Test-TcpPort $script:activePort)) {
        $script:portReady = $true
        Set-LauncherStatus (Get-UiText "StatusRunning" @($script:activePort)) "#59E391"
        $script:BtnConsoleOpenWeb.IsEnabled = $true
        Append-LauncherLog "LogRunning" @("http://127.0.0.1:$($script:activePort)")

        if ($script:AutoBrowserCheck.IsChecked -eq $true -and -not $script:browserOpened) {
            $script:browserOpened = $true
            Open-ComfyUIWeb
        }
    }
})

$window.Add_Closing({
    param($sender, $eventArgs)

    if ($script:isClosing) {
        return
    }

    if ($null -ne $script:coreUpdateJob) {
        $eventArgs.Cancel = $true
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            "ComfyUI 核心正在更新。为避免文件损坏，请等待更新完成后再关闭启动器。",
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }
    if ($null -ne $script:dependencyRepairJob) {
        $eventArgs.Cancel = $true
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            "版本依赖正在恢复。为避免损坏 Python 环境，请等待完成后再关闭启动器。",
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }
    if ($null -ne $script:extensionJob -and
        $script:extensionJobIsMutation) {
        $eventArgs.Cancel = $true
        [void][System.Windows.MessageBox]::Show(
            $script:window,
            "扩展文件正在变更。为避免节点损坏，请等待操作完成后再关闭启动器。",
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
        return
    }

    if (Test-ComfyUIRunning) {
        $answer = [System.Windows.MessageBox]::Show(
            $script:window,
            (Get-UiText "ConfirmExit"),
            (Get-UiText "DialogTitle"),
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }

    }

    $script:isClosing = $true
    if ($null -ne $script:launcherCheckJob) {
        Stop-Job $script:launcherCheckJob -ErrorAction SilentlyContinue
        Remove-Job $script:launcherCheckJob -Force -ErrorAction SilentlyContinue
        $script:launcherCheckJob = $null
    }
    if ($null -ne $script:workflowShowcaseTimer) {
        $script:workflowShowcaseTimer.Stop()
    }
    if ($null -ne $script:extensionCatalogSearchTimer) {
        $script:extensionCatalogSearchTimer.Stop()
    }
    if (Test-ComfyUIRunning) {
        Stop-ComfyUI
    }
    else {
        if ($script:AutoTempCleanCheck.IsChecked -eq $true) {
            try {
                Invoke-RuntimeTempCleanup -Silent
            }
            catch {
            }
        }
        Remove-TemporaryLogs
    }

    foreach ($job in @($script:networkProbeJobs)) {
        try { $job.Probe.Client.CancelPendingRequests() } catch {}
    }
    if ($null -ne $script:updateRequest) {
        try { $script:updateRequest.Client.CancelPendingRequests() } catch {}
    }
    if ($null -ne $script:inventoryJob) {
        try { Stop-Job -Job $script:inventoryJob -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $script:inventoryJob -Force -ErrorAction SilentlyContinue } catch {}
        $script:inventoryJob = $null
    }
    if ($null -ne $script:extensionJob) {
        Stop-ExtensionWorkerProcess $script:extensionJob
        $script:extensionJob = $null
    }
})

$pollTimer.Start()
$script:workflowShowcaseTimer.Start()
if (Test-ShouldAutoCheckUpdates) {
    Start-CoreUpdateCheck
}
try {
    [void]$window.ShowDialog()
}
finally {
    $pollTimer.Stop()
    if ($null -ne $script:workflowShowcaseTimer) {
        $script:workflowShowcaseTimer.Stop()
    }
    if ($null -ne $script:extensionCatalogSearchTimer) {
        $script:extensionCatalogSearchTimer.Stop()
    }
    if (Test-ComfyUIRunning) {
        Stop-ComfyUI
    }

    $networkTasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
    foreach ($job in @($script:networkProbeJobs)) {
        try { $job.Probe.Client.CancelPendingRequests() } catch {}
        if ($null -ne $job.Probe.Task) {
            $networkTasks.Add($job.Probe.Task)
        }
    }
    if ($null -ne $script:updateRequest) {
        try { $script:updateRequest.Client.CancelPendingRequests() } catch {}
        if ($null -ne $script:updateRequest.Task) {
            $networkTasks.Add($script:updateRequest.Task)
        }
    }

    if ($networkTasks.Count -gt 0) {
        try {
            [void][System.Threading.Tasks.Task]::WaitAll(
                $networkTasks.ToArray(),
                [TimeSpan]::FromSeconds(2)
            )
        }
        catch {
        }
    }

    foreach ($job in @($script:networkProbeJobs)) {
        if ($job.Probe.Task.IsCompleted) {
            try { $job.Probe.Request.Dispose() } catch {}
            try { $job.Probe.Client.Dispose() } catch {}
        }
    }
    $script:networkProbeJobs.Clear()
    if ($null -ne $script:updateRequest) {
        if ($script:updateRequest.Task.IsCompleted) {
            try { $script:updateRequest.Client.Dispose() } catch {}
        }
        $script:updateRequest = $null
    }
    if ($null -ne $script:inventoryJob) {
        try { Stop-Job -Job $script:inventoryJob -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $script:inventoryJob -Force -ErrorAction SilentlyContinue } catch {}
        $script:inventoryJob = $null
    }
    if ($null -ne $script:extensionJob) {
        Stop-ExtensionWorkerProcess $script:extensionJob
        $script:extensionJob = $null
    }
    $script:extensionJobAction = ""
    $script:extensionJobQuery = ""
    $script:extensionJobIsMutation = $false
    $script:extensionRestartAfter = $false
    $script:pendingCatalogQuery = $null
    Remove-TemporaryLogs
}
