# Builds the Hive server installer: dist-installer\HiveServerSetup-<version>.exe
#
# Needs Python 3.12, FFmpeg on PATH and the built Hive Admin in admin\dist
# (npm run build --prefix admin). Run from anywhere:  pwsh deploy\windows\build.ps1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = (Resolve-Path "$PSScriptRoot\..\..").Path
Set-Location $root

$WinSW = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW-x64.exe"
$Fpcalc = "https://github.com/acoustid/chromaprint/releases/download/v1.5.1/chromaprint-fpcalc-1.5.1-windows-x86_64.zip"

if (-not (Test-Path "admin\dist\index.html")) { throw "Build Hive Admin first (npm run build --prefix admin)." }

python -m pip install --quiet --upgrade pip
python -m pip install --quiet ./server pyinstaller
$version = (python -c "import hive; print(hive.__version__)").Trim()
Write-Host "Hive server $version"

python -m PyInstaller --noconfirm --clean --log-level WARN `
  --distpath dist --workpath build\pyinstaller deploy\windows\hive.spec
$app = "dist\hive"

# FFmpeg (with any DLLs beside it) and Chromaprint's fpcalc, so nothing is installed by hand.
New-Item -ItemType Directory -Force "$app\tools", "build\downloads" | Out-Null
$ffmpeg = (Get-Command ffmpeg).Source
Copy-Item $ffmpeg "$app\tools\ffmpeg.exe"
Get-ChildItem (Split-Path $ffmpeg) -Filter *.dll -ErrorAction SilentlyContinue | Copy-Item -Destination "$app\tools"
Invoke-WebRequest $Fpcalc -OutFile build\downloads\fpcalc.zip
Expand-Archive build\downloads\fpcalc.zip build\downloads\fpcalc -Force
Copy-Item (Get-ChildItem build\downloads\fpcalc -Recurse -Filter fpcalc.exe | Select-Object -First 1).FullName "$app\tools\fpcalc.exe"

# The service wrapper, named after its settings file (hive-service.xml).
Invoke-WebRequest $WinSW -OutFile "$app\hive-service.exe"

# Hive Admin, served by hive.exe from admin\.
Copy-Item -Recurse -Force admin\dist "$app\admin"

# The installer itself (Inno Setup 6).
$iscc = (Get-Command iscc -ErrorAction SilentlyContinue).Source
if (-not $iscc) { $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe" }
if (-not (Test-Path $iscc)) {
  Write-Host "Installing Inno Setup"
  Invoke-WebRequest "https://jrsoftware.org/download.php/is.exe" -OutFile build\downloads\innosetup.exe
  Start-Process build\downloads\innosetup.exe -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-" -Wait
  $iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
}
& $iscc /Q "/DMyAppVersion=$version" deploy\windows\hive.iss
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)" }
Get-ChildItem dist-installer\*.exe | ForEach-Object { Write-Host "Built $($_.Name) ($([math]::Round($_.Length / 1MB)) MB)" }
