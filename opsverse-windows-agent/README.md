# StackGen ObserveNow - Windows Agent

Installs the StackGen ObserveNow agent (built on Grafana Alloy) as a single
Windows service, `ObserveNowAgent`. The base install collects **Windows system
metrics** and **Application event logs** only; everything else is added on
demand with `install-exporter.ps1`.

Compatible with Windows PowerShell 5.1+ (Windows Server 2016 and newer).
All scripts must be run from an elevated (Administrator) PowerShell.

## Contents

```
installation.ps1                        Agent installer
install-exporter.ps1                    Add/remove monitoring components
config.alloy                            Base configuration template
observenow-agent-installer.zip.part1/2  Agent installer (split zip, reassembled at install)
exporter-configs\*.alloy                Per-component configuration templates
healthcheck\agents-health-check.ps1     Restarts the service if it stops
```

## Install the agent

```powershell
.\installation.ps1 -Hostname "store-001" `
    -MetricsUrl "metrics.example.com" `
    -LogsUrl "logs.example.com" `
    -Password "<observenow-password>"
```

URLs may be given with or without scheme/path - they are normalized to
`https://<host>/api/v1/write` (metrics) and `https://<host>/loki/api/v1/push`
(logs). Any legacy Grafana Agent / opsverse-windows-exporter install is
removed automatically. Re-running upgrades in place.

After install, verify: `Invoke-WebRequest http://localhost:12345/-/healthy -UseBasicParsing`

## Add monitoring components

```powershell
.\install-exporter.ps1 -Exporter mssql -ConnectionString "sqlserver://monitor_user:pass@localhost:1433"
.\install-exporter.ps1 -Exporter nginx
.\install-exporter.ps1 -Exporter javalogs -LogPath "C:\DataSync\logs\*.log,C:\ServiceA\logs\*.log"
.\install-exporter.ps1 -Exporter otel -TracesUrl "https://traces.example.com"
.\install-exporter.ps1 -Exporter collectors -Collectors "iis,dns"
.\install-exporter.ps1 -Exporter mssql -Remove
```

| Exporter    | What it does                                                        | Required parameter |
|-------------|---------------------------------------------------------------------|--------------------|
| `mssql`     | SQL Server metrics (built-in exporter)                              | `-ConnectionString` (defaults to localhost) |
| `mysql`     | MySQL metrics (built-in)                                            | `-ConnectionString` (defaults to localhost) |
| `postgres`  | PostgreSQL metrics (built-in)                                       | `-ConnectionString` (defaults to localhost) |
| `redis`     | Redis metrics (built-in)                                            | `-ConnectionString` (defaults to localhost) |
| `kafka`     | Kafka metrics (built-in)                                            | `-ConnectionString` (defaults to localhost) |
| `blackbox`  | HTTP/TCP endpoint probing (built-in)                                | - (edit targets in the .alloy file) |
| `nginx`     | nginx metrics; downloads nginx-prometheus-exporter, runs as scheduled task | - (requires stub_status in nginx) |
| `jmx`       | JVM metrics; downloads the Prometheus JMX javaagent jar             | - (attach jar to Java services, instructions printed) |
| `javalogs`  | Tails Java service log files to Loki (files older than 48h skipped) | `-LogPath` (comma-separated for multiple paths) |
| `otel`      | OTLP trace receiver on 127.0.0.1:4317 (gRPC) / 4318 (HTTP)          | `-TracesUrl` |
| `sysevents` | Ships the Windows "System" event log channel                        | - |
| `collectors`| Extra windows_exporter collectors on top of the base set            | `-Collectors "iis,dns"` |

Each component is a `<name>.alloy` file in
`C:\ProgramData\StackGen\ObserveNow\conf.d`. The agent loads every `.alloy`
file in that directory as one configuration. Configs are validated before the
agent is live-reloaded; a failed validation is rolled back automatically.

Connection-string defaults are placeholders - edit the `.alloy` file with real
credentials, then reload:

```powershell
Invoke-WebRequest -Method POST -Uri http://localhost:12345/-/reload -UseBasicParsing
```

## Operational notes

- Exclude `C:\ProgramData\GrafanaLabs\Alloy` from antivirus real-time
  scanning - the agent writes bookmark/WAL files there constantly.
- Base metric collectors: cpu, os, process, system, net, time, memory,
  logical_disk, service. Add role-specific ones (iis, dns, ...) via the
  `collectors` exporter above.
- Troubleshooting: agent UI at `http://localhost:12345`, validate configs with
  `& "C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe" validate "C:\ProgramData\StackGen\ObserveNow\conf.d"`.
- A scheduled task (`agents-health-check`) restarts the service if it stops.

## Validate telemetry

In ObserveNow Grafana Explore (metrics):

```promql
up{job="integrations/windows-exporter", instance="<hostname>"}
windows_os_info{instance="<hostname>"}
```

In ObserveNow Grafana Explore (logs):

```logql
{job="windows-events", host="<hostname>"}
```
