#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Adds (or removes) a monitoring component to the StackGen ObserveNow agent.

.DESCRIPTION
    Windows counterpart of the Linux install-exporter.sh. Drops a
    <component>.alloy configuration file into the agent's configuration
    directory (C:\ProgramData\StackGen\ObserveNow\conf.d) and live-reloads the
    agent - no restart needed.

    Most components (mssql, mysql, postgres, redis, kafka, blackbox) use
    exporters built into the agent, so no extra binary is installed.

    nginx additionally downloads nginx-prometheus-exporter and runs it as
    scheduled task "prom-nginx-exporter" (requires stub_status enabled in
    nginx and internet access to github.com during install).

    jmx additionally downloads the Prometheus JMX javaagent jar, which you
    must attach to your Java services (instructions are printed).

    sysevents forwards the Windows "System" event log channel to Loki (the
    base install ships the "Application" channel only).

    collectors enables additional windows_exporter collectors (iis, dns, tcp,
    smb, ...) on top of the base set. Re-running with a different -Collectors
    list replaces the previous extras; -Remove reverts to the base set.

    Compatible with Windows PowerShell 5.1+.

.EXAMPLE
    .\install-exporter.ps1 -Exporter mssql -ConnectionString "sqlserver://monitor_user:pass@localhost/SQLEXPRESS"

.EXAMPLE
    .\install-exporter.ps1 -Exporter javalogs -LogPath "C:\ServiceA\logs\*.log,C:\ServiceB\logs\*.log"

.EXAMPLE
    .\install-exporter.ps1 -Exporter nginx

.EXAMPLE
    .\install-exporter.ps1 -Exporter collectors -Collectors "iis,dns"

.EXAMPLE
    .\install-exporter.ps1 -Exporter mssql -Remove
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("mssql", "mysql", "postgres", "redis", "kafka", "blackbox", "nginx", "jmx", "javalogs", "otel", "sysevents", "collectors")]
    [string]$Exporter,

    # Connection details for mssql/mysql/postgres/redis/kafka. If omitted, a
    # localhost default is written that you can edit later in the .alloy file.
    [string]$ConnectionString = "",

    # Log file glob(s) for javalogs, comma-separated for multiple services,
    # e.g. "C:\ServiceA\logs\*.log,C:\ServiceB\logs\*.log"
    [string]$LogPath = "",

    # ObserveNow OTLP endpoint for otel, e.g. https://traces.example.com
    [string]$TracesUrl = "",

    # Comma-separated extra windows_exporter collectors for 'collectors',
    # e.g. "iis,dns". Replaces the previous extra list on re-run.
    [string]$Collectors = "",

    [switch]$Remove
)

$ErrorActionPreference = "Stop"

$dataDir       = Join-Path $env:ProgramData "StackGen\ObserveNow"
$confDir       = Join-Path $dataDir "conf.d"
$exportersDir  = Join-Path $env:ProgramFiles "StackGen\ObserveNow\exporters"
$componentConf = Join-Path $confDir "$Exporter.alloy"
$agentService  = "ObserveNowAgent"
$alloyBinary   = Join-Path $env:ProgramFiles "GrafanaLabs\Alloy\alloy-windows-amd64.exe"

$connectionDefaults = @{
    mssql    = "sqlserver://monitor_user:password@localhost:1433"
    mysql    = "monitor_user:password@(localhost:3306)/"
    postgres = "postgresql://postgres:password@localhost:5432/postgres?sslmode=disable"
    redis    = "localhost:6379"
    kafka    = "localhost:9092"
}

function Reload-Agent {
    try {
        Invoke-WebRequest -Method POST -Uri "http://localhost:12345/-/reload" -UseBasicParsing | Out-Null
        Write-Output "Agent configuration reloaded."
    } catch {
        Write-Warning "Live reload failed ($_); restarting the $agentService service instead."
        Restart-Service -Name $agentService -Force
    }
}

if (-not (Test-Path $confDir)) {
    throw "Agent configuration directory not found at $confDir. Install the agent first with installation.ps1."
}

# ---------- Remove ----------

