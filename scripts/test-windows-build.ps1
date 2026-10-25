param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [Parameter(Mandatory = $true)]
    [string]$ReportPath
)

$ErrorActionPreference = "Stop"

function Invoke-CheckedCommand {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Test-BpfElfObject {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected BPF object was not produced: $Path"
    }

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 20) {
        throw "The generated file is too small to be an ELF object: $Path"
    }
    if ($bytes[0] -ne 0x7F -or
        $bytes[1] -ne [byte][char]'E' -or
        $bytes[2] -ne [byte][char]'L' -or
        $bytes[3] -ne [byte][char]'F' -or
        $bytes[18] -ne 0xF7 -or
        $bytes[19] -ne 0x00) {
        throw "The generated file is not a little-endian EM_BPF ELF object: $Path"
    }
}

$projectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$buildPath = Join-Path $projectPath "build"
$vsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vsWhere)) {
    throw "Visual Studio Locator was not found: $vsWhere"
}

$vsInstallPath = & $vsWhere -latest -version "[17.0,18.0)" -products "*" -requires Component.Microsoft.Windows.DriverKit -property installationPath |
    Select-Object -First 1
if (-not $vsInstallPath) {
    throw "Visual Studio 2022 with the Windows Driver Kit component was not found."
}

$vsDevCmd = Join-Path $vsInstallPath "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path -LiteralPath $vsDevCmd)) {
    throw "Visual Studio developer command script was not found: $vsDevCmd"
}

$cmake = Get-Command cmake.exe -ErrorAction Stop
$command = 'call "{0}" -no_logo -arch=amd64 -host_arch=amd64 && "{1}" -S "{2}" -B "{3}" -G "Visual Studio 17 2022" -A x64 && "{1}" --build "{3}" --config Release --parallel' -f `
    $vsDevCmd, $cmake.Source, (Join-Path $projectPath "eBPF_boost_asio_design"), $buildPath
& $env:ComSpec /d /s /c $command
if ($LASTEXITCODE -ne 0) {
    throw "CMake configure/build failed with exit code $LASTEXITCODE."
}

$smokeTest = Join-Path $buildPath "Release\asio_smoke_test.exe"
if (-not (Test-Path -LiteralPath $smokeTest)) {
    throw "The Asio smoke-test executable was not produced: $smokeTest"
}
Invoke-CheckedCommand -Command $smokeTest -Arguments @()

Test-BpfElfObject -Path (Join-Path $buildPath "bpf\xdp_pass.bpf.o")
Test-BpfElfObject -Path (Join-Path $buildPath "bpf\bind_policy.bpf.o")

$report = [ordered]@{
    status = "passed"
    timestampUtc = [DateTime]::UtcNow.ToString("o")
    configuration = "Release"
    checks = @(
        "CMake configure and build",
        "asio_smoke_test",
        "xdp_pass.bpf.o is an EM_BPF ELF object",
        "bind_policy.bpf.o is an EM_BPF ELF object"
    )
}
$report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
Write-Host "Windows build and tests passed."
