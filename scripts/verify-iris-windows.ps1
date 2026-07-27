# Proves a Windows build is actually installable, rather than just built.
#
# The NSIS installer exiting zero says nothing about whether the app it wrote
# will start, so this runs the installer the way a person would (silently),
# finds what it put on disk, checks that binary's signature too — an installer
# can be signed while the payload inside it is not — launches it, and only then
# calls the build good. It uninstalls afterwards so a runner stays clean.
#
# Usage: pwsh scripts/verify-iris-windows.ps1 [-Installer <path>] [-RequireSigned]

[CmdletBinding()]
param(
  [string]$Installer,
  [switch]$RequireSigned
)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$bundleDir = 'iris-desktop/src-tauri/target/release/bundle'
if (-not $Installer) {
  $Installer = Get-ChildItem -Path $bundleDir -Recurse -Filter '*-setup.exe' -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
if (-not $Installer -or -not (Test-Path $Installer)) {
  Write-Error 'No NSIS installer found — build one first.'
  exit 1
}

$script:failures = 0
function Pass($m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  FAIL  $m" -ForegroundColor Red; $script:failures++ }
function Note($m) { Write-Host "  ----  $m" }

Write-Host "Installer: $Installer"

function Test-Signed($path, $label) {
  $signature = Get-AuthenticodeSignature -FilePath $path
  if ($signature.Status -eq 'Valid') {
    Pass "$label is signed by $($signature.SignerCertificate.Subject)"
    # An Authenticode signature without a countersigned timestamp stops
    # validating the day the certificate expires, taking every copy already
    # downloaded with it.
    if ($signature.TimeStamperCertificate) {
      Pass "$label carries a trusted timestamp"
    } else {
      Fail "$label has no timestamp — it will stop validating when the certificate expires"
    }
    return $true
  }

  if ($RequireSigned) {
    Fail "$label signature status is $($signature.Status)"
  } else {
    Note "$label is not signed ($($signature.Status)) — SmartScreen will block it for real users"
  }
  return $false
}

Write-Host ''
Write-Host 'Signature'
Test-Signed $Installer 'the installer' | Out-Null

Write-Host ''
Write-Host 'Install and open'

# /S is NSIS's silent switch. Tauri installs per-user by default, so this needs
# no elevation on a runner.
$install = Start-Process -FilePath $Installer -ArgumentList '/S' -Wait -PassThru
if ($install.ExitCode -ne 0) {
  Fail "the installer exited with code $($install.ExitCode)"
} else {
  Pass 'the installer completes silently'
}

$candidates = @(
  (Join-Path $env:LOCALAPPDATA 'Iris\Iris.exe'),
  (Join-Path ${env:ProgramFiles} 'Iris\Iris.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'Iris\Iris.exe')
) | Where-Object { $_ -and (Test-Path $_) }

$installed = $candidates | Select-Object -First 1
if (-not $installed) {
  Fail 'the installer wrote no Iris.exe anywhere it was expected'
  Write-Host ''
  Write-Host "$script:failures check(s) failed."
  exit 1
}
Pass "installed to $installed"

Test-Signed $installed 'the installed app' | Out-Null

# Being installed is not the same as being able to start: a missing WebView2
# runtime or a bad manifest only shows up here.
$process = Start-Process -FilePath $installed -PassThru
Start-Sleep -Seconds 10
$running = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
if ($running) {
  Pass 'the installed app starts and stays running (10s)'
  Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
} else {
  Fail "the installed app exited on launch (code $($process.ExitCode))"
}

$uninstaller = Join-Path (Split-Path $installed -Parent) 'uninstall.exe'
if (Test-Path $uninstaller) {
  Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait -ErrorAction SilentlyContinue
  Note 'uninstalled'
}

Write-Host ''
if ($script:failures -eq 0) {
  Write-Host 'Installs, is signed as configured, and opens.'
  exit 0
}
Write-Host "$script:failures check(s) failed."
exit 1
