$ErrorActionPreference = "Stop"

$taskName = "WindowsEbpfSandboxAutomation"
$workPath = Join-Path $env:ProgramData "Windows-eBPF-Sandbox-Automation"
$scriptPath = Join-Path $workPath "Invoke-WindowsVmAutomation.ps1"
$configPath = Join-Path $workPath "automation-config.json"
$statePath = Join-Path $workPath "state.txt"
$logPath = Join-Path $workPath "automation.log"
$projectPath = Join-Path $env:SystemDrive "Users\Administrator\source\Windows-eBPF-Sandbox"
$transcriptStarted = $false
$failure = $null

function Set-AutomationState {
    param([string]$State)

    Set-Content -LiteralPath $statePath -Value $State -Encoding ASCII
}

function Remove-UnattendedCredentials {
    $winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    $winlogon = Get-ItemProperty -LiteralPath $winlogonPath -ErrorAction Stop
    Set-ItemProperty -LiteralPath $winlogonPath -Name AutoAdminLogon -Value "0"
    if ($winlogon.PSObject.Properties.Name -contains "DefaultPassword") {
        Remove-ItemProperty -LiteralPath $winlogonPath -Name DefaultPassword -ErrorAction Stop
    }

    foreach ($path in @(
        "$env:SystemRoot\Panther\unattend.xml",
        "$env:SystemRoot\Panther\Unattend\unattend.xml",
        "$env:SystemRoot\Panther\Unattend\Unattend.xml",
        "$env:SystemRoot\Panther\UnattendGC\unattend.xml"
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }
}

function Register-AutomationTask {
    $action = New-ScheduledTaskAction `
        -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null
}

function Send-AutomationResult {
    param(
        [string]$Status,
        [string]$ErrorMessage
    )

    $resultPath = Join-Path $workPath "result"
    $zipPath = Join-Path $workPath "result.zip"
    if (Test-Path -LiteralPath $resultPath) {
        Remove-Item -LiteralPath $resultPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $resultPath | Out-Null

    $manifest = [ordered]@{
        status = $Status
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        error = $ErrorMessage
        computerName = $env:COMPUTERNAME
    }
    $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resultPath "automation-result.json") -Encoding UTF8

    if (Test-Path -LiteralPath $logPath) {
        Copy-Item -LiteralPath $logPath -Destination $resultPath -Force
    }
    $buildPath = Join-Path $projectPath "build"
    foreach ($relativePath in @("Release", "bpf", "windows-build-test.json")) {
        $source = Join-Path $buildPath $relativePath
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination $resultPath -Recurse -Force
        }
    }

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $resultPath "*") -DestinationPath $zipPath -Force
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Invoke-WebRequest `
                -UseBasicParsing `
                -Uri $config.uploadUrl `
                -Method Post `
                -Headers @{ "X-Automation-Token" = $config.token } `
                -ContentType "application/zip" `
                -InFile $zipPath `
                -TimeoutSec 180 | Out-Null
            return
        }
        catch {
            if ($attempt -eq 5) {
                throw
            }
            Start-Sleep -Seconds 5
        }
    }
}

New-Item -ItemType Directory -Force -Path $workPath | Out-Null
if (-not (Test-Path -LiteralPath $scriptPath)) {
    $toolsVolume = Get-Volume -FileSystemLabel "WINDOWS_DEV_TOOLS" |
        Where-Object { $_.DriveLetter } |
        Select-Object -First 1
    if (-not $toolsVolume) {
        throw "The WINDOWS_DEV_TOOLS CD was not found during first logon."
    }

    $toolsRoot = "$($toolsVolume.DriveLetter):\"
    Copy-Item -LiteralPath (Join-Path $toolsRoot "Invoke-WindowsVmAutomation.ps1") -Destination $scriptPath -Force
    Copy-Item -LiteralPath (Join-Path $toolsRoot "automation-config.json") -Destination $configPath -Force
    Copy-Item -LiteralPath (Join-Path $toolsRoot "test-windows-build.ps1") -Destination $workPath -Force

    $scriptsPath = Join-Path $projectPath "scripts"
    New-Item -ItemType Directory -Force -Path $scriptsPath | Out-Null
    Copy-Item -LiteralPath (Join-Path $toolsRoot "test-windows-build.ps1") -Destination $scriptsPath -Force
    Register-AutomationTask
}

Start-Transcript -LiteralPath $logPath -Append | Out-Null
$transcriptStarted = $true

try {
    Remove-UnattendedCredentials
    $state = if (Test-Path -LiteralPath $statePath) {
        (Get-Content -LiteralPath $statePath -Raw).Trim()
    } else {
        "install"
    }

    switch ($state) {
        "install" {
            Write-Host "Installing the Windows guest development tools."
            $toolsVolume = Get-Volume -FileSystemLabel "WINDOWS_DEV_TOOLS" |
                Where-Object { $_.DriveLetter } |
                Select-Object -First 1
            if (-not $toolsVolume) {
                throw "The WINDOWS_DEV_TOOLS CD is not mounted."
            }

            $setupScript = Join-Path "$($toolsVolume.DriveLetter):\" "setup-windows-guest.ps1"
            & $setupScript
            if (-not $?) {
                throw "The Windows guest tool bootstrap failed."
            }

            Set-AutomationState "build"
            Write-Host "Tool installation finished; restarting before the Windows build."
            Restart-Computer -Force
            return
        }
        "build" {
            Write-Host "Building and testing the Windows targets."
            $testScript = Join-Path $workPath "test-windows-build.ps1"
            & $testScript `
                -ProjectPath $projectPath `
                -ReportPath (Join-Path $projectPath "build\windows-build-test.json")
            Set-AutomationState "complete"
        }
        "complete" {
            Write-Host "Automation was already completed."
        }
        "failed" {
            throw "A previous automation run failed; inspect $logPath."
        }
        default {
            throw "Unknown automation state '$state'."
        }
    }
}
catch {
    $failure = $_.Exception.ToString()
    Write-Host "ERROR: $failure"
    Set-AutomationState "failed"
}
finally {
    try {
        Remove-UnattendedCredentials
    }
    catch {
        $cleanupError = $_.Exception.ToString()
        Write-Host "ERROR: unattended credential cleanup failed: $cleanupError"
        if ($failure) {
            $failure += "`nUnattended credential cleanup failed: $cleanupError"
        }
        else {
            $failure = "Unattended credential cleanup failed: $cleanupError"
            Set-AutomationState "failed"
        }
    }
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}

$status = if ($failure) { "failed" } else { "passed" }
try {
    Send-AutomationResult -Status $status -ErrorMessage $failure
}
catch {
    $publishError = $_.Exception.ToString()
    Add-Content -LiteralPath $logPath -Value "Result upload failed: $publishError"
    shutdown.exe /s /t 15 /c "Windows eBPF Sandbox result upload failed"
    throw "Build stage finished with status '$status', but host result upload failed: $publishError"
}
finally {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

if ($failure) {
    Write-Host "Windows automation failed. The log and failure report were sent to the host."
    shutdown.exe /s /t 15 /c "Windows eBPF Sandbox automation failed"
    exit 1
}

Write-Host "Windows build and tests passed; results were sent to the host."
shutdown.exe /s /t 15 /c "Windows eBPF Sandbox automation completed"