if ($Remove) {
    if (Test-Path $componentConf) {
        Remove-Item $componentConf -Force
        Write-Output "Removed $componentConf"
    } else {
        Write-Output "No configuration found for '$Exporter'; nothing to remove from conf.d."
    }

    if ($Exporter -eq "nginx") {
        if (Get-ScheduledTask -TaskName "prom-nginx-exporter" -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName "prom-nginx-exporter" -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName "prom-nginx-exporter" -Confirm:$false
        }
        if (Get-Process -Name "nginx-prometheus-exporter" -ErrorAction SilentlyContinue) {
            Stop-Process -Name "nginx-prometheus-exporter" -Force
        }
        Remove-Item (Join-Path $exportersDir "nginx") -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($Exporter -eq "jmx") {
        Remove-Item (Join-Path $exportersDir "jmx") -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "Remember to remove the -javaagent flag from your Java services."
    }

    Reload-Agent
    exit 0
}

# ---------- Install ----------

if ($Exporter -eq "javalogs" -and -not $LogPath) {
    throw "javalogs requires -LogPath, e.g. -LogPath 'C:\StackGen\logs\*.log'"
}

if ($Exporter -eq "otel" -and -not $TracesUrl) {
    throw "otel requires -TracesUrl, e.g. -TracesUrl 'https://traces.example.com'"
}

if ($Exporter -eq "collectors" -and -not $Collectors) {
    throw "collectors requires -Collectors, e.g. -Collectors 'iis,dns'"
}

# Hostname is not substituted here: templates reference the shared
# local.file.hostname.content component defined in config.alloy.
$template = Get-Content (Join-Path $PSScriptRoot "exporter-configs\$Exporter.alloy") -Raw

if ($connectionDefaults.ContainsKey($Exporter)) {
    $conn = if ($ConnectionString) { $ConnectionString } else { $connectionDefaults[$Exporter] }
    $template = $template.Replace("__CONNECTION_STRING__", $conn.Replace("\", "\\"))
    if (-not $ConnectionString) {
        Write-Warning "No -ConnectionString passed; wrote localhost defaults. Edit $componentConf with real credentials, then reload the agent."
    }
}

if ($Exporter -eq "javalogs") {
    $logPaths = @($LogPath -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $pathTargets = ($logPaths | ForEach-Object {
        "    { __path__ = `"$($_.Replace('\', '\\'))`", job = `"java-services`", host = local.file.hostname.content },"
    }) -join "`n"
    $template = $template.Replace("__PATH_TARGETS__", $pathTargets)
}

if ($Exporter -eq "otel") {
    # The otlphttp exporter appends /v1/traces itself
    $TracesUrl = "https://" + ($TracesUrl -replace "^https?://", "")
    $TracesUrl = $TracesUrl -replace "/v1/traces$", ""
    $template = $template.Replace("__TRACES_URL__", $TracesUrl.TrimEnd("/"))
}

if ($Exporter -eq "collectors") {
    $baseCollectors  = @("cpu", "os", "process", "system", "net", "time", "memory", "logical_disk", "service")
    $extraCollectors = @($Collectors -split "," | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })

    $duplicates = @($extraCollectors | Where-Object { $baseCollectors -contains $_ })
    if ($duplicates.Count -gt 0) {
        Write-Warning "Skipping collector(s) already enabled in the base config: $($duplicates -join ', ')"
        $extraCollectors = @($extraCollectors | Where-Object { $baseCollectors -notcontains $_ })
    }
    if ($extraCollectors.Count -eq 0) {
        throw "No extra collectors left to enable after removing base-config duplicates."
    }

    $collectorList = ($extraCollectors | ForEach-Object { "`"$_`"" }) -join ", "
    $template = $template.Replace("__COLLECTORS__", $collectorList)
}

# ---------- Component-specific binaries ----------

if ($Exporter -eq "nginx") {
    $nginxVersion = "1.5.3"
    $nginxDir     = Join-Path $exportersDir "nginx"
    $nginxExe     = Join-Path $nginxDir "nginx-prometheus-exporter.exe"
    $zipName      = "nginx-prometheus-exporter_${nginxVersion}_windows_amd64.zip"
    $zipPath      = Join-Path $env:TEMP $zipName

    if (-not (Test-Path -PathType Container $nginxDir)) {
        New-Item -ItemType Directory -Path $nginxDir -Force | Out-Null
    }

    Write-Output "Downloading nginx-prometheus-exporter v$nginxVersion"
    Invoke-WebRequest -Uri "https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${nginxVersion}/${zipName}" -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $nginxDir -Force
    Remove-Item $zipPath -Force

    $taskName = "prom-nginx-exporter"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
    if (Get-Process -Name "nginx-prometheus-exporter" -ErrorAction SilentlyContinue) {
        Stop-Process -Name "nginx-prometheus-exporter" -Force
    }

    $taskAction    = New-ScheduledTaskAction -Execute $nginxExe -Argument "--nginx.scrape-uri=http://localhost:80/stub_status --web.listen-address=127.0.0.1:9113"
    $taskTrigger   = New-ScheduledTaskTrigger -AtStartup
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $taskSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -ExecutionTimeLimit 0 -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $taskTrigger `
        -Principal $taskPrincipal -Settings $taskSettings `
        -Description "StackGen ObserveNow nginx metrics exporter" | Out-Null
    Start-ScheduledTask -TaskName $taskName

    Write-Output "nginx exporter installed (task '$taskName', listening on 127.0.0.1:9113)."
    Write-Output "Ensure stub_status is enabled in nginx: location = /stub_status { stub_status; }"
    Write-Output "If nginx listens on a different port, edit the task action's --nginx.scrape-uri."
}

if ($Exporter -eq "jmx") {
    $jmxVersion = "1.6.0"
    $jmxDir     = Join-Path $exportersDir "jmx"
    $jmxJar     = Join-Path $jmxDir "jmx_prometheus_javaagent.jar"

    if (-not (Test-Path -PathType Container $jmxDir)) {
        New-Item -ItemType Directory -Path $jmxDir -Force | Out-Null
    }

    Write-Output "Downloading Prometheus JMX javaagent v$jmxVersion"
    Invoke-WebRequest -Uri "https://github.com/prometheus/jmx_exporter/releases/download/${jmxVersion}/jmx_prometheus_javaagent-${jmxVersion}.jar" -OutFile $jmxJar -UseBasicParsing

    $jmxConfig = Join-Path $jmxDir "config.yaml"
    if (-not (Test-Path $jmxConfig)) {
        Set-Content -Path $jmxConfig -Value "rules:`n- pattern: `".*`"" -Encoding ASCII
    }

    Write-Output ""
    Write-Output "JMX javaagent installed at: $jmxJar"
    Write-Output "Attach it to each Java service (one port per service, matching jmx.alloy):"
    Write-Output "  java -javaagent:`"$jmxJar`"=9404:`"$jmxConfig`" -jar service.jar"
}

# ---------- Write component configuration, validate, and reload ----------

# Back up any existing version of this component's config so a failed
# validation can be rolled back cleanly.
$backupConf = $null
if (Test-Path $componentConf) {
    $backupConf = "$componentConf.bak"
    Copy-Item $componentConf $backupConf -Force
}

Set-Content -Path $componentConf -Value $template -Encoding ASCII
Write-Output "Wrote $componentConf"

if (Test-Path $alloyBinary) {
    Write-Output "Validating configuration"
    & $alloyBinary validate $confDir
    if ($LASTEXITCODE -ne 0) {
        if ($backupConf) {
            Move-Item $backupConf $componentConf -Force
            Write-Warning "Validation failed; restored the previous $Exporter.alloy. The agent was not reloaded."
        } else {
            Remove-Item $componentConf -Force
            Write-Warning "Validation failed; removed $componentConf. The agent was not reloaded."
        }
        exit 1
    }
} else {
    Write-Warning "Agent binary not found at $alloyBinary; skipping validation."
}

if ($backupConf -and (Test-Path $backupConf)) {
    Remove-Item $backupConf -Force
}

Reload-Agent

Write-Output "`n'$Exporter' monitoring enabled. Verify metrics in ObserveNow Grafana."
