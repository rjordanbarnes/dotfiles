[CmdletBinding()]
param(
    [string]$UserId = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
)

$ErrorActionPreference = 'Stop'
$runtime = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
$script = Join-Path $PSScriptRoot 'Invoke-DockerMaintenance.ps1'
$action = New-ScheduledTaskAction `
    -Execute $runtime `
    -Argument "-NoProfile -NonInteractive -File `"$script`"" `
    -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -Daily -At '03:00'
$principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask `
    -TaskName 'Dotfiles-Docker-Maintenance' `
    -Description 'Remove only old untagged Docker images while no GitHub runner job is active. Preserve CI cache, tagged images, containers and volumes.' `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Get-ScheduledTaskInfo -TaskName 'Dotfiles-Docker-Maintenance' |
    Select-Object TaskName, NextRunTime, LastTaskResult
