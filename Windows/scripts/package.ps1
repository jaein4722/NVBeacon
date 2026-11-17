<#
Builds a portable NVBeacon for Windows x64 that runs without the Swift toolchain:
  dist\NVBeacon-<version>-windows-x64\  and  dist\NVBeacon-<version>-windows-x64.zip

  powershell -ExecutionPolicy Bypass -File Windows\scripts\package.ps1 -Version 1.0.0

Needs the Swift toolchain, the Windows SDK (rc.exe) and Visual Studio Build Tools
(dumpbin.exe). Fetches the WebView2 SDK with fetch-webview2.ps1 when it is missing.
#>
param(
    [Parameter(Mandatory)][string]$Version,
    [switch]$NoZip
)
$ErrorActionPreference = "Stop"
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must look like 1.2.3" }

$windows = Split-Path $PSScriptRoot
$repo = Split-Path $windows
$work = Join-Path $windows ".build\package"
$name = "NVBeacon-$Version-windows-x64"
$dist = Join-Path $repo "dist\$name"
New-Item -ItemType Directory -Force $work | Out-Null

function Find-Tool([string]$pattern) {
    $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $found) { throw "Not found: $pattern" }
    $found.FullName
}

# 1. WebView2 loader
$loader = Join-Path $windows "ThirdParty\webview2\pkg\build\native\x64\WebView2Loader.dll"
if (-not (Test-Path $loader)) { & (Join-Path $PSScriptRoot "fetch-webview2.ps1") }

# 2. Icon: NVBeacon.ico from the repository's icon.png (PNG-compressed entries).
Add-Type -AssemblyName System.Drawing
$icon = Join-Path $work "NVBeacon.ico"
$source = [System.Drawing.Image]::FromFile((Join-Path $repo "icon.png"))
try {
    $images = foreach ($size in 16, 20, 24, 32, 40, 48, 64, 128, 256) {
        $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($source, 0, 0, $size, $size)
        $graphics.Dispose()
        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
        [pscustomobject]@{ Size = $size; Bytes = $stream.ToArray() }
    }
} finally { $source.Dispose() }
$file = New-Object System.IO.BinaryWriter ([System.IO.File]::Create($icon))
try {
    $file.Write([uint16]0); $file.Write([uint16]1); $file.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($image in $images) {
        $dimension = if ($image.Size -ge 256) { 0 } else { $image.Size }
        $file.Write([byte]$dimension); $file.Write([byte]$dimension); $file.Write([byte]0); $file.Write([byte]0)
        $file.Write([uint16]1); $file.Write([uint16]32)
        $file.Write([uint32]$image.Bytes.Length); $file.Write([uint32]$offset)
        $offset += $image.Bytes.Length
    }
    foreach ($image in $images) { $file.Write($image.Bytes) }
} finally { $file.Close() }

# 3. Version resources, one per executable.
$rc = Find-Tool "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x64\rc.exe"
$sdkVersion = Split-Path (Split-Path (Split-Path $rc)) -Leaf
$include = "${env:ProgramFiles(x86)}\Windows Kits\10\Include\$sdkVersion"
$template = Get-Content (Join-Path $windows "packaging\NVBeacon.rc.in") -Raw
$resources = @{}
foreach ($product in "NVBeacon", "nvbeacon-cli") {
    $script = $template.Replace("@VERSION_COMMAS@", ($Version -replace '\.', ',') + ",0").Replace("@VERSION@", $Version).Replace("@NAME@", $product)
    $rcFile = Join-Path $work "$product.rc"
    [System.IO.File]::WriteAllText($rcFile, $script, (New-Object System.Text.UTF8Encoding $false))
    $res = Join-Path $work "$product.res"
    & $rc /nologo /i "$include\um" /i "$include\shared" /i $work /fo $res $rcFile
    if ($LASTEXITCODE -ne 0) { throw "rc.exe failed for $product" }
    $resources[$product] = $res
}

# 4. Release builds with the resources linked in.
Push-Location $windows
try {
    foreach ($product in "NVBeacon", "nvbeacon-cli") {
        swift build -c release --product $product -Xlinker $resources[$product]
        if ($LASTEXITCODE -ne 0) { throw "swift build failed for $product" }
    }
    $bin = (swift build -c release --show-bin-path).Trim()
} finally { Pop-Location }

# 5. Assemble the folder.
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force $dist | Out-Null
Copy-Item (Join-Path $bin "NVBeacon.exe"), (Join-Path $bin "nvbeacon-cli.exe"), $loader $dist
Copy-Item (Join-Path $bin "NVBeaconWindows_NVBeacon.resources") $dist -Recurse

# Swift and C++ runtime DLLs the executables load, found by walking their imports.
$dumpbin = Find-Tool "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe"
$runtime = Split-Path (Get-Command swiftCore.dll).Source
$pending = [System.Collections.Generic.Queue[string]]::new()
$pending.Enqueue((Join-Path $dist "NVBeacon.exe")); $pending.Enqueue((Join-Path $dist "nvbeacon-cli.exe"))
$copied = @{}
while ($pending.Count) {
    $binary = $pending.Dequeue()
    $imports = & $dumpbin /nologo /dependents $binary | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.dll$' }
    foreach ($dll in $imports) {
        $candidate = Join-Path $runtime $dll
        if ($copied.ContainsKey($dll.ToLower()) -or -not (Test-Path $candidate)) { continue }
        Copy-Item $candidate $dist
        $copied[$dll.ToLower()] = $true
        $pending.Enqueue((Join-Path $dist $dll))
    }
}
# Loaded at run time rather than imported: ICU data and the Foundation pieces it pulls in.
foreach ($dll in "_FoundationICU.dll", "FoundationInternationalization.dll") {
    if (-not $copied.ContainsKey($dll.ToLower()) -and (Test-Path (Join-Path $runtime $dll))) { Copy-Item (Join-Path $runtime $dll) $dist }
}

Copy-Item (Join-Path $repo "LICENSE") (Join-Path $dist "LICENSE.txt")
Copy-Item (Join-Path $windows "packaging\THIRD-PARTY-NOTICES.txt") $dist
Copy-Item (Join-Path $windows "ThirdParty\webview2\pkg\LICENSE.txt") (Join-Path $dist "WebView2-LICENSE.txt")

# 6. Zip.
$size = (Get-ChildItem $dist -Recurse -File | Measure-Object Length -Sum).Sum
"Packaged $name : $((Get-ChildItem $dist -Recurse -File).Count) files, $([math]::Round($size / 1MB, 1)) MB"
if (-not $NoZip) {
    $zip = "$dist.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $dist -DestinationPath $zip
    "Zip: $zip  SHA-256 $((Get-FileHash $zip -Algorithm SHA256).Hash)"
}
