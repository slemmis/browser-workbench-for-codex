$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$BridgeScript = Join-Path $ScriptDirectory "windows-image-bridge.ps1"
$TemporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("browser-workbench-native-" + [Guid]::NewGuid().ToString("N"))
$MaxEncodedBytes = 26214400
$MaxDimension = 20000
$MaxPixels = 25000000

function Stop-Test {
    param([string]$Message)
    throw "browser-workbench native Windows test: $Message"
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('\', '\').Replace('"', '\"') + '"'
}

function Invoke-BridgeProcess {
    param(
        [string]$Mode,
        [string]$InputPath
    )

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = @(
        "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", (Quote-ProcessArgument $BridgeScript), $Mode,
        (Quote-ProcessArgument $InputPath), "$MaxEncodedBytes", "$MaxDimension", "$MaxPixels"
    )
    $start.Arguments = $arguments -join " "
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { Stop-Test "could not start Windows PowerShell 5.1" }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return @{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Assert-BridgeFailure {
    param(
        [string]$Description,
        [string]$InputPath
    )

    $failure = Invoke-BridgeProcess "file" $InputPath
    if ($failure.ExitCode -eq 0) { Stop-Test "$Description unexpectedly succeeded" }
    if (-not [string]::IsNullOrWhiteSpace($failure.Stdout)) {
        Stop-Test "$Description wrote payload data to stdout"
    }
    if ($failure.Stderr -notmatch "browser-workbench Windows image bridge") {
        Stop-Test "$Description did not return a bounded bridge diagnostic"
    }
    if ($failure.Stderr.Length -gt 4096) {
        Stop-Test "$Description returned an oversized diagnostic"
    }
}

try {
    if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
        Stop-Test "this gate must run under Windows PowerShell 5.1"
    }
    $null = [ScriptBlock]::Create([System.IO.File]::ReadAllText($BridgeScript))
    New-Item -ItemType Directory -Path $TemporaryRoot | Out-Null

    Add-Type -AssemblyName System.Drawing
    $sourcePath = Join-Path $TemporaryRoot "generated local image.png"
    $bitmap = New-Object System.Drawing.Bitmap 3, 2
    try {
        $bitmap.SetPixel(0, 0, [System.Drawing.Color]::FromArgb(255, 17, 34, 51))
        $bitmap.Save($sourcePath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }

    $success = Invoke-BridgeProcess "file" $sourcePath
    if ($success.ExitCode -ne 0) {
        Stop-Test ("generated local-file import failed: " + $success.Stderr.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($success.Stderr)) {
        Stop-Test "successful import wrote diagnostics to stderr"
    }
    try {
        $bytes = [Convert]::FromBase64String($success.Stdout.Trim())
    } catch {
        Stop-Test "successful import stdout was not one base64 payload"
    }
    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($bytes.Length -lt 24) { Stop-Test "PNG output was truncated" }
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($bytes[$index] -ne $signature[$index]) { Stop-Test "output bytes were not PNG" }
    }
    $width = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 16))
    $height = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 20))
    if ($width -ne 3 -or $height -ne 2) { Stop-Test "output PNG dimensions changed" }

    $pngStream = [System.IO.MemoryStream]::new($bytes, $false)
    $decodedImage = $null
    $decodedBitmap = $null
    try {
        $decodedImage = [System.Drawing.Image]::FromStream($pngStream, $true, $true)
        $decodedBitmap = [System.Drawing.Bitmap]::new($decodedImage)
        $marker = $decodedBitmap.GetPixel(0, 0)
        if ($marker.A -ne 255 -or $marker.R -ne 17 -or $marker.G -ne 34 -or $marker.B -ne 51) {
            Stop-Test ("output PNG marker changed: rgba({0},{1},{2},{3})" -f $marker.R, $marker.G, $marker.B, $marker.A)
        }
    } finally {
        if ($null -ne $decodedBitmap) { $decodedBitmap.Dispose() }
        if ($null -ne $decodedImage) { $decodedImage.Dispose() }
        $pngStream.Dispose()
    }

    Assert-BridgeFailure "missing local file" (Join-Path $TemporaryRoot "missing.png")

    $nonImagePath = Join-Path $TemporaryRoot "not an image.bin"
    [System.IO.File]::WriteAllText($nonImagePath, "this is not an image")
    Assert-BridgeFailure "non-image local file" $nonImagePath

    Assert-BridgeFailure "alternate data stream path" ($sourcePath + ":stream")
    Assert-BridgeFailure "device path" ("\\?\" + $sourcePath)

    $encodedLimitSourcePath = Join-Path $TemporaryRoot "encoded limit source.jpg"
    $noiseBitmap = [System.Drawing.Bitmap]::new(4096, 4096, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $noiseData = $null
    try {
        $noiseData = $noiseBitmap.LockBits(
            [System.Drawing.Rectangle]::new(0, 0, $noiseBitmap.Width, $noiseBitmap.Height),
            [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
            [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $noiseBytes = New-Object byte[] ([Math]::Abs($noiseData.Stride) * $noiseData.Height)
        [System.Random]::new(12345).NextBytes($noiseBytes)
        [System.Runtime.InteropServices.Marshal]::Copy($noiseBytes, 0, $noiseData.Scan0, $noiseBytes.Length)
        $noiseBitmap.UnlockBits($noiseData)
        $noiseData = $null
        $noiseBitmap.Save($encodedLimitSourcePath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    } finally {
        if ($null -ne $noiseData) { $noiseBitmap.UnlockBits($noiseData) }
        $noiseBitmap.Dispose()
    }
    if ((Get-Item -LiteralPath $encodedLimitSourcePath).Length -gt $MaxEncodedBytes) {
        Stop-Test "encoded-limit JPEG fixture unexpectedly exceeded the source limit"
    }
    Assert-BridgeFailure "encoded PNG size limit" $encodedLimitSourcePath

    $oversizedPath = Join-Path $TemporaryRoot "oversized source.png"
    $oversizedStream = [System.IO.File]::Open($oversizedPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $oversizedStream.SetLength($MaxEncodedBytes + 1)
    } finally {
        $oversizedStream.Dispose()
    }
    Assert-BridgeFailure "oversized source file" $oversizedPath

    $widePath = Join-Path $TemporaryRoot "too wide.png"
    $wideBitmap = [System.Drawing.Bitmap]::new($MaxDimension + 1, 1)
    try {
        $wideBitmap.SetPixel(0, 0, [System.Drawing.Color]::FromArgb(255, 17, 34, 51))
        $wideBitmap.Save($widePath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $wideBitmap.Dispose()
    }
    Assert-BridgeFailure "over-dimension image" $widePath

    $junctionTarget = Join-Path $TemporaryRoot "junction target"
    $junctionPath = Join-Path $TemporaryRoot "junction source"
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $junctionTarget "image.png")
    try {
        $junction = New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop
    } catch {
        Stop-Test ("junction capability is required for the reparse-point test: " + $_.Exception.Message)
    }
    if (($junction.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        Stop-Test "junction capability did not create a reparse point"
    }
    Assert-BridgeFailure "junction source path" (Join-Path $junctionPath "image.png")

    Write-Output "Browser Workbench native Windows PowerShell tests passed"
} finally {
    if (Test-Path -LiteralPath $TemporaryRoot) {
        Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force
    }
}
