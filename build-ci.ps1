<#
    build-ci.ps1 — CI build/packaging for NovaNetX VPN

    Mirrors build.ps1 but is resilient for unattended CI:
      * Core deliverables (.NET app + native Redirector/RouteHelper) are REQUIRED.
      * Optional protocol helpers under Other/ (Go source builds, third-party
        downloads) are BEST-EFFORT — a failure there is logged but does not abort
        the release, so a usable client is always produced.
#>
param (
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$OutputPath = 'release'
)

$ErrorActionPreference = 'Stop'
Push-Location (Split-Path $MyInvocation.MyCommand.Path -Parent)

function Write-Section($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

# ---------------------------------------------------------------- staging ----
if (Test-Path -Path $OutputPath) { Remove-Item -Recurse -Force $OutputPath }
New-Item -ItemType Directory -Name $OutputPath | Out-Null

Push-Location $OutputPath
New-Item -ItemType Directory -Name 'bin' | Out-Null
Copy-Item -Recurse -Force '..\Storage\i18n' '.'
Copy-Item -Recurse -Force '..\Storage\mode' '.'
Copy-Item -Force '..\Storage\stun.txt'     'bin'
Copy-Item -Force '..\Storage\nfdriver.sys' 'bin'
Copy-Item -Force '..\Storage\aiodns.conf'  'bin'
Copy-Item -Force '..\Storage\tun2socks.bin' 'bin'
Copy-Item -Force '..\Storage\README.md'    'bin'
try {
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Loyalsoldier/geoip/release/Country.mmdb' -OutFile 'bin\GeoLite2-Country.mmdb'
} catch {
    Write-Warning "GeoIP database download failed: $_"
}
Pop-Location

# ----------------------------------------------- optional Other helpers ------
Write-Section 'Optional native helpers (best-effort)'
try {
    if (-Not (Test-Path '.\Other\release')) { & '.\Other\build.ps1' }
} catch {
    Write-Warning "Other/ helper build failed (continuing): $_"
}
if (Test-Path '.\Other\release') {
    Copy-Item -Force '.\Other\release\*.bin' "$OutputPath\bin" -ErrorAction SilentlyContinue
    Copy-Item -Force '.\Other\release\*.dll' "$OutputPath\bin" -ErrorAction SilentlyContinue
    Copy-Item -Force '.\Other\release\*.exe' "$OutputPath\bin" -ErrorAction SilentlyContinue
}

# ------------------------------------------------------- .NET app (req) ------
Write-Section 'Building NovaNetX VPN (.NET)'
dotnet publish `
    -c $Configuration `
    -r 'win-x64' `
    -p:Platform='x64' `
    -p:SelfContained=$True `
    -p:PublishSingleFile=$True `
    -p:IncludeNativeLibrariesForSelfExtract=$True `
    -o ".\Netch\bin\$Configuration" `
    '.\Netch\Netch.csproj'
if (-Not $?) { exit $lastExitCode }
Copy-Item -Force ".\Netch\bin\$Configuration\Netch.exe" $OutputPath

# ------------------------------------------------ native Redirector (req) ----
Write-Section 'Building Redirector (C++)'
msbuild -property:Configuration=$Configuration -property:Platform=x64 '.\Redirector\Redirector.vcxproj'
if (-Not $?) { exit $lastExitCode }
Copy-Item -Force ".\Redirector\bin\$Configuration\nfapi.dll"      "$OutputPath\bin"
Copy-Item -Force ".\Redirector\bin\$Configuration\Redirector.bin" "$OutputPath\bin"

# ------------------------------------------------ native RouteHelper (req) ---
Write-Section 'Building RouteHelper (C++)'
msbuild -property:Configuration=$Configuration -property:Platform=x64 '.\RouteHelper\RouteHelper.vcxproj'
if (-Not $?) { exit $lastExitCode }
Copy-Item -Force ".\RouteHelper\bin\$Configuration\RouteHelper.bin" "$OutputPath\bin"

# ----------------------------------------------------------------- trim ------
if ($Configuration -eq 'Release') {
    Remove-Item -Force "$OutputPath\*.pdb" -ErrorAction SilentlyContinue
    Remove-Item -Force "$OutputPath\*.xml" -ErrorAction SilentlyContinue
}

Write-Section 'Build complete'
Get-ChildItem -Recurse $OutputPath | Where-Object { -Not $_.PSIsContainer } | ForEach-Object { Write-Host $_.FullName }

Pop-Location
exit 0
