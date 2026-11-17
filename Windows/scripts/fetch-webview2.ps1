# Downloads the Microsoft WebView2 SDK into Windows/ThirdParty (ignored by git).
# The C shim target compiles against its headers; the app loads WebView2Loader.dll at run time.
$ErrorActionPreference = "Stop"
$version = "1.0.4314.35"
$expectedSha256 = "90778DEB1B77E36292828B4B5833C9255C27533F40E0DDD55891AE718944EDC4"
$root = Join-Path $PSScriptRoot "..\ThirdParty\webview2"
$package = Join-Path $root "microsoft.web.webview2.$version.nupkg"

if (Test-Path (Join-Path $root "pkg\build\native\include\WebView2.h")) {
    Write-Host "WebView2 SDK $version already present."
    exit 0
}
New-Item -ItemType Directory -Force $root | Out-Null
$url = "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$version/microsoft.web.webview2.$version.nupkg"
Invoke-WebRequest $url -OutFile $package -UseBasicParsing
$actual = (Get-FileHash $package -Algorithm SHA256).Hash
if ($actual -ne $expectedSha256) { throw "SHA-256 mismatch for $package ($actual)" }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($package, (Join-Path $root "pkg"))
Write-Host "WebView2 SDK $version extracted to $root\pkg"
