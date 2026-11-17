<#
Regenerates Windows\packaging\THIRD-PARTY-NOTICES.txt from the exact upstream sources of
the libraries that ship with NVBeacon for Windows (the Windows counterpart of
scripts/generate_ios_notices.py).

  powershell -ExecutionPolicy Bypass -File Windows\scripts\generate-notices.ps1
  powershell -ExecutionPolicy Bypass -File Windows\scripts\generate-notices.ps1 -Check

License files are read from GitHub at the tag of the installed Swift toolchain, so the
notices match the runtime DLLs that package.ps1 copies. Licenses embedded in individual
source files that end up in those DLLs are included too. -Check fails when the toolchain
or WebView2 SDK changed and the bundled file is stale.
#>
param([switch]$Check)
$ErrorActionPreference = "Stop"

$windows = Split-Path $PSScriptRoot
$output = Join-Path $windows "packaging\THIRD-PARTY-NOTICES.txt"

# The pinned tag must match the toolchain that builds the release.
$swiftTag = "swift-6.2.4-RELEASE"
$installed = (& swift --version 2>&1 | Out-String)
if ($installed -notmatch [regex]::Escape("($swiftTag)")) {
    throw "The installed Swift toolchain is not $swiftTag. Update `$swiftTag (and review the component list) in $PSCommandPath."
}
$icuTag = "release-74-1"   # U_ICU_VERSION in swift-foundation-icu at $swiftTag

$web = New-Object System.Net.WebClient
$web.Encoding = [System.Text.Encoding]::UTF8
$web.Headers.Add("User-Agent", "NVBeacon-notices")
function Get-Upstream([string]$repo, [string]$ref, [string]$path) {
    $text = $web.DownloadString("https://raw.githubusercontent.com/$repo/$ref/$path")
    # A symlink comes back as its target path rather than the file.
    if ($text.Length -lt 200 -and $text.Trim() -match '^[\w./-]+$') { throw "$repo/$path at $ref is a link to $($text.Trim())" }
    $text
}
# The first /* ... */ comment in a source file that contains $marker.
function Get-EmbeddedLicense([string]$repo, [string]$ref, [string]$path, [string]$marker) {
    $source = Get-Upstream $repo $ref $path
    foreach ($match in [regex]::Matches($source, '/\*.*?\*/', 'Singleline')) {
        if ($match.Value.Contains($marker)) { return $match.Value }
    }
    throw "No license comment containing '$marker' in $repo/$path at $ref"
}

$sections = New-Object System.Collections.Generic.List[string]
$sections.Add("NVBeacon for Windows — Open Source Licenses`n`n" +
    "Generated from the pinned sources by Windows/scripts/generate-notices.ps1.`n" +
    "NVBeacon itself is released under the MIT License (LICENSE.txt). The sections below cover`n" +
    "the third-party libraries installed with it.")
function Add-Section([string]$title, [string]$body) {
    $sections.Add("$title`n$('=' * 72)`n$($body.Trim())")
}
function Add-Component([string]$name, [string]$repo, [string]$ref, [string]$shipped, [string[]]$licenseFiles) {
    Add-Section "$name — $ref" "Source: https://github.com/$repo/tree/$ref`nShipped as: $shipped"
    foreach ($file in $licenseFiles) {
        Add-Section "$($repo.Split('/')[1])/$file" (Get-Upstream $repo $ref $file)
    }
}

Add-Component "Swift standard library and runtime" "swiftlang/swift" $swiftTag `
    "swiftCore.dll, swiftCRT.dll, swiftWinSDK.dll, swift_Concurrency.dll" @("LICENSE.txt")
Add-Section "LLVM Support code in the Swift runtime — $swiftTag" (
    "Source: https://github.com/swiftlang/swift/tree/$swiftTag/stdlib/public/LLVMSupport`n" +
    "Shipped as: part of swiftCore.dll`n`n" +
    "These files are part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.")
