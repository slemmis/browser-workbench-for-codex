param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("clipboard", "file")]
    [string]$Mode,

    [Parameter(Position = 1)]
    [AllowEmptyString()]
    [string]$Path
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

$MaxEncodedBytes = 25 * 1024 * 1024
$MaxDimension = 20000
$MaxPixels = 25000000

function Assert-NoReparseParents {
    param([string]$FullPath)

    $root = [System.IO.Path]::GetPathRoot($FullPath)
    if ([string]::IsNullOrEmpty($root)) {
        Stop-Bridge "the requested path has no local drive root"
    }
    $relative = $FullPath.Substring($root.Length)
    $parts = $relative.Split(@([char]'\', [char]'/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $current = $root
    for ($index = 0; $index -lt $parts.Length - 1; $index++) {
        $current = [System.IO.Path]::Combine($current, $parts[$index])
        try {
            $parent = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        } catch {
            Stop-Bridge "a parent directory could not be inspected"
        }
        if (-not $parent.PSIsContainer) {
            Stop-Bridge "a parent path component is not a directory"
        }
        if (($parent.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Bridge "reparse points in the source path are not allowed"
        }
    }
}

function Stop-Bridge {
    param([string]$Message)

    [Console]::Error.WriteLine("browser-workbench Windows image bridge: {0}" -f $Message)
    exit 1
}

function Assert-ImageLimits {
    param([System.Drawing.Image]$Image)

    if ($null -eq $Image -or $Image.Width -lt 1 -or $Image.Height -lt 1) {
        Stop-Bridge "the source does not contain a usable image"
    }
    if ($Image.Width -gt $MaxDimension -or $Image.Height -gt $MaxDimension) {
        Stop-Bridge "image dimensions exceed ${MaxDimension}x${MaxDimension}"
    }
    if ([int64]$Image.Width * [int64]$Image.Height -gt $MaxPixels) {
        Stop-Bridge "image exceeds the ${MaxPixels} pixel limit"
    }
}

function Convert-ImageToPng {
    param([System.Drawing.Image]$Image)

    Assert-ImageLimits $Image
    $stream = New-Object System.IO.MemoryStream
    try {
        $Image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $stream.ToArray()
    } catch {
        Stop-Bridge "the image could not be encoded as PNG"
    } finally {
        $stream.Dispose()
    }
    if ($null -eq $bytes -or $bytes.Length -lt 1) {
        Stop-Bridge "the image encoder returned no data"
    }
    if ($bytes.Length -gt $MaxEncodedBytes) {
        Stop-Bridge "encoded PNG exceeds the ${MaxEncodedBytes} byte limit"
    }
    return ,$bytes
}

function Get-FileImage {
    param([string]$InputPath)

    if ([string]::IsNullOrEmpty($InputPath)) {
        Stop-Bridge "file mode requires an absolute local Windows drive path"
    }
    if ($InputPath -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
        Stop-Bridge "URI paths are not allowed"
    }
    if ($InputPath -notmatch '^[A-Za-z]:[\\/]') {
        Stop-Bridge "file mode requires an absolute local Windows drive path"
    }
    if ($InputPath.StartsWith('\\') -or $InputPath.StartsWith('//') -or $InputPath.StartsWith('\\.') -or $InputPath.StartsWith('\\?')) {
        Stop-Bridge "UNC, network, and device paths are not allowed"
    }
    if ($InputPath.Substring(2) -match '(^|[\\/])([?.])([\\/]|$)') {
        Stop-Bridge "device paths are not allowed"
    }
    if ($InputPath.Substring(2) -match ':') {
        Stop-Bridge "alternate data stream paths are not allowed"
    }

    $driveLetter = $InputPath.Substring(0, 1)
    try {
        $drive = New-Object System.IO.DriveInfo($driveLetter)
        if ($drive.DriveType -eq [System.IO.DriveType]::Network) {
            Stop-Bridge "network drives are not allowed"
        }
    } catch {
        Stop-Bridge "the Windows drive could not be inspected"
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($InputPath)
    } catch {
        Stop-Bridge "the requested path could not be normalized"
    }
    Assert-NoReparseParents $fullPath

    try {
        $items = @(Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop)
    } catch {
        Stop-Bridge "the requested file could not be opened"
    }
    if ($items.Count -ne 1) {
        Stop-Bridge "the requested path did not resolve to one file"
    }
    $file = $items[0]
    if ($file.PSIsContainer -or (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        Stop-Bridge "the requested path is not a regular local file"
    }
    if ([int64]$file.Length -gt $MaxEncodedBytes) {
        Stop-Bridge "source file exceeds the ${MaxEncodedBytes} byte limit"
    }
    $extension = [System.IO.Path]::GetExtension($file.Name).ToLowerInvariant()
    if ($extension -eq '.webp') {
        Stop-Bridge "WebP is unsupported by System.Drawing in Windows PowerShell 5.1"
    }

    $image = $null
    try {
        $image = [System.Drawing.Image]::FromFile($file.FullName)
        $bytes = Convert-ImageToPng $image
    } catch {
        if ($_.Exception.Message -like 'browser-workbench Windows image bridge:*') {
            throw
        }
        Stop-Bridge "file is not a supported System.Drawing image; WebP is unsupported"
    } finally {
        if ($null -ne $image) {
            $image.Dispose()
        }
    }
    return ,$bytes
}

try {
    Add-Type -AssemblyName System.Drawing
    if ($Mode -eq 'clipboard') {
        if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
            Stop-Bridge "clipboard access requires a single-threaded apartment"
        }
        Add-Type -AssemblyName System.Windows.Forms
        if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
            Stop-Bridge "the Windows clipboard does not contain an image"
        }
        $clipboardImage = $null
        try {
            $clipboardImage = [System.Windows.Forms.Clipboard]::GetImage()
            if ($null -eq $clipboardImage) {
                Stop-Bridge "the Windows clipboard does not contain an image"
            }
            $bytes = Convert-ImageToPng $clipboardImage
        } finally {
            if ($null -ne $clipboardImage) {
                $clipboardImage.Dispose()
            }
        }
    } else {
        $bytes = Get-FileImage $Path
    }
    [Console]::Out.WriteLine([Convert]::ToBase64String($bytes))
} catch {
    if ($_.Exception.Message -like 'browser-workbench Windows image bridge:*') {
        throw
    }
    Stop-Bridge "Windows image access failed"
}
