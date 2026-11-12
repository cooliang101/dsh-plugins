param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Language
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType=WindowsRuntime]
$null = [Windows.Media.Ocr.OcrResult, Windows.Media.Ocr, ContentType=WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Globalization, ContentType=WindowsRuntime]

$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Receive-WinRT($operation, [type]$resultType) {
    $task = $asTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
    return $task.GetAwaiter().GetResult()
}

$engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($Language))
if ($null -eq $engine) {
    $installed = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object LanguageTag)
    ConvertTo-Json -InputObject @{ status = 'language-unavailable'; installed = $installed } -Compress
    exit
}

$file = Receive-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)) ([Windows.Storage.StorageFile])
$stream = Receive-WinRT ($file.OpenAsync([Windows.Storage.FileAccessMode, Windows.Storage, ContentType=WindowsRuntime]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
try {
    $decoder = Receive-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $transform = [Windows.Graphics.Imaging.BitmapTransform, Windows.Graphics.Imaging, ContentType=WindowsRuntime]::new()
    $longest = [Math]::Max($decoder.PixelWidth, $decoder.PixelHeight)
    $maximum = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    if ($longest -gt $maximum) {
        $transform.ScaledWidth = [uint32][Math]::Max(1, [Math]::Floor($decoder.PixelWidth * $maximum / $longest))
        $transform.ScaledHeight = [uint32][Math]::Max(1, [Math]::Floor($decoder.PixelHeight * $maximum / $longest))
    }
    $bitmap = Receive-WinRT ($decoder.GetSoftwareBitmapAsync(
        [Windows.Graphics.Imaging.BitmapPixelFormat, Windows.Graphics.Imaging, ContentType=WindowsRuntime]::Bgra8,
        [Windows.Graphics.Imaging.BitmapAlphaMode, Windows.Graphics.Imaging, ContentType=WindowsRuntime]::Ignore,
        $transform,
        [Windows.Graphics.Imaging.ExifOrientationMode, Windows.Graphics.Imaging, ContentType=WindowsRuntime]::IgnoreExifOrientation,
        [Windows.Graphics.Imaging.ColorManagementMode, Windows.Graphics.Imaging, ContentType=WindowsRuntime]::DoNotColorManage
    )) ([Windows.Graphics.Imaging.SoftwareBitmap])
    try {
        $result = Receive-WinRT ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        $lines = @($result.Lines | ForEach-Object Text | Where-Object { $_ -and $_.Trim() })
        ConvertTo-Json -InputObject @{ status = 'ok'; lines = $lines } -Compress
    } finally { $bitmap.Dispose() }
} finally { $stream.Dispose() }