Add-Section "llvm-project/llvm/LICENSE.TXT" (Get-Upstream "swiftlang/llvm-project" $swiftTag "llvm/LICENSE.TXT")

Add-Component "Swift Regex (swift-experimental-string-processing)" "swiftlang/swift-experimental-string-processing" $swiftTag `
    "swift_RegexParser.dll, swift_StringProcessing.dll" @("LICENSE.txt")

Add-Component "Dispatch (swift-corelibs-libdispatch)" "swiftlang/swift-corelibs-libdispatch" $swiftTag `
    "dispatch.dll, BlocksRuntime.dll, swiftDispatch.dll" @("LICENSE")

Add-Component "Foundation (swift-corelibs-foundation)" "swiftlang/swift-corelibs-foundation" $swiftTag `
    "Foundation.dll" @("LICENSE")
Add-Section "swift-corelibs-foundation/Sources/CoreFoundation/CFUniChar.c — embedded license" (
    "Also in Sources/CoreFoundation/CFBuiltinConverters.c.`n`n" +
    (Get-EmbeddedLicense "swiftlang/swift-corelibs-foundation" $swiftTag "Sources/CoreFoundation/CFUniChar.c" "Unicode, Inc."))

Add-Component "Foundation (swift-foundation)" "swiftlang/swift-foundation" $swiftTag `
    "FoundationEssentials.dll, FoundationInternationalization.dll" @("LICENSE.md", "NOTICE.txt")
Add-Section "swift-foundation/Sources/_FoundationCShims/uuid.c — embedded license" (
    "Also in swift-corelibs-foundation/Sources/CoreFoundation/uuid.c.`n`n" +
    (Get-EmbeddedLicense "swiftlang/swift-foundation" $swiftTag "Sources/_FoundationCShims/uuid.c" "Redistribution and use"))

Add-Component "ICU for Foundation (swift-foundation-icu)" "swiftlang/swift-foundation-icu" $swiftTag `
    "_FoundationICU.dll" @("LICENSE.md")
Add-Component "ICU 74.1" "unicode-org/icu" $icuTag "_FoundationICU.dll (ICU sources and data)" @("LICENSE")

$webView2Version = ([regex]::Match((Get-Content (Join-Path $PSScriptRoot "fetch-webview2.ps1") -Raw), '\$version\s*=\s*"([^"]+)"')).Groups[1].Value
$webView2License = Join-Path $windows "ThirdParty\webview2\pkg\LICENSE.txt"
if (-not (Test-Path $webView2License)) { & (Join-Path $PSScriptRoot "fetch-webview2.ps1") }
Add-Section "Microsoft Edge WebView2 SDK — $webView2Version" (
    "Source: https://www.nuget.org/packages/Microsoft.Web.WebView2/$webView2Version`nShipped as: WebView2Loader.dll")
Add-Section "Microsoft.Web.WebView2/LICENSE.txt" ([System.IO.File]::ReadAllText($webView2License))

Add-Section "Microsoft Visual C++ Redistributable" (
    "Shipped as: VCRUNTIME140.dll, VCRUNTIME140_1.dll, MSVCP140.dll`n`n" +
    "Copyright (c) Microsoft Corporation. Distributed with the application as distributable code`n" +
    "under the Microsoft Visual Studio license terms:`n" +
    "https://learn.microsoft.com/visualstudio/releases/2022/redistribution")

$text = (($sections -join "`n`n") -replace "`r", "" -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
$text = $text.TrimEnd() + "`n"
$utf8 = New-Object System.Text.UTF8Encoding $false
if ($Check) {
    $current = if (Test-Path $output) { [System.IO.File]::ReadAllText($output, $utf8) } else { "" }
    if ($current -ne $text) { throw "THIRD-PARTY-NOTICES.txt is stale; run Windows\scripts\generate-notices.ps1" }
    "Notices verified for $swiftTag"
} else {
    [System.IO.File]::WriteAllText($output, $text, $utf8)
    "Generated $output ($([math]::Round($text.Length / 1KB)) KB)"
}
