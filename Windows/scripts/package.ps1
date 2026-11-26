<#
Builds a portable NVBeacon for Windows x64 that runs without the Swift toolchain:
  dist\NVBeacon-<version>-windows-x64\  and  dist\NVBeacon-<version>-windows-x64.zip

With -Installer it also builds the per-user installer
  dist\NVBeacon-<version>-windows-x64-setup.exe  (from packaging\NVBeacon.iss)

  powershell -ExecutionPolicy Bypass -File Windows\scripts\package.ps1 -Version 1.0.0 -Installer
  powershell -ExecutionPolicy Bypass -File Windows\scripts\package.ps1 -Version 1.0.0-beta.1 -Installer

Needs the Swift toolchain, the Windows SDK (rc.exe) and Visual Studio Build Tools
(dumpbin.exe), plus Inno Setup 6 for -Installer (winget install JRSoftware.InnoSetup).
Fetches the WebView2 SDK with fetch-webview2.ps1 when it is missing.
#>
param(
    [Parameter(Mandatory)][string]$Version,
    [switch]$NoZip,
    [switch]$Installer
)
$ErrorActionPreference = "Stop"
# A pre-release adds -alpha.N, -beta.N or -rc.N (shown as is). The numeric file version
# Windows keeps in the executables and the installer has no room for it: 1.0.0-beta.1 is 1.0.0.0.
if ($Version -notmatch '^(\d+\.\d+\.\d+)(-(alpha|beta|rc)\.\d+)?$') { throw "Version must look like 1.2.3 or 1.2.3-beta.1" }
$numericVersion = $Matches[1]

$windows = Split-Path $PSScriptRoot
$repo = Split-Path $windows
$work = Join-Path $windows ".build\package"
$name = "NVBeacon-$Version-windows-x64"
$dist = Join-Path $repo "dist\$name"
New-Item -ItemType Directory -Force $work | Out-Null

