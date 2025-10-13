#Requires -RunAsAdministrator

echo "Running OpsVerse ObserveNow Windows Metrics Exporter Installation"

$hostname= Read-Host -Prompt "Enter Unique Hostname"

[bool] $flag= $false

$path= "C:\Program Files\Grafana Agent\healthcheck"

$metricsUrl= Read-Host -Prompt "Enter ObserveNow Metrics URL"
if(!($metricsUrl.StartsWith("https://"))) {
    $metricsUrl= "https://" + $metricsUrl
}

if(!($metricsUrl.EndsWith("/api/v1/write"))) {
    $metricsUrl= $metricsUrl + "/api/v1/write"
}

$logsUrl= Read-Host -Prompt "Enter ObserveNow Logs URL"
if(!($logsUrl.StartsWith("https://"))) {
    $logsUrl= "https://" + $logsUrl
}

if(!($logsUrl.EndsWith("/loki/api/v1/push"))) {
    $logsUrl= $logsUrl + "/loki/api/v1/push"
}

$password= Read-Host -Prompt "Enter password"

$schedulerName = "agents-health-check"
$schedulerExists = Get-ScheduledTask | Where-Object {$_.TaskName -like $schedulerName } -ErrorAction SilentlyContinue

$serviceName = "opsverse-agent"
$serviceExists = Get-Service $serviceName -ErrorAction SilentlyContinue

if($schedulerExists) {
   schtasks /delete /tn $schedulerName /f
} else {
   echo "Scheduled task 'agents-health-check' doesn't exist."
}

if($serviceExists) {
   sc.exe delete $serviceName
   echo "Service 'opsverse-agent' has been deleted successfully."
} else {
   echo "Service 'opsverse-agent' doesn't exist."
}

$grafanaAgentService = Get-Service -Name "Grafana Agent" -ErrorAction SilentlyContinue
if ($grafanaAgentService.Length -gt 0) {
    $flag= $true
    echo "Stop Running Grafana Agent Service"
    Stop-Service 'Grafana Agent' -Force -NoWait
    Start-Sleep -Seconds 5
}

$service = Get-Service -Name "opsverse-windows-exporter" -ErrorAction SilentlyContinue
if ($service.Length -gt 0) {
    echo "Stopping Running Windows Exporter Service"
    sc.exe delete "opsverse-windows-exporter"
    taskkill /F /IM windows_exporter-0.31.3-amd64.exe
    Start-Sleep -Seconds 5
}

echo "`nStarting Installation"
Start-Process grafana-agent-installer.exe "/S /v/qn"
Start-Sleep -Seconds 10
cp .\windows_exporter-0.31.3-amd64.exe 'C:\Program Files\Grafana Agent'
cp .\agent-config.yaml 'C:\Program Files\Grafana Agent\agent-config.yaml'
cp .\windows-agent-config.yaml 'C:\Program Files\Grafana Agent\windows-agent-config.yaml'

If(!(test-path -PathType container $path))
{
      New-Item -ItemType Directory -Path $path
}

cp .\healthcheck\agents-health-check.ps1 'C:\Program Files\Grafana Agent\healthcheck\agents-health-check.ps1'

(Get-Content 'C:\Program Files\Grafana Agent\agent-config.yaml').replace("__HOSTNAME__", $hostname) | Set-Content 'C:\Program Files\Grafana Agent\agent-config.yaml'
(Get-Content 'C:\Program Files\Grafana Agent\agent-config.yaml').replace("__METRICS_URL__", $metricsUrl) | Set-Content 'C:\Program Files\Grafana Agent\agent-config.yaml'
(Get-Content 'C:\Program Files\Grafana Agent\agent-config.yaml').replace("__LOGS_URL__", $logsUrl) | Set-Content 'C:\Program Files\Grafana Agent\agent-config.yaml'
(Get-Content 'C:\Program Files\Grafana Agent\agent-config.yaml').replace("__PASSWORD__", $password) | Set-Content 'C:\Program Files\Grafana Agent\agent-config.yaml'

echo "`nCreating Services"
sc.exe failure "Grafana Agent" reset= 86400  actions= restart/60000/restart/60000/restart/60000
sc.exe failureflag "Grafana Agent" 1

$windows_agent_config="""""""C:\\Program Files\\Grafana Agent\\windows-agent-config.yaml"""
$windows_agent_binPath="C:\\Program Files\\Grafana Agent\\windows_exporter-0.31.3-amd64.exe"
sc.exe create opsverse-windows-exporter binPath= "$windows_agent_binPath --config.file=$windows_agent_config" type= own start= auto error= normal tag= no DisplayName= "opsverse-windows-exporter"

sc.exe failure "opsverse-windows-exporter" reset= 86400  actions= restart/60000/restart/60000/restart/60000
sc.exe failureflag "opsverse-windows-exporter" 1

echo "`nStarting Services and installing Task scheduler"

Start-Service -Name "Grafana Agent"
Start-Service -Name "opsverse-windows-exporter"
Start-Sleep -Seconds 10

echo "`nRunning Agent Health Check"
$response = curl http://localhost:12345/-/healthy
echo $response.Content

if ($response.Content.StartsWith("Agent is Healthy.")) {
    echo "Installing Task scheduler"

    # Create a new task action
    $healthCheckTaskAction = New-ScheduledTaskAction `
        -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -Argument "& 'C:\Program Files\Grafana Agent\healthcheck\agents-health-check.ps1'"


    # The name of your scheduled task.
    $healthCheckTaskName = "agents-health-check"

    # Describe the scheduled task.
    $healthCheckTaskDescription = "Checks the health of Grafana Agent and OpsVerse Windows Exporter."

    $cimTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
                                    -Namespace Root/Microsoft/Windows/TaskScheduler:MSFT_TaskEventTrigger

    $healthCheckTaskTrigger = New-CimInstance -CimClass $CIMTriggerClass -ClientOnly
    $healthCheckTaskTrigger.Subscription = 
@"
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Service Control Manager'] and EventID=7036]]</Select></Query></QueryList>
"@
    $healthCheckTaskTrigger.Enabled = $True

    $healthCheckTaskTrigger.Repetition = $(New-ScheduledTaskTrigger -Once -At "07:30" -RepetitionInterval "00:05").Repetition

    # Register the scheduled task for grafana-agent
    Register-ScheduledTask `
        -TaskName $healthCheckTaskName `
        -Action $healthCheckTaskAction `
        -Trigger $healthCheckTaskTrigger `
        -Description $healthCheckTaskDescription

    # Set the task principal's user ID and run level.
    $healthCheckTaskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    # Set the task compatibility value to Windows 10.
    $healthCheckTaskSettings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -ExecutionTimeLimit 0 -StartWhenAvailable
    # Update the task principal settings
    Set-ScheduledTask -TaskName $healthCheckTaskName -Principal $healthCheckTaskPrincipal -Settings $healthCheckTaskSettings

    #Start
    Start-ScheduledTask -TaskName $healthCheckTaskName

    echo "`nCompleted Installation! Verify Windows metrics are coming in on Grafana"
    echo "Thanks for using OpsVerse ObserveNow"
}

if($flag -eq $true) {
    Restart-Service -Name "Grafana Agent"
}

Read-Host -Prompt "Press Enter to exit"