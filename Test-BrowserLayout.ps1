$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$path=Join-Path $PSScriptRoot 'launcher/tools/ComfyUI-Launcher.xaml'
$window=[Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText($path))
foreach($name in @('PageHome','PageNetwork','PageFolders','PageConsole')) {
    $control=$window.FindName($name)
    if ($control) { $control.Visibility='Collapsed' }
}
$window.FindName('PageAdvanced').Visibility='Visible'
$window.Show()
try {
    foreach($size in @(@(1280,720),@(980,650))) {
        $window.Width=$size[0];$window.Height=$size[1]
        $window.UpdateLayout()
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
        $browser=$window.FindName('BtnChooseBrowser')
        $start=$window.FindName('BtnAdvancedStart')
        $start.BringIntoView()
        $window.UpdateLayout()
        $window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
        $pos=$browser.TransformToAncestor($window).Transform([Windows.Point]::new(0,0))
        $startPos=$start.TransformToAncestor($window).Transform([Windows.Point]::new(0,0))
        if ($start.ActualHeight -lt 20 -or $pos.Y+$browser.ActualHeight -gt $startPos.Y -or $startPos.Y+$start.ActualHeight -gt $window.ActualHeight-20) { throw "Advanced controls overlap or are clipped at $size" }
    }
    $out=Join-Path $PSScriptRoot 'test-artifacts/browser-layout.png'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($out))
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create($out)
    try {$encoder.Save($stream)} finally {$stream.Dispose()}
    "PASS: browser controls do not overlap at 1280x720 and 980x650; $out"
} finally {$window.Close()}
