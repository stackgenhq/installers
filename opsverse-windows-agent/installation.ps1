#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Installs the StackGen ObserveNow Windows agent (Grafana Alloy).

.DESCRIPTION
    Installs Grafana Alloy as a single Windows service ("ObserveNowAgent",
    displayed as "StackGen ObserveNow Agent").

    The base install collects Windows system metrics and Windows event logs
    only. Additional components (mssql, mysql, postgres, redis, kafka,
    blackbox, nginx, jmx, javalogs) are added on demand with
    install-exporter.ps1, which drops a <component>.alloy file into the
    configuration directory:

        C:\ProgramData\StackGen\ObserveNow\conf.d

    The agent loads every *.alloy file in that directory as one configuration.

    Any legacy Grafana Agent / opsverse-windows-exporter installation found on
    the machine is removed automatically.

    Compatible with Windows PowerShell 5.1+ (Windows Server 2016 and newer).

.EXAMPLE
    .\installation.ps1 -Hostname "store-001" -MetricsUrl "metrics.example.com" -LogsUrl "logs.example.com" -Password "secret"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Hostname,
    [Parameter(Mandatory = $true)][string]$MetricsUrl,
    [Parameter(Mandatory = $true)][string]$LogsUrl,
    [Parameter(Mandatory = $true)][string]$Password
)

$ErrorActionPreference = "Stop"

$installDir         = Join-Path $env:ProgramFiles "GrafanaLabs\Alloy"
$dataDir            = Join-Path $env:ProgramData "StackGen\ObserveNow"
$confDir            = Join-Path $dataDir "conf.d"
$healthcheckDir     = Join-Path $installDir "healthcheck"
$serviceName        = "ObserveNowAgent"
$serviceDisplayName = "StackGen ObserveNow Agent"
$serviceBinary      = Join-Path $installDir "alloy-service-windows-amd64.exe"
$schedulerName      = "agents-health-check"

Write-Output "Running StackGen ObserveNow Windows Agent Installation"

# ---------- Normalize URLs (same rules as the Linux setup.sh) ----------

$MetricsUrl = "https://" + ($MetricsUrl -replace "^https?://", "")
if (-not $MetricsUrl.EndsWith("/api/v1/write")) { $MetricsUrl = $MetricsUrl.TrimEnd("/") + "/api/v1/write" }

$LogsUrl = "https://" + ($LogsUrl -replace "^https?://", "")
if (-not $LogsUrl.EndsWith("/loki/api/v1/push")) { $LogsUrl = $LogsUrl.TrimEnd("/") + "/loki/api/v1/push" }

# ---------- Remove legacy scheduled task and services ----------

$schedulerExists = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like $schedulerName }
if ($schedulerExists) {
    schtasks /delete /tn $schedulerName /f
}

if (Get-Service -Name "opsverse-agent" -ErrorAction SilentlyContinue) {
    sc.exe delete "opsverse-agent" | Out-Null
    Write-Output "Removed legacy service 'opsverse-agent'."
}

$exporterService = Get-Service -Name "opsverse-windows-exporter" -ErrorAction SilentlyContinue
if ($exporterService) {
    Write-Output "Removing legacy service 'opsverse-windows-exporter'."
    Stop-Service "opsverse-windows-exporter" -Force -ErrorAction SilentlyContinue
    sc.exe delete "opsverse-windows-exporter" | Out-Null
    if (Get-Process -Name "windows_exporter-0.31.3-amd64" -ErrorAction SilentlyContinue) {
        Stop-Process -Name "windows_exporter-0.31.3-amd64" -Force
    }
    Start-Sleep -Seconds 5
}

$grafanaAgentService = Get-Service -Name "Grafana Agent" -ErrorAction SilentlyContinue
if ($grafanaAgentService) {
    Write-Output "Removing legacy Grafana Agent installation."
    Stop-Service "Grafana Agent" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    $legacyUninstallers = @(
        (Join-Path $env:ProgramFiles "Grafana Agent\uninstaller.exe"),
        (Join-Path $env:ProgramFiles "Grafana Agent\uninstall.exe")
    )
    $uninstaller = $legacyUninstallers | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($uninstaller) {
        Start-Process -FilePath $uninstaller -ArgumentList "/S" -Wait
    } else {
        sc.exe delete "Grafana Agent" | Out-Null
    }
    Start-Sleep -Seconds 5
}

# ---------- Stop existing agent service (upgrade case) ----------

$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existingService -and $existingService.Status -eq "Running") {
    Write-Output "Stopping running $serviceDisplayName service for upgrade."
    Stop-Service $serviceName -Force
    Start-Sleep -Seconds 5
}

# ---------- Prepare configuration directory ----------

if (-not (Test-Path -PathType Container $confDir)) {
    New-Item -ItemType Directory -Path $confDir -Force | Out-Null
}

# ---------- Install Grafana Alloy ----------

Write-Output "`nInstalling agent"

# The agent installer ships as a split zip (GitHub's 100MB file limit).
# Reassemble the parts, extract, and run.
$zipParts = @(Get-ChildItem -Path $PSScriptRoot -Filter "observenow-agent-installer.zip.part*" | Sort-Object Name)
if ($zipParts.Count -eq 0) {
    throw "Agent installer archive parts (observenow-agent-installer.zip.part*) not found in $PSScriptRoot"
}

$installerZip     = Join-Path $env:TEMP "observenow-agent-installer.zip"
$installerExtract = Join-Path $env:TEMP "observenow-agent-installer"

