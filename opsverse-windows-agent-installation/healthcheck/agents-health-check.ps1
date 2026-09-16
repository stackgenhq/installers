#Requires -RunAsAdministrator

$agentService = Get-Service -Name "ObserveNowAgent" -ErrorAction SilentlyContinue

if ($agentService -and $agentService.Status -ne 'Running') {
    Start-Service 'ObserveNowAgent'
    Start-Sleep -Seconds 5
}
