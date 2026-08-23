param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("clipboard", "file")]
    [string]$Mode,

    [Parameter(Position = 1)]
    [AllowEmptyString()]
    [string]$Path,

    [Parameter(Mandatory = $true, Position = 2)]
    [ValidateRange(1, 2147483647)]
    [int64]$MaxEncodedBytes,

    [Parameter(Mandatory = $true, Position = 3)]
    [ValidateRange(1, 2147483647)]
    [int]$MaxDimension,

    [Parameter(Mandatory = $true, Position = 4)]
    [ValidateRange(1, 2147483647)]
    [int64]$MaxPixels
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Text;

public static class BrowserWorkbenchSafeFile {
    public const uint GENERIC_READ = 0x80000000;
    public const uint FILE_SHARE_READ = 0x00000001;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    public const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
    public const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
    public const uint FILE_TYPE_DISK = 0x0001;

    [StructLayout(LayoutKind.Sequential)]
    public struct BY_HANDLE_FILE_INFORMATION {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern SafeFileHandle CreateFile(
        string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
        uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetFileInformationByHandle(
        SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION information);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetFileType(SafeFileHandle handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern uint GetFinalPathNameByHandle(
        SafeFileHandle handle, StringBuilder path, uint pathLength, uint flags);
}
'@

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

    $extension = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    if ($extension -eq '.webp') {
        Stop-Bridge "WebP is unsupported by System.Drawing in Windows PowerShell 5.1"
    }

    # FILE_SHARE_READ denies writers and deletion/rename until decoding is done.
    # OPEN_REPARSE_POINT ensures the final component itself is never followed.
    $handle = [BrowserWorkbenchSafeFile]::CreateFile(
        $fullPath,
        [BrowserWorkbenchSafeFile]::GENERIC_READ,
        [BrowserWorkbenchSafeFile]::FILE_SHARE_READ,
        [IntPtr]::Zero,
        [BrowserWorkbenchSafeFile]::OPEN_EXISTING,
        [BrowserWorkbenchSafeFile]::FILE_FLAG_OPEN_REPARSE_POINT,
        [IntPtr]::Zero)
    if ($null -eq $handle -or $handle.IsInvalid) {
        if ($null -ne $handle) { $handle.Dispose() }
        Stop-Bridge "the requested file could not be opened safely"
    }

    $image = $null
    $stream = $null
    try {
        $information = New-Object BrowserWorkbenchSafeFile+BY_HANDLE_FILE_INFORMATION
        if (-not [BrowserWorkbenchSafeFile]::GetFileInformationByHandle($handle, [ref]$information)) {
            Stop-Bridge "the requested file handle could not be inspected"
        }
        if ([BrowserWorkbenchSafeFile]::GetFileType($handle) -ne [BrowserWorkbenchSafeFile]::FILE_TYPE_DISK -or
            ($information.FileAttributes -band [BrowserWorkbenchSafeFile]::FILE_ATTRIBUTE_DIRECTORY) -ne 0 -or
            ($information.FileAttributes -band [BrowserWorkbenchSafeFile]::FILE_ATTRIBUTE_REPARSE_POINT) -ne 0) {
            Stop-Bridge "the requested path is not a regular local file"
        }
        $pathBuffer = New-Object System.Text.StringBuilder 32768
        $pathLength = [BrowserWorkbenchSafeFile]::GetFinalPathNameByHandle($handle, $pathBuffer, $pathBuffer.Capacity, 0)
        if ($pathLength -eq 0 -or $pathLength -ge $pathBuffer.Capacity) {
            Stop-Bridge "the opened file path could not be verified"
        }
        $openedPath = $pathBuffer.ToString()
        if ($openedPath.StartsWith('\\?\')) { $openedPath = $openedPath.Substring(4) }
        if (-not [string]::Equals($openedPath, $fullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-Bridge "the requested path resolved through a reparse point"
        }

        $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read, 65536, $false)
        if ($stream.Length -gt $MaxEncodedBytes) {
            Stop-Bridge "source file exceeds the ${MaxEncodedBytes} byte limit"
        }
        $image = [System.Drawing.Image]::FromStream($stream, $true, $true)
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
        if ($null -ne $stream) {
            $stream.Dispose()
        } elseif ($null -ne $handle) {
            $handle.Dispose()
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