$zipStream = [System.IO.File]::Create($installerZip)
try {
    foreach ($part in $zipParts) {
        $bytes = [System.IO.File]::ReadAllBytes($part.FullName)
        $zipStream.Write($bytes, 0, $bytes.Length)
    }
} finally {
    $zipStream.Close()
}

if (Test-Path $installerExtract) { Remove-Item $installerExtract -Recurse -Force }
Expand-Archive -Path $installerZip -DestinationPath $installerExtract -Force

$installerPath = Join-Path $installerExtract "observenow-agent-installer.exe"
if (-not (Test-Path $installerPath)) {
    throw "Agent installer not found in archive at $installerPath"
}
Start-Process -FilePath $installerPath -ArgumentList "/S", "/DISABLEREPORTING=yes", "/FORCEREGISTRY=yes", "/CONFIG=$confDir" -Wait
Start-Sleep -Seconds 5

Remove-Item $installerZip -Force -ErrorAction SilentlyContinue
Remove-Item $installerExtract -Recurse -Force -ErrorAction SilentlyContinue

# ---------- Re-register the service under the ObserveNow name ----------
# The Alloy installer always (re)creates and starts a service named "Alloy".
# Replace it with our branded service pointing at the same service binary,
# which reads its configuration from the HKLM\SOFTWARE\GrafanaLabs\Alloy
# registry key regardless of the service name.

$vendorService = Get-Service -Name "Alloy" -ErrorAction SilentlyContinue
if ($vendorService) {
    Stop-Service "Alloy" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5
    sc.exe delete "Alloy" | Out-Null
}

if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    sc.exe delete $serviceName | Out-Null
    Start-Sleep -Seconds 2
}
sc.exe create $serviceName binPath= "`"$serviceBinary`"" start= delayed-auto DisplayName= "$serviceDisplayName" | Out-Null

# ---------- Render base configuration ----------

Write-Output "Writing base configuration to $confDir\config.alloy"

$config = Get-Content (Join-Path $PSScriptRoot "config.alloy") -Raw

$config = $config.Replace("__HOSTNAME__", $Hostname)
$config = $config.Replace("__METRICS_URL__", $MetricsUrl)
$config = $config.Replace("__LOGS_URL__", $LogsUrl)
$config = $config.Replace("__PASSWORD__", $Password)

Set-Content -Path (Join-Path $confDir "config.alloy") -Value $config -Encoding ASCII

# Settings consumed by install-exporter.ps1 (no secrets here)
@{ hostname = $Hostname } | ConvertTo-Json | Set-Content -Path (Join-Path $dataDir "agent-settings.json") -Encoding ASCII

# ---------- Install healthcheck script ----------

if (-not (Test-Path -PathType Container $healthcheckDir)) {
    New-Item -ItemType Directory -Path $healthcheckDir | Out-Null
}
Copy-Item (Join-Path $PSScriptRoot "healthcheck\agents-health-check.ps1") (Join-Path $healthcheckDir "agents-health-check.ps1") -Force

# ---------- Service recovery settings ----------

sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null
sc.exe failureflag $serviceName 1 | Out-Null

# ---------- Start service ----------

Write-Output "`nStarting $serviceDisplayName service"
Start-Service -Name $serviceName
Start-Sleep -Seconds 10

# ---------- Health check ----------

Write-Output "`nRunning agent health check"
$healthy = $false
try {
    $response = Invoke-WebRequest -Uri "http://localhost:12345/-/healthy" -UseBasicParsing
    Write-Output $response.Content
    if ($response.StatusCode -eq 200) { $healthy = $true }
} catch {
    Write-Warning "Agent health check failed: $_"
}

# ---------- Register healthcheck scheduled task ----------

Write-Output "Installing healthcheck scheduled task"

$healthCheckTaskAction = New-ScheduledTaskAction `
    -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$healthcheckDir\agents-health-check.ps1`""

$healthCheckTaskDescription = "Checks the health of the StackGen ObserveNow agent."

$cimTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
                                -Namespace Root/Microsoft/Windows/TaskScheduler:MSFT_TaskEventTrigger

$healthCheckTaskTrigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly
$healthCheckTaskTrigger.Subscription =
@"
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Service Control Manager'] and EventID=7036]]</Select></Query></QueryList>
"@
$healthCheckTaskTrigger.Enabled = $True
$healthCheckTaskTrigger.Repetition = $(New-ScheduledTaskTrigger -Once -At "07:30" -RepetitionInterval "00:05").Repetition

Register-ScheduledTask `
    -TaskName $schedulerName `
    -Action $healthCheckTaskAction `
    -Trigger $healthCheckTaskTrigger `
    -Description $healthCheckTaskDescription | Out-Null

$healthCheckTaskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$healthCheckTaskSettings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -ExecutionTimeLimit 0 -StartWhenAvailable
Set-ScheduledTask -TaskName $schedulerName -Principal $healthCheckTaskPrincipal -Settings $healthCheckTaskSettings | Out-Null

Start-ScheduledTask -TaskName $schedulerName

if ($healthy) {
    Write-Output "`nCompleted installation! Verify Windows metrics are coming in on Grafana."
    Write-Output "To monitor additional components (mssql, nginx, jmx, ...), run install-exporter.ps1"
    Write-Output "Thanks for using StackGen ObserveNow"
} else {
    Write-Warning "Installation finished but the agent is not reporting healthy yet."
    Write-Warning "Check the '$serviceName' service and $confDir, or re-run the health check: Invoke-WebRequest http://localhost:12345/-/healthy"
}
