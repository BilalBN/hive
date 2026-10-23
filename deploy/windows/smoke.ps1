# Installs the built installer on this (throwaway) Windows machine and checks
# it the way a family would use it: Hive runs as a service, answers, has
# FFmpeg, makes backups; running the installer again updates it after a
# backup; removing Hive keeps the data. Used by CI after build.ps1.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
$setup = (Get-ChildItem "$root\dist-installer\HiveServerSetup-*.exe" | Select-Object -First 1).FullName
$music = Join-Path $env:RUNNER_TEMP "HiveMusic"
$data = Join-Path $env:ProgramData "Hive"
$base = "http://127.0.0.1:8443"

function Step($text) { Write-Host "== $text" }
function Install($log) {
  # No Tailscale on CI machines, so listen on this computer only.
  $p = Start-Process $setup -PassThru -Wait -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART",
    "/MUSIC=$music", "/HOST=127.0.0.1", "/LOG=$(Join-Path $env:RUNNER_TEMP $log)"
  if ($p.ExitCode -ne 0) { throw "the installer stopped with $($p.ExitCode) (see $log)" }
}
function WaitForHive {
  for ($i = 0; $i -lt 60; $i++) {
    try { return Invoke-RestMethod "$base/api/v1/health" } catch { Start-Sleep 2 }
  }
  throw "Hive didn't answer within 2 minutes"
}

Step "install"
Install "install.log"
$service = Get-Service Hive
if ($service.Status -ne "Running") { throw "the Hive service is $($service.Status)" }
if ((Get-CimInstance Win32_Service -Filter "Name='Hive'").StartMode -ne "Auto") { throw "Hive doesn't start at boot" }
$health = WaitForHive
if ($health.status -ne "ok") { throw "health: $($health | ConvertTo-Json)" }
Write-Host "Hive $($health.serverVersion) answers"
if (-not (Test-Path "$data\hive.toml")) { throw "no settings file in $data" }
Get-Content "$data\hive.toml"

Step "Hive Admin, FFmpeg and fpcalc come with it"
$adminPage = Invoke-WebRequest "$base/admin/" -UseBasicParsing
if ($adminPage.StatusCode -ne 200 -or $adminPage.Content -notmatch "Hive Admin") { throw "Hive Admin isn't served" }
$library = Invoke-RestMethod "$base/api/v1/admin/library/imports"
if (-not $library.ffmpeg) { throw "Hive can't find the bundled FFmpeg" }
$folders = @($library.folders | ForEach-Object { $_.path })
if (-not ($folders -contains $music)) { throw "music folder not set: $folders" }
$lookup = Invoke-RestMethod "$base/api/v1/admin/library/lookup"
if (-not $lookup.fingerprinting) { Write-Host "note: fingerprinting off (needs an AcoustID key), fpcalc: $(Test-Path "$env:ProgramFiles\Hive\tools\fpcalc.exe")" }
& "$env:ProgramFiles\Hive\tools\ffmpeg.exe" -hide_banner -version | Select-Object -First 1
& "$env:ProgramFiles\Hive\tools\fpcalc.exe" -version

Step "a backup from Hive Admin"
$backup = Invoke-RestMethod -Method Post "$base/api/v1/admin/backups"
Write-Host "made $($backup.id)"

Step "update: run the installer again"
Install "update.log"
$before = Get-ChildItem "$data\backups\hive-backup-*-before-update.zip" -ErrorAction SilentlyContinue
if (-not $before) { throw "no backup was made before the update" }
Write-Host "backed up first: $($before[0].Name)"
$health = WaitForHive
$backups = Invoke-RestMethod "$base/api/v1/admin/backups"
if (@($backups.items).Count -lt 2) { throw "backups were lost in the update" }

Step "remove Hive"
$p = Start-Process "$env:ProgramFiles\Hive\unins000.exe" -PassThru -Wait -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART"
if ($p.ExitCode -ne 0) { throw "the uninstaller stopped with $($p.ExitCode)" }
Start-Sleep 3
if (Get-Service Hive -ErrorAction SilentlyContinue) { throw "the service is still there" }
if (-not (Test-Path "$data\server.db")) { throw "removing Hive deleted its data" }
Write-Host "removed; the data stays in $data"
