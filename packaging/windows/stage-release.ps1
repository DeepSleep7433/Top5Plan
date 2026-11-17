[CmdletBinding()]
param(
    [string]$InnoSetupCompiler = $env:INNO_SETUP_ISCC
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$releaseDir = Join-Path $root 'release\1.0.0\windows'
$sourceDir = Join-Path $root 'client\build\windows\x64\runner\Release'
$stageDir = Join-Path $root 'build\windows-installer-payload'

if (-not (Test-Path (Join-Path $sourceDir 't5_plan.exe'))) {
    throw "Windows release build not found at $sourceDir"
}
if (-not (Test-Path $releaseDir)) {
    New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
}
if (Test-Path $stageDir) {
    Remove-Item -Recurse -Force $stageDir
}
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
Copy-Item -Path (Join-Path $sourceDir '*') -Destination $stageDir -Recurse -Force

# App-local VC++ runtime makes the installer and portable ZIP self-contained
# on machines without the Visual C++ redistributable installed.
$redistRoot = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Redist\MSVC'
$crt = Get-ChildItem -Path $redistRoot -Directory -ErrorAction Stop |
    Sort-Object Name -Descending |
    ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if ($null -eq $crt) {
    throw "VC++ x64 runtime directory not found under $redistRoot"
}
Copy-Item -Path (Join-Path $crt.FullName '*.dll') -Destination $stageDir -Force

$portable = Join-Path $releaseDir 't5-windows-release-portable.zip'
if (Test-Path $portable) { Remove-Item -Force $portable }
Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $portable -CompressionLevel Optimal

if (-not $InnoSetupCompiler) {
    $InnoSetupCompiler = 'E:\Tools\InnoSetup\ISCC.exe'
}
if (-not (Test-Path $InnoSetupCompiler)) {
    throw "Inno Setup compiler not found: $InnoSetupCompiler"
}
& $InnoSetupCompiler "/O$releaseDir" (Join-Path $PSScriptRoot 't5.iss')
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup compiler failed with exit code $LASTEXITCODE"
}
Write-Output "portable=$portable"
Write-Output "installer=$releaseDir\t5-setup-1.0.0-x64.exe"