function Find-Tool([string[]]$pattern) {
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
    $script = $template.Replace("@VERSION_COMMAS@", ($numericVersion -replace '\.', ',') + ",0").Replace("@VERSION@", $Version).Replace("@NAME@", $product)
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
    # swift build does not relink when only the -Xlinker resource changed, which would
    # keep the previous version number in the executables: remove them first.
    $releaseBin = (swift build -c release --show-bin-path).Trim()
    Remove-Item (Join-Path $releaseBin "NVBeacon.exe"), (Join-Path $releaseBin "nvbeacon-cli.exe") -ErrorAction SilentlyContinue
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
# Visual Studio 2022 or 2026 ("18"): Build Tools install under Program Files (x86),
# full editions (as on GitHub's Windows runners) under Program Files.
$dumpbin = Find-Tool ("${env:ProgramFiles(x86)}", "$env:ProgramFiles" | ForEach-Object { "$_\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe" })
$runtime = Split-Path (Get-Command swiftCore.dll).Source
$pending = [System.Collections.Generic.Queue[string]]::new()
$pending.Enqueue((Join-Path $dist "NVBeacon.exe")); $pending.Enqueue((Join-Path $dist "nvbeacon-cli.exe"))
$copied = @{}
while ($pending.Count) {
    $binary = $pending.Dequeue()
    $imports = & $dumpbin /nologo /dependents $binary | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.dll$' }
    foreach ($dll in $imports) {
        $candidate = Join-Path $runtime $dll
        if ($copied.ContainsKey($dll.ToLower())) { continue }
        if (-not (Test-Path $candidate)) {
            # Anything else not found there is part of Windows, except the C++ runtime and debug CRT.
            if ($dll -match '^(msvcp|vcruntime|concrt|vcomp|vccorlib|ucrtbased)') { throw "$dll (imported by $(Split-Path $binary -Leaf)) is not in $runtime" }
            continue
        }
        Copy-Item $candidate $dist
        $copied[$dll.ToLower()] = $true
        $pending.Enqueue((Join-Path $dist $dll))
    }
}
# Loaded at run time rather than imported: ICU data and the Foundation pieces it pulls in.
foreach ($dll in "_FoundationICU.dll", "FoundationInternationalization.dll") {
    if (-not $copied.ContainsKey($dll.ToLower()) -and (Test-Path (Join-Path $runtime $dll))) { Copy-Item (Join-Path $runtime $dll) $dist }
}
# A PC without Visual Studio has no C++ runtime, so the package must carry it (the walk
# above takes it from the Swift runtime folder, which ships it). Stop rather than build
# a package that only starts on developer machines.
$required = "swiftCore.dll", "Foundation.dll", "_FoundationICU.dll", "VCRUNTIME140.dll", "VCRUNTIME140_1.dll", "MSVCP140.dll", "WebView2Loader.dll"
$missing = $required | Where-Object { -not (Test-Path (Join-Path $dist $_)) }
if ($missing) { throw "Runtime DLLs missing from the package: $($missing -join ', '). Check $runtime." }

Copy-Item (Join-Path $repo "LICENSE") (Join-Path $dist "LICENSE.txt")
# Full license texts of every bundled library (WebView2's included); fails if stale.
& (Join-Path $PSScriptRoot "generate-notices.ps1") -Check
Copy-Item (Join-Path $windows "packaging\THIRD-PARTY-NOTICES.txt") $dist

# 6. Zip.
$size = (Get-ChildItem $dist -Recurse -File | Measure-Object Length -Sum).Sum
"Packaged $name : $((Get-ChildItem $dist -Recurse -File).Count) files, $([math]::Round($size / 1MB, 1)) MB"
if (-not $NoZip) {
    $zip = "$dist.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $dist -DestinationPath $zip
    "Zip: $zip  SHA-256 $((Get-FileHash $zip -Algorithm SHA256).Hash)"
}

# 7. Installer (Inno Setup 6): dist\NVBeacon-<version>-windows-x64-setup.exe
if ($Installer) {
    $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw "Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup" }

    # Wizard images in the style of assets\banner.jpg, one per DPI scale (Setup picks
    # the closest): the side panel on the welcome and finish pages, and the small
    # square in the top-right corner of the other pages.
    $appIcon = [System.Drawing.Image]::FromFile((Join-Path $repo "icon.png"))
    $wizardImages = @(); $smallImages = @()
    try {
        foreach ($size in @(@(202, 386), @(269, 515), @(336, 643), @(403, 772), @(430, 824), @(498, 953), @(534, 1022))) {
            $w = $size[0]; $h = $size[1]
            $bitmap = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bitmap)
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.Clear([System.Drawing.Color]::FromArgb(0x0D, 0x11, 0x0E))
            $cx = $w / 2; $cy = $h * 0.42
            # Soft green glow behind the icon.
            $glow = New-Object System.Drawing.Drawing2D.GraphicsPath
            $glow.AddEllipse($cx - $w * 0.75, $cy - $w * 0.75, $w * 1.5, $w * 1.5)
            $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush $glow
            $brush.CenterColor = [System.Drawing.Color]::FromArgb(110, 0x3A, 0x55, 0x18)
            $brush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 0x0D, 0x11, 0x0E))
            $g.FillPath($brush, $glow); $brush.Dispose(); $glow.Dispose()
            # Concentric rings, as in the banner.
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0x2A, 0x36, 0x1C)), ([math]::Max(1.0, $w / 200))
            foreach ($ring in 1..5) {
                $r = $w * (0.34 + 0.27 * $ring)
                $g.DrawEllipse($pen, [single]($cx - $r), [single]($cy - $r), [single](2 * $r), [single](2 * $r))
            }
            $pen.Dispose()
            $iconSize = $w * 0.58
            $g.DrawImage($appIcon, [single]($cx - $iconSize / 2), [single]($cy - $iconSize / 2), [single]$iconSize, [single]$iconSize)
            $g.Dispose()
            $path = Join-Path $work "wizard-$w.png"
            $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
            $wizardImages += $path
        }
        foreach ($s in 58, 77, 97, 116, 124, 143, 159) {
            $bitmap = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bitmap)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($appIcon, 0, 0, $s, $s); $g.Dispose()
            $path = Join-Path $work "wizard-small-$s.png"
            $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
            $smallImages += $path
        }
    } finally { $appIcon.Dispose() }

    & $iscc /Q "/DAppVersion=$Version" "/DAppNumericVersion=$numericVersion" "/DSourceDir=$dist" "/DOutputDir=$(Split-Path $dist)" "/DIconFile=$icon" `
        "/DWizardImages=$($wizardImages -join ',')" "/DWizardSmallImages=$($smallImages -join ',')" (Join-Path $windows "packaging\NVBeacon.iss")
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }
    $setup = Join-Path (Split-Path $dist) "$name-setup.exe"
    "Installer: $setup  $([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB  SHA-256 $((Get-FileHash $setup -Algorithm SHA256).Hash)"
}
