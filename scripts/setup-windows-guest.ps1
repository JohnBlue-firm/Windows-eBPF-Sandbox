#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

$ebpfCommit = "b7a8dd217a608719b03afe848cc4d5206445fbda"
$expectedSha256 = "6384A8BA507B8C1FB48AAE8BA298C7A79E3927BC92B3BFAB47552371208D8AEB"
$vsConfigSha256 = "064E8C5C3BDF3B38F609AF9CE2B77E6235EB4D2CD8230C79EDE1A9AF88C40BF9"
$bootstrapPath = Join-Path $env:TEMP "ebpf-Setup-DevEnv.ps1"
$bootstrapUrl = "https://raw.githubusercontent.com/microsoft/ebpf-for-windows/$ebpfCommit/scripts/Setup-DevEnv.ps1"
$vsConfigPath = Join-Path $env:TEMP "ebpf-vsconfig.json"
$vsConfigUrl = "https://raw.githubusercontent.com/microsoft/ebpf-for-windows/$ebpfCommit/.vsconfig"
$projectPath = Join-Path $env:USERPROFILE "source\Windows-eBPF-Sandbox"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Test-Path (Join-Path $PSScriptRoot "eBPF_boost_asio_design"))) {
    throw "Project sources are not present on this tools ISO. Recreate it with scripts/setup.sh --download-windows-iso."
}

New-Item -ItemType Directory -Force -Path $projectPath | Out-Null
Copy-Item (Join-Path $PSScriptRoot "eBPF_boost_asio_design") $projectPath -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot "README.md") $projectPath -Force
Copy-Item (Join-Path $PSScriptRoot "docs") $projectPath -Recurse -Force
Write-Host "Project sources copied to $projectPath"

Write-Host "Downloading Microsoft's pinned eBPF for Windows development setup..."
Invoke-WebRequest -UseBasicParsing -Uri $bootstrapUrl -OutFile $bootstrapPath
Invoke-WebRequest -UseBasicParsing -Uri $vsConfigUrl -OutFile $vsConfigPath

$actualSha256 = (Get-FileHash -Algorithm SHA256 $bootstrapPath).Hash
if ($actualSha256 -ne $expectedSha256) {
    Remove-Item $bootstrapPath -Force
    throw "Setup script hash mismatch. Refusing to execute downloaded script."
}
$actualVsConfigSha256 = (Get-FileHash -Algorithm SHA256 $vsConfigPath).Hash
if ($actualVsConfigSha256 -ne $vsConfigSha256) {
    Remove-Item $bootstrapPath, $vsConfigPath -Force
    throw "Visual Studio component manifest hash mismatch. Refusing to use the unpinned manifest."
}

$floatingVsConfigUrl = "https://raw.githubusercontent.com/microsoft/ebpf-for-windows/main/.vsconfig"
$bootstrapContents = Get-Content -Raw $bootstrapPath
$manifestDownload = "Invoke-WebRequest '$floatingVsConfigUrl' -OutFile `$env:TEMP\ebpf-for-windows.vsconfig"
if (-not $bootstrapContents.Contains($manifestDownload)) {
    throw "Pinned bootstrap no longer has the expected Visual Studio manifest URL. Review the guest setup script."
}
$verifiedManifestCopy = "Copy-Item -LiteralPath '$vsConfigPath' -Destination `$env:TEMP\ebpf-for-windows.vsconfig -Force"
$bootstrapContents = $bootstrapContents.Replace($manifestDownload, $verifiedManifestCopy)
Set-Content -Path $bootstrapPath -Value $bootstrapContents -Encoding UTF8 -NoNewline

if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey from its official bootstrap endpoint..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
}

Write-Host "Installing the pinned Visual Studio 2022, Windows SDK/WDK, Clang, CMake, and NuGet components..."
& $bootstrapPath -VisualStudioVersion 2022
if (-not $?) {
    throw "Microsoft's development environment setup failed."
}

$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstallPath = & $vsWhere -latest -version "[17.0,18.0)" -products "*" -requires Component.Microsoft.Windows.DriverKit -property installationPath | Select-Object -First 1
if (-not $vsInstallPath) {
    throw "Visual Studio 2022 or its Windows Driver Kit component was not found after setup."
}

Write-Host "Guest toolchain setup complete. Restart Windows if the installer requests it."
Write-Host "The eBPF runtime/driver signing setup is separate; see docs/InstallEbpf.md in the eBPF for Windows repository."
Write-Host "After setup/restart, build from $projectPath with:"
Write-Host "  cmake -S eBPF_boost_asio_design -B build"
Write-Host "  cmake --build build --config Release"