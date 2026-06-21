<#
    build-ci.ps1 — CI build/packaging for NovaNetX VPN

    Mirrors build.ps1 but is resilient for unattended CI:
      * Core deliverables (.NET app + native Redirector/RouteHelper) are REQUIRED.
      * Optional protocol helpers under Other/ (Go source builds, third-party
        downloads) are BEST-EFFORT — a failure there is logged but does not abort
        the release, so a usable client is always produced.

    NOTE: the Other/ helper scripts freely change the working directory (and may
    `exit` on failure), so we ALWAYS reset to $root and use root-relative paths
    before each required build step.
#>
param (
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$OutputPath = 'release'
)

$root = Split-Path $MyInvocation.MyCommand.Path -Parent
Set-Location $root
$out = Join-Path $root $OutputPath

function Write-Section($t) { Write-Host "`n==== $t ====" -ForegroundColor Cyan }

# ---------------------------------------------------------------- staging ----
if (Test-Path -Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Path $out | Out-Null
New-Item -ItemType Directory -Path (Join-Path $out 'bin') | Out-Null

$bin = Join-Path $out 'bin'
Copy-Item -Recurse -Force (Join-Path $root 'Storage\i18n') $out
Copy-Item -Recurse -Force (Join-Path $root 'Storage\mode') $out
Copy-Item -Force (Join-Path $root 'Storage\stun.txt')     $bin
Copy-Item -Force (Join-Path $root 'Storage\nfdriver.sys') $bin
Copy-Item -Force (Join-Path $root 'Storage\aiodns.conf')  $bin
Copy-Item -Force (Join-Path $root 'Storage\tun2socks.bin') $bin
Copy-Item -Force (Join-Path $root 'Storage\README.md')    $bin
try {
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Loyalsoldier/geoip/release/Country.mmdb' -OutFile (Join-Path $bin 'GeoLite2-Country.mmdb')
} catch {
    Write-Warning "GeoIP database download failed: $_"
}

# ----------------------------------------------- optional Other helpers ------
Write-Section 'Optional native helpers (best-effort)'
try {
    if (-Not (Test-Path (Join-Path $root 'Other\release'))) {
        & (Join-Path $root 'Other\build.ps1')
    }
} catch {
    Write-Warning "Other/ helper build raised an error (continuing): $_"
}
# Reset CWD — the Other scripts leave us in an arbitrary directory.
Set-Location $root
$otherRelease = Join-Path $root 'Other\release'
if (Test-Path $otherRelease) {
    foreach ($ext in '*.bin', '*.dll', '*.exe') {
        Copy-Item -Force (Join-Path $otherRelease $ext) $bin -ErrorAction SilentlyContinue
    }
    Write-Host "Bundled helpers:"
    Get-ChildItem $otherRelease | ForEach-Object { Write-Host "  $($_.Name)" }
} else {
    Write-Warning "No Other/ helpers were produced; shipping core client only."
}

# ----------------------------------- backfill missing helpers (best-effort) --
# Some helpers are built from fragile upstream sources (v2ray-sn) or downloads
# (wintun). If our build didn't produce them, pull the exact compatible binaries
# from the upstream Netch release so the client is fully functional.
$required = @('v2ray-sn.exe', 'wintun.dll')
$missing = $required | Where-Object { -Not (Test-Path (Join-Path $bin $_)) }
if ($missing) {
    Write-Section "Backfilling helpers from upstream Netch release: $($missing -join ', ')"
    try {
        $headers = @{ 'User-Agent' = 'novanetx-ci' }
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/netchx/netch/releases/latest' -Headers $headers
        $asset = $rel.assets | Where-Object { $_.name -like '*.7z' -or $_.name -like '*.zip' } | Select-Object -First 1
        $tmp = Join-Path $root 'upstream-netch'
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $arc = Join-Path $tmp $asset.name
        Write-Host "Downloading $($asset.name) ($($rel.tag_name)) ..."
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $arc
        if ($asset.name -like '*.7z') { 7z x $arc "-o$tmp" -y | Out-Null }
        else { Expand-Archive -Force -Path $arc -DestinationPath $tmp }
        foreach ($f in $missing) {
            $found = Get-ChildItem -Recurse -Path $tmp -Filter $f -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { Copy-Item -Force $found.FullName $bin; Write-Host "  backfilled $f" }
            else { Write-Warning "  $f not found in upstream release" }
        }
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "Helper backfill failed (continuing): $_"
    }
    Set-Location $root
}

# ------------------------------------------------------- .NET app (req) ------
Write-Section 'Building NovaNetX VPN (.NET)'
Set-Location $root
dotnet publish `
    -c $Configuration `
    -r 'win-x64' `
    -p:Platform='x64' `
    -p:SelfContained=$True `
    -p:PublishSingleFile=$True `
    -p:IncludeNativeLibrariesForSelfExtract=$True `
    -p:CodeAnalysisTreatWarningsAsErrors=false `
    -p:TreatWarningsAsErrors=false `
    -p:EnforceCodeStyleInBuild=false `
    -p:RunAnalyzersDuringBuild=false `
    -o (Join-Path $root "Netch\bin\$Configuration") `
    (Join-Path $root 'Netch\Netch.csproj')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Copy-Item -Force (Join-Path $root "Netch\bin\$Configuration\Netch.exe") $out

# ------------------------------------------------ native Redirector (req) ----
Write-Section 'Building Redirector (C++)'
Set-Location $root
msbuild -property:Configuration=$Configuration -property:Platform=x64 (Join-Path $root 'Redirector\Redirector.vcxproj')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Copy-Item -Force (Join-Path $root "Redirector\bin\$Configuration\nfapi.dll")       $bin
Copy-Item -Force (Join-Path $root "Redirector\bin\$Configuration\Redirector.bin")  $bin

# ------------------------------------------------ native RouteHelper (req) ---
Write-Section 'Building RouteHelper (C++)'
Set-Location $root
msbuild -property:Configuration=$Configuration -property:Platform=x64 (Join-Path $root 'RouteHelper\RouteHelper.vcxproj')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Copy-Item -Force (Join-Path $root "RouteHelper\bin\$Configuration\RouteHelper.bin") $bin

# ----------------------------------------------------------------- trim ------
if ($Configuration -eq 'Release') {
    Remove-Item -Force (Join-Path $out '*.pdb') -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $out '*.xml') -ErrorAction SilentlyContinue
}

Write-Section 'Build complete'
Get-ChildItem -Recurse $out | Where-Object { -Not $_.PSIsContainer } | ForEach-Object { Write-Host $_.FullName }

Set-Location $root
exit 0
