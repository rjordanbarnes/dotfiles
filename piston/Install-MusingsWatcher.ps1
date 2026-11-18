[CmdletBinding()]
param(
    [string] $TaskName = 'Ditzy-Musings-Watcher',
    [string] $UserId = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
)

$ErrorActionPreference = 'Stop'
$backgroundHost = & (Join-Path $PSScriptRoot '..\windows\Get-BackgroundProcessHost.ps1')
$node = (Get-Command node.exe -CommandType Application -ErrorAction Stop).Source
$watcher = Join-Path $PSScriptRoot 'musings-watcher.mjs'
if (-not (Test-Path -LiteralPath 'C:\code\piston\user\musings' -PathType Container)) {
    throw 'The Piston musings directory does not exist.'
}

$action = New-ScheduledTaskAction `
    -Execute $backgroundHost `
    -Argument "`"$node`" `"$watcher`"" `
    -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description 'Watch public Piston musings, debounce edits, and ask Ditzy to broadcast updates without reading piston/user/private.' `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2
Get-ScheduledTaskInfo -TaskName $TaskName |
    Select-Object TaskName, NextRunTime, LastRunTime, LastTaskResult
